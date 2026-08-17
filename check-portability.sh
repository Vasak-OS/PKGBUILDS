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

for tool in bsdtar objdump; do
  command -v "$tool" >/dev/null || { echo "$tool not found (install libarchive and binutils)." >&2; exit 1; }
done

# The fingerprint of a compiler told to target x86-64-v3 or above.
#
# These are BMI1/BMI2 general-purpose instructions. They matter for two reasons:
# no CPU before 2013 has them, and — unlike the AVX vector instructions — they
# are practically never written by hand inside the runtime-dispatched SIMD
# routines that crates like memchr ship. So finding one means the *compiler* was
# aimed above the baseline, not that a library carries an optional fast path.
#
# `tzcnt` is deliberately absent. It assembles to `f3 0f bc`, which a CPU without
# BMI1 executes as `rep bsf` — the same result — so LLVM emits it even for the
# baseline. Flagging it would fail every package for no reason.
FINGERPRINT='\b(lzcnt|shlx|shrx|sarx|andn|bzhi|mulx|pdep|pext|blsi|blsr|blsmsk)\b'

# Reported separately: these do appear in hand-written, cpuid-guarded code, so on
# their own they are not a verdict — only a hint worth printing when something
# else already failed.
VECTOR='\b(vpbroadcast[a-z]+|vperm[a-z0-9]+|vfmadd[0-9]+[a-z]+|vpsravd|vgather[a-z]+)\b'

scan_package() {
  local pkg="$1" name work bad=0
  name="${pkg##*/}"

  work="$(mktemp -d)"
  # Extract only what can contain machine code.
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

    local hits
    hits="$(objdump -d --no-show-raw-insn "$file" 2>/dev/null |
      grep -coE "$FINGERPRINT" || true)"
    [[ "$hits" -gt 0 ]] || continue

    if [[ $reported -eq 0 ]]; then
      echo "  ${RED}$name${OFF}"
      reported=1
      bad=1
    fi
    local vec
    vec="$(objdump -d --no-show-raw-insn "$file" 2>/dev/null | grep -coE "$VECTOR" || true)"
    printf '      %-52s %s instrucción(es) BMI, %s vectoriales\n' \
      "${file#"$work"/}" "$hits" "$vec"
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
echo "  ilegal» en equipos más viejos. Para los paquetes Rust, fijá la arquitectura en" >&2
echo "  build(); para los de C, revisá que CFLAGS no traiga -march=native.${OFF}" >&2
exit 1
