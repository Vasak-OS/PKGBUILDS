#!/usr/bin/env bash
#
# check-portability.sh — refuse to publish a package that only runs on the
# machine that built it.
#
# A package compiled with `-C target-cpu=native` (or `-march=native`) installs
# without a complaint anywhere and then dies with «illegal instruction» on any
# CPU older than the builder's. Nothing about that looks like a build failure,
# which is why it went unnoticed here for nine packages: it only shows up on
# somebody else's computer.
#
# So the finished packages are read, not the sources. build-all.sh already
# checks that every Rust PKGBUILD pins the architecture; this is the backstop
# that catches whatever that check cannot see — a C package picking up CFLAGS
# from makepkg.conf, a vendored binary, a dependency built somewhere else.
#
# Usage:
#   ./check-portability.sh [DIR|PACKAGE...]
#
# With no arguments it scans every package in the repository staging directory
# (../repository-script/x86_64 by default, overridable with $VASAKOS_REPO_DIR).
#
# Exits non-zero if anything is not portable.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$REPO_DIR/.." && pwd)"
DEFAULT_REPO="${VASAKOS_REPO_DIR:-$WORKSPACE/repository-script/x86_64}"

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'; DIM=$'\033[2m'; OFF=$'\033[0m'
[[ -t 1 ]] || { RED=""; GREEN=""; YELLOW=""; CYAN=""; DIM=""; OFF=""; }

for tool in bsdtar objdump gawk; do
  command -v "$tool" >/dev/null || { echo "$tool not found (install libarchive and binutils)." >&2; exit 1; }
done

# The fingerprint of a compiler told to target x86-64-v3 or above.
#
# These are BMI1/BMI2 general-purpose instructions, and no CPU from before 2013
# has them. Finding one is not a verdict on its own, though: `ring` ships the
# CRYPTOGAMS bignum assembly, written by hand and full of `mulx`, and picks the
# routine to call after reading CPUID. Its instructions are there on every
# build, on purpose, and never execute on a machine that lacks them.
#
# What tells the two apart is *where* the instructions are. Hand-written
# assembly lives in one block: 375 of them inside 108 KB of ring's own code, in
# a 7 MB binary. A compiler aimed above the baseline spreads them through
# everything it compiled. So the distribution is what decides, and finding the
# CPUID check that guards them is the corroboration.
#
# `tzcnt` is deliberately absent. It assembles to `f3 0f bc`, which a CPU without
# BMI1 executes as `rep bsf` — the same result — so LLVM emits it even for the
# baseline. Flagging it would fail every package for no reason.
BMI='lzcnt|shlx|shrx|sarx|andn|bzhi|mulx|pdep|pext|blsi|blsr|blsmsk'
FINGERPRINT="\\b($BMI)\\b"

# El mismo patrón para gawk, que no es el mismo idioma: el borde de palabra ahí
# es \y, y \b dentro de una variable significa «retroceso», así que la
# búsqueda no encontraba nada y todo parecía portable. Las barras van dobles
# porque -v procesa los escapes una vez antes de que la expresión se compile.
GAWK_FINGERPRINT="\\\\y($BMI)\\\\y"

# Reported separately: these do appear in hand-written, cpuid-guarded code, so on
# their own they are not a verdict — only a hint worth printing when something
# else already failed.
VECTOR='\b(vpbroadcast[a-z]+|vperm[a-z0-9]+|vfmadd[0-9]+[a-z]+|vpsravd|vgather[a-z]+)\b'

# How much of the binary the suspicious instructions are spread across, plus
# whether anything in it reads CPUID. Answered in one pass: these binaries are
# big and disassembling them twice was already the slow part of this script.
#
# Prints: <instrucciones> <bloques de 64 KB> <ancho en bytes> <cpuid>
measure_file() {
  objdump -d --no-show-raw-insn "$1" 2>/dev/null | gawk -v fp="$GAWK_FINGERPRINT" '
    $0 ~ fp {
      addr = $1; sub(":", "", addr)
      d = strtonum("0x" addr)
      if (d == 0) next
      hits++
      block[int(d / 65536)] = 1
      if (min == 0 || d < min) min = d
      if (d > max) max = d
    }
    /\ycpuid\y/ {
      addr = $1; sub(":", "", addr)
      c = strtonum("0x" addr)
      if (c > 0) cpuid[++cpuids] = c
    }
    END {
      # Lo que importa del cpuid no es que exista, sino que esté pegado al
      # bloque: es el control que decide si esas instrucciones se ejecutan.
      distancia = -1
      for (i = 1; i <= cpuids; i++)
        if (cpuid[i] < min && (distancia == -1 || min - cpuid[i] < distancia))
          distancia = min - cpuid[i]
      printf "%d %d %d %d\n", hits + 0, length(block), (max - min) + 0, distancia
    }
  '
}

# Instructions packed into one stretch of code with a CPUID check right in front
# of them are somebody's hand-written fast path, not a compiler aimed at this
# machine.
#
# Las dos condiciones van juntas a propósito. Que haya un cpuid en algún lado no
# dice nada —un binario compilado nativo que además use `ring` lo tendría—, pero
# si *todas* las instrucciones caben en un tramo corto que empieza justo después
# de un cpuid, no quedó ninguna suelta en el código que compiló el compilador.
# ring, que es la razón de todo esto, mide 108 KB y tiene su control 2 KB antes.
ANCHO_MAX=$((256 * 1024))
CONTROL_MAX=$((128 * 1024))

scan_package() {
  local pkg="$1" name work bad=0
  name="${pkg##*/}"

  work="$(mktemp -d)"
  if ! bsdtar -xf "$pkg" -C "$work" 2>/dev/null; then
    echo "  ${RED}$name: no se pudo leer el paquete${OFF}" >&2
    rm -rf "$work"
    return 1
  fi

  local reported=0
  while IFS= read -r -d '' file; do
    # `file` would be clearer but adds a dependency. The magic is read as hex
    # because comparing raw bytes in a command substitution trips over the NUL
    # that ELF's fourth byte is not, but the ones after it are.
    [[ "$(od -An -tx1 -N4 "$file" 2>/dev/null | tr -d ' \n')" == "7f454c46" ]] || continue

    local hits bloques ancho control
    read -r hits bloques ancho control < <(measure_file "$file")
    [[ "${hits:-0}" -gt 0 ]] || continue

    local corto="${file#"$work"/}"

    if [[ "$ancho" -le $ANCHO_MAX && "$control" -ge 0 && "$control" -le $CONTROL_MAX ]]; then
      # Worth printing: it is the difference between "revisado y está bien" and
      # "no se miró", and if the guess is ever wrong this line is what shows it.
      printf '  %s%-52s%s %s instrucción(es) BMI en %s KB, con el control de CPU %s KB antes: ensamblador propio, no el compilador\n' \
        "$DIM" "$corto" "$OFF" "$hits" "$((ancho / 1024))" "$((control / 1024))"
      continue
    fi

    if [[ $reported -eq 0 ]]; then
      echo "  ${RED}$name${OFF}"
      reported=1
      bad=1
    fi
    local vec
    vec="$(objdump -d --no-show-raw-insn "$file" 2>/dev/null | grep -coE "$VECTOR" || true)"
    printf '      %-52s %s instrucción(es) BMI en %s bloques de 64 KB, %s vectoriales\n' \
      "$corto" "$hits" "$bloques" "$vec"
  done < <(find "$work" -type f -print0 2>/dev/null)

  rm -rf "$work"
  return $bad
}

TARGETS=()
if [[ $# -eq 0 ]]; then
  [[ -d "$DEFAULT_REPO" ]] || { echo "No existe $DEFAULT_REPO" >&2; exit 1; }
  mapfile -t TARGETS < <(find "$DEFAULT_REPO" -maxdepth 1 -name '*.pkg.tar.*' ! -name '*.sig' | sort)
else
  for arg in "$@"; do
    if [[ -d "$arg" ]]; then
      mapfile -t -O "${#TARGETS[@]}" TARGETS < <(find "$arg" -maxdepth 1 -name '*.pkg.tar.*' ! -name '*.sig' | sort)
    elif [[ -f "$arg" ]]; then
      TARGETS+=("$arg")
    else
      # A package name: look for what its directory produced.
      mapfile -t -O "${#TARGETS[@]}" TARGETS < <(find "$REPO_DIR/$arg" -maxdepth 1 -name '*.pkg.tar.*' ! -name '*.sig' 2>/dev/null | sort)
    fi
  done
fi

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "No hay paquetes para revisar." >&2
  exit 1
fi

echo "${CYAN}==> Revisando ${#TARGETS[@]} paquete(s) para x86-64 base${OFF}"

FAILED=()
for pkg in "${TARGETS[@]}"; do
  scan_package "$pkg" || FAILED+=("${pkg##*/}")
done

echo
if [[ ${#FAILED[@]} -eq 0 ]]; then
  echo "${GREEN}Todos corren en cualquier x86-64.${OFF}"
  exit 0
fi

echo "${RED}No portables (${#FAILED[@]}):${OFF} ${FAILED[*]}" >&2
echo "${DIM}  Se compilaron para la CPU de esta máquina y se van a caer con «instrucción" >&2
echo "  ilegal» en equipos más viejos." >&2
echo >&2
echo "  Si el PKGBUILD todavía no fija la arquitectura: en los de Rust va" >&2
echo "  '-C target-cpu=x86-64' en build(); en los de C, que CFLAGS no traiga -march=native." >&2
echo >&2
echo "  Si el PKGBUILD ya la fija, lo que sobrevive es el binario viejo: se compiló antes" >&2
echo "  del arreglo y build-all lo da por actualizado porque el pkgver/pkgrel no cambió." >&2
echo "  Subí el pkgrel —así pacman también actualiza donde ya esté instalado— o forzá el" >&2
echo "  paquete por nombre: ./build-all.sh <dir>.${OFF}" >&2
exit 1
