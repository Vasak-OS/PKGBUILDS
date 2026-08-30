#!/usr/bin/env bash
#
# build-all.sh — build the VasakOS packages that are out of date and publish
# them into the local pacman repository.
#
# For each package directory that contains a PKGBUILD it asks makepkg which
# files that PKGBUILD would produce (`makepkg --packagelist`, which resolves
# pkgname/pkgver/pkgrel/arch and split packages). If every one of those files is
# already sitting in the repository directory, the package is up to date and is
# not rebuilt. Otherwise it is built, copied into the repository, and any older
# version of the same pkgname — together with its detached signature — is
# deleted so only one version of each package remains.
#
# When both a release and a VCS variant exist (e.g. vasak-desktop and
# vasak-desktop-git), the `-git` one is preferred and the twin skipped. Both
# carry the same pkgname, so the twin's package is cleaned up by the same rule.
#
# The repository directory defaults to the checkout of repository-script that
# lives next to this repo in the workspace:
#
#   <workspace>/repository-script/x86_64
#
# After this script finishes, run repository-script/build-db.sh to regenerate
# and sign the database. `repository-script/update-repo.sh` does both in one go.
#
# Usage:
#   ./build-all.sh [options] [package-dir ...]
#
# Naming a package directory builds exactly those, always, ignoring the
# up-to-date check — the escape hatch for rebuilding a `-git` package whose
# pkgver did not change but whose upstream branch did.
#
# Options:
#   -r, --repo DIR        Publish into DIR (default: the path above,
#                         overridable with $VASAKOS_REPO_DIR).
#       --no-repo         Don't read from or write to the repository: build
#                         everything, like the old behaviour.
#   -a, --all             Build every package even if it is already published.
#       --adopt           If the expected package file is already sitting in its
#                         PKGBUILD directory from an earlier build, publish that
#                         instead of building it again. Handy the first time the
#                         repository directory is filled.
#   -n, --dry-run         Report what would be built and removed; change nothing.
#   -i, --install         Also install each package (makepkg -i).
#   -o, --output DIR      Also copy built packages into DIR.
#   -x, --exclude NAME    Skip package dir NAME (repeatable).
#   -s, --stop            Stop on the first failure (default: keep going).
#       --no-prefer-git   Do not skip release twins in favour of -git.
#       --no-clean        Keep older versions in the repository.
#   -d, --nodeps          Don't check or install dependencies (makepkg -d).
#                         Lets you verify everything compiles without root.
#       --keep-work       Don't delete src/, pkg/ and the git clone after a
#                         successful build. They are removed by default: among
#                         the 20 recipes they reached 8.4 GB, and the next
#                         build re-clones from the remote anyway. A failed
#                         build always keeps them.
#       --refresh-vcs     Run `makepkg -o` on PKGBUILDs that carry a pkgver()
#                         function, so their version reflects upstream HEAD
#                         before the up-to-date check. Costs a source fetch.
#       --no-check        Skip the check-all.sh pre-flight.
#       --strict-check    Abort the whole run if any app fails the pre-flight,
#                         instead of skipping just that package.
#   -h, --help            Show this help.
#
# Before building, check-all.sh runs a fast pre-flight on the apps that are
# actually going to be built: a Tauri PKGBUILD fails on a single type error, and
# finding that out after a full build wastes a lot of time.
#
# It checks the sources makepkg fetched, not your working copy. The PKGBUILDs
# fetch with git+https and build the pushed branch, so a checkout that is behind
# reports errors for code already fixed upstream, and one that is ahead hides
# errors that only appear at build time. Neither is what ends up in the package.
#
# makepkg runs with: -sf --noconfirm --needed  (installs deps, overwrites).
# Do not run as root — makepkg refuses to.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$REPO_DIR/.." && pwd)"

# Nada queda afuera por omisión: lo que el ISO pide en packages.x86_64 se
# compila. Dejar algo afuera de forma permanente significa armar la imagen con
# lo que hubiera quedado de una compilación anterior —o con nada—, y eso no se
# nota hasta que la imagen ya está hecha. Para saltear algo en una vuelta
# puntual está --exclude, que dura lo que dura el comando.
EXCLUDE=()
INSTALL=0
STOP=0
PREFER_GIT=1
CHECK=1
STRICT_CHECK=0
NODEPS=0
KEEP_WORK=0
FORCE_ALL=0
DRY_RUN=0
ADOPT=0
CLEAN_OLD=1
REFRESH_VCS=0
USE_PACREPO=1
OUTPUT=""
PACREPO="${VASAKOS_REPO_DIR:-$WORKSPACE/repository-script/x86_64}"
ONLY=()

# The help text is the header comment itself, so the two cannot drift apart.
usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "${BASH_SOURCE[0]}"; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--install) INSTALL=1; shift ;;
    -o|--output) OUTPUT="${2:?--output needs a dir}"; shift 2 ;;
    -r|--repo) PACREPO="${2:?--repo needs a dir}"; shift 2 ;;
    --no-repo) USE_PACREPO=0; shift ;;
    -a|--all) FORCE_ALL=1; shift ;;
    --adopt) ADOPT=1; shift ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    -x|--exclude) EXCLUDE+=("${2:?--exclude needs a name}"); shift 2 ;;
    -s|--stop) STOP=1; shift ;;
    --no-prefer-git) PREFER_GIT=0; shift ;;
    --no-clean) CLEAN_OLD=0; shift ;;
    --refresh-vcs) REFRESH_VCS=1; shift ;;
    --keep-work) KEEP_WORK=1; shift ;;
    --no-check) CHECK=0; shift ;;
    --strict-check) STRICT_CHECK=1; shift ;;
    -d|--nodeps) NODEPS=1; shift ;;
    -h|--help) usage 0 ;;
    -*) echo "Unknown option: $1" >&2; usage 1 ;;
    *) ONLY+=("${1%/}"); shift ;;
  esac
done

if [[ $EUID -eq 0 ]]; then
  echo "Do not run build-all.sh as root; makepkg must run as a regular user." >&2
  exit 1
fi

command -v makepkg >/dev/null || { echo "makepkg not found (install base-devel)." >&2; exit 1; }

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'; DIM=$'\033[2m'; OFF=$'\033[0m'
[[ -t 1 ]] || { RED=""; GREEN=""; YELLOW=""; CYAN=""; DIM=""; OFF=""; }

if [[ $USE_PACREPO -eq 1 ]]; then
  if [[ ! -d "$PACREPO" ]]; then
    echo "!! Repository directory not found: $PACREPO" >&2
    echo "   Clone repository-script next to this repo, pass --repo DIR, or use --no-repo." >&2
    exit 1
  fi
  PACREPO="$(cd "$PACREPO" && pwd)"
fi

is_excluded() {
  local name="$1" e
  for e in "${EXCLUDE[@]}"; do [[ "$name" == "$e" ]] && return 0; done
  return 1
}

wanted() {
  [[ ${#ONLY[@]} -eq 0 ]] && return 0
  local name="$1" want
  for want in "${ONLY[@]}"; do [[ "$name" == "$want" ]] && return 0; done
  return 1
}

# A package file is NAME-PKGVER-PKGREL-ARCH.pkg.tar.zst, and NAME itself may
# contain dashes. Dropping the last three dash-separated fields is the only way
# to recover the name without parsing the PKGBUILD again — and it has to be
# exact, because a prefix glob would make vasak-desktop swallow
# vasak-desktop-settings.
pkg_name_of() {
  local base="${1##*/}"
  base="${base%.pkg.tar.*}"
  base="${base%-*}"   # arch
  base="${base%-*}"   # pkgrel
  echo "${base%-*}"   # pkgver
}

# Packages other VasakOS packages depend on, built before the rest.
#
# Alphabetical order is fine until one of ours needs another of ours: without
# this, vasak-accounts is reached before vasak-permissions and makepkg cannot
# resolve a dependency that has not been built yet.
FIRST=(vasak-permissions)

# Collect candidate package dirs (those with a PKGBUILD), dependencies first.
mapfile -t ALL < <(
  cd "$REPO_DIR" || exit
  for d in */; do [[ -f "${d}PKGBUILD" ]] && echo "${d%/}"; done | sort |
    awk -v first="${FIRST[*]}" '
      BEGIN { split(first, f, " "); for (i in f) rank[f[i]] = 1 }
      { if ($0 in rank) early[++e] = $0; else late[++l] = $0 }
      END {
        for (i = 1; i <= e; i++) print early[i]
        for (i = 1; i <= l; i++) print late[i]
      }'
)

# An explicitly named directory is built no matter what: it is how you force a
# rebuild, so exclusion and twin-preference must not filter it out.
TARGETS=()
for name in "${ALL[@]}"; do
  if [[ ${#ONLY[@]} -gt 0 ]]; then
    wanted "$name" && TARGETS+=("$name")
    continue
  fi
  is_excluded "$name" && continue
  # Prefer the -git twin: skip "foo" when "foo-git" also exists.
  if [[ $PREFER_GIT -eq 1 && "$name" != *-git && -f "$REPO_DIR/${name}-git/PKGBUILD" ]]; then
    continue
  fi
  TARGETS+=("$name")
done

if [[ ${#ONLY[@]} -gt 0 ]]; then
  for want in "${ONLY[@]}"; do
    [[ -f "$REPO_DIR/$want/PKGBUILD" ]] || { echo "No such package directory: $want" >&2; exit 1; }
  done
fi

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "Nothing to do." >&2
  exit 0
fi

# ── Portability guard ─────────────────────────────────────────────────────────
#
# makepkg exports RUSTFLAGS from makepkg.conf, and some distributions ship
# `-C target-cpu=native` there — CachyOS does, in
# /etc/makepkg.conf.d/rust.conf. A package built with it runs on the machine
# that compiled it and dies with SIGILL on anything older, because rustc emits
# whatever the builder's CPU happens to support.
#
# Nothing about that failure looks like a build problem: the package builds,
# installs and only crashes on somebody else's computer. So it is checked here,
# where a new PKGBUILD cannot quietly inherit it.
UNPINNED=()
for name in "${TARGETS[@]}"; do
  pkgbuild="$REPO_DIR/$name/PKGBUILD"
  # Los comentarios se sacan antes de buscar. `vasakos-desktop` no compila nada
  # —es un metapaquete `arch=('any')`, 380 lineas de `depends` y un `package()`—
  # y aun asi salia en esta lista: un comentario suyo nombra la ruta
  # `vasak-installer/src-tauri/paquetes.txt`, y `src-tauri` alcanzaba para que
  # el patron diera positivo. Avisar de un paquete que no tiene una sola linea
  # de Rust es peor que no avisar: esta advertencia existe porque nueve
  # paquetes se publicaron sin fijar la arquitectura, y una que se equivoca es
  # una que se aprende a ignorar.
  #
  # El `#` se corta solo si abre linea o viene despues de un espacio, para no
  # partir un `source=(git+https://...#branch=main)`, que no es un comentario.
  codigo=$(sed -E 's/(^|[[:space:]])#.*//' "$pkgbuild")
  grep -qE '\bcargo\b|\brust\b|tauri' <<<"$codigo" || continue
  grep -q 'target-cpu=x86-64' <<<"$codigo" || UNPINNED+=("$name")
done

if [[ ${#UNPINNED[@]} -gt 0 ]]; then
  echo "${YELLOW}!! Estos paquetes Rust no fijan target-cpu y van a heredar el de la máquina:${OFF}" >&2
  printf '     %s\n' "${UNPINNED[@]}" >&2
  echo "${DIM}   Agregá en build(), antes de compilar:" >&2
  echo "     unset CARGO_ENCODED_RUSTFLAGS" >&2
  echo "     export RUSTFLAGS=\"-C opt-level=3 -C target-cpu=x86-64\"" >&2
  echo "     export CARGO_BUILD_RUSTFLAGS=\"\$RUSTFLAGS\"" >&2
  echo "   Sin eso el paquete sólo corre en CPUs como la que lo compiló.${OFF}" >&2
  echo >&2
fi

# ── Las tres listas no se pisan ───────────────────────────────────────────────
#
# VasakOS reparte los paquetes en tres lugares, y el criterio es qué papel
# cumple cada uno: `vasakos-desktop` lleva lo que el escritorio necesita para
# funcionar, `archiso/packages.x86_64` lo que hace falta para armar o arrancar
# la ISO, y `complementos.toml` del instalador lo que el usuario elige.
#
# Un paquete en el metapaquete *y* entre los complementos rompe la tercera: la
# casilla se dibuja, el usuario la desmarca, y el paquete se instala igual
# porque entra por dependencia. Pasó con `firefox` y con `broadcom-wl-dkms`,
# que estaban en los dos lados: quien pedía Brave —o «sin navegador»— se
# llevaba Firefox de todos modos, y la pantalla de complementos era decorado.
#
# No falla el build: es un aviso, y sólo corre si el repositorio del instalador
# está al lado.
COMPLEMENTOS="$WORKSPACE/vasak-installer/src-tauri/complementos.toml"
META="$REPO_DIR/vasakos-desktop/PKGBUILD"
if [[ -f "$COMPLEMENTOS" && -f "$META" ]]; then
  # Del PKGBUILD: las líneas de `depends`, sin comentarios.
  mapfile -t _dep < <(
    sed -n '/^depends=(/,/^)/p' "$META" | sed -E 's/#.*//; s/^[[:space:]]+//; s/[[:space:]]+$//' |
      grep -vE '^(depends=\(|\)|)$'
  )
  # Del catálogo: lo que nombran las listas `paquetes = [...]`.
  mapfile -t _cat < <(
    grep -E '^[[:space:]]*paquetes[[:space:]]*=' "$COMPLEMENTOS" |
      grep -oE '"[^"]+"' | tr -d '"' | sort -u
  )
  SOLAPADOS=()
  for _p in "${_cat[@]+"${_cat[@]}"}"; do
    for _d in "${_dep[@]+"${_dep[@]}"}"; do
      [[ "$_p" == "$_d" ]] && SOLAPADOS+=("$_p") && break
    done
  done
  if [[ ${#SOLAPADOS[@]} -gt 0 ]]; then
    echo "${YELLOW}!! Estos paquetes están en vasakos-desktop y también entre los complementos:${OFF}" >&2
    printf '     %s\n' "${SOLAPADOS[@]}" >&2
    echo "${DIM}   El metapaquete los instala por dependencia, así que la casilla del" >&2
    echo "   instalador no cambia nada: quien la desmarca se los lleva igual." >&2
    echo "   Sacalos de las \`depends\` de vasakos-desktop, o del catálogo.${OFF}" >&2
    echo >&2
  fi
fi

# ── Decide what is out of date ────────────────────────────────────────────────
#
# `makepkg --packagelist` is cheap: it sources the PKGBUILD and prints the
# output paths, without touching the network. The exception is a VCS PKGBUILD
# with a pkgver() function, whose version is only correct after the sources have
# been fetched — hence --refresh-vcs.

declare -A EXPECTED=()   # dir -> newline separated output paths
BUILD=()
ADOPTED=()
UPTODATE=()
BROKEN=()

echo "${CYAN}==> Checking ${#TARGETS[@]} package(s) against the repository${OFF}"
[[ $USE_PACREPO -eq 1 ]] && echo "    repo: $PACREPO"

for name in "${TARGETS[@]}"; do
  dir="$REPO_DIR/$name"

  if [[ $REFRESH_VCS -eq 1 ]] && grep -qE '^[[:space:]]*pkgver[[:space:]]*\(\)' "$dir/PKGBUILD"; then
    printf '  %-30s %s\n' "$name" "${DIM}refreshing pkgver from upstream…${OFF}"
    (cd "$dir" && makepkg -o --nodeps --noconfirm >/dev/null 2>&1) || true
  fi

  # Debug packages are a by-product of makepkg's OPTIONS, never published.
  mapfile -t files < <(cd "$dir" && makepkg --packagelist 2>/dev/null | grep -v -- '-debug-')
  if [[ ${#files[@]} -eq 0 ]]; then
    printf '  %-30s %s\n' "$name" "${RED}PKGBUILD does not parse${OFF}"
    BROKEN+=("$name")
    continue
  fi
  EXPECTED["$name"]="$(printf '%s\n' "${files[@]}")"

  if [[ $USE_PACREPO -eq 0 || $FORCE_ALL -eq 1 || ${#ONLY[@]} -gt 0 ]]; then
    BUILD+=("$name")
    continue
  fi

  missing=0
  for f in "${files[@]}"; do
    [[ -f "$PACREPO/${f##*/}" ]] || missing=1
  done

  if [[ $missing -eq 0 ]]; then
    printf '  %-30s %s\n' "$name" "${DIM}up to date ($(pkg_name_of "${files[0]}") $(basename "${files[0]}" | sed -E 's/.*-([^-]+-[^-]+)-[^-]+\.pkg\.tar\..*/\1/'))${OFF}"
    UPTODATE+=("$name")
    continue
  fi

  # The package may already have been built here in an earlier session — the
  # common case the first time the repository directory is populated. Rebuilding
  # a Tauri app for half an hour to obtain a file that is already on disk is
  # pure waste, so --adopt publishes it instead.
  if [[ $ADOPT -eq 1 ]]; then
    local_ok=1
    for f in "${files[@]}"; do [[ -f "$f" ]] || local_ok=0; done
    if [[ $local_ok -eq 1 ]]; then
      printf '  %-30s %s\n' "$name" "${CYAN}already built here — adopting${OFF}"
      ADOPTED+=("$name")
      continue
    fi
  fi

  printf '  %-30s %s\n' "$name" "${YELLOW}needs build${OFF} ${DIM}→ $(basename "${files[0]}")${OFF}"
  BUILD+=("$name")
done

echo
if [[ ${#BUILD[@]} -eq 0 && ${#ADOPTED[@]} -eq 0 ]]; then
  echo "${GREEN}Everything is already published (${#UPTODATE[@]} package(s) up to date).${OFF}"
  [[ ${#BROKEN[@]} -gt 0 ]] && { echo "${RED}Broken PKGBUILDs (${#BROKEN[@]}): ${BROKEN[*]}${OFF}"; exit 1; }
  exit 0
fi

[[ ${#ADOPTED[@]} -gt 0 ]] && echo "${CYAN}==> Will adopt ${#ADOPTED[@]} already-built package(s):${OFF} ${ADOPTED[*]}"
[[ ${#BUILD[@]} -gt 0 ]] && echo "${CYAN}==> Will build ${#BUILD[@]} package(s):${OFF} ${BUILD[*]}"
echo

OK=()
FAIL=()
NOCOMPILE=()
PUBLISHED=()
REMOVED=()

publish() {
  local name="$1" new base target old
  while IFS= read -r new; do
    [[ -n "$new" ]] || continue
    base="${new##*/}"
    if [[ ! -f "$new" ]]; then
      echo "!! ${YELLOW}built but missing: $base${OFF}" >&2
      continue
    fi
    install -m644 "$new" "$PACREPO/$base"
    # A stale detached signature next to a freshly copied package would be
    # served by repo-add as valid; drop it and let build-db.sh sign again.
    rm -f "$PACREPO/$base.sig"
    PUBLISHED+=("$base")

    [[ $CLEAN_OLD -eq 1 ]] || continue
    target="$(pkg_name_of "$new")"
    for old in "$PACREPO"/*.pkg.tar.*; do
      [[ -f "$old" ]] || continue
      [[ "$old" == *.sig ]] && continue
      [[ "$(pkg_name_of "$old")" == "$target" ]] || continue
      [[ "${old##*/}" == "$base" ]] && continue
      rm -f "$old" "$old.sig"
      REMOVED+=("${old##*/}")
    done
  done <<<"${EXPECTED[$name]}"
}

if [[ $DRY_RUN -eq 1 ]]; then
  echo "${DIM}(dry run — nothing was built)${OFF}"
  if [[ $USE_PACREPO -eq 1 && $CLEAN_OLD -eq 1 ]]; then
    echo
    echo "Would remove from the repository:"
    for name in "${BUILD[@]}" "${ADOPTED[@]+"${ADOPTED[@]}"}"; do
      while IFS= read -r new; do
        target="$(pkg_name_of "$new")"
        for old in "$PACREPO"/*.pkg.tar.*; do
          [[ -f "$old" ]] || continue
          [[ "$old" == *.sig ]] && continue
          [[ "$(pkg_name_of "$old")" == "$target" ]] || continue
          [[ "${old##*/}" == "${new##*/}" ]] && continue
          echo "  ${old##*/}"
        done
      done <<<"${EXPECTED[$name]}"
    done
  fi
  exit 0
fi

for name in "${ADOPTED[@]+"${ADOPTED[@]}"}"; do
  publish "$name"
done

if [[ ${#BUILD[@]} -eq 0 ]]; then
  CHECK=0
fi

# ── Pre-flight ────────────────────────────────────────────────────────────────
#
# Only the apps whose package is actually being rebuilt are worth checking; the
# workspace dir for a package is its name minus the -git suffix.

if [[ $CHECK -eq 1 && -x "$REPO_DIR/check-all.sh" ]]; then
  CHECK_ARGS=()
  for name in "${BUILD[@]}"; do
    app="${name%-git}"

    # Check the sources makepkg fetched, not the working copy. The PKGBUILD
    # builds from the remote, so a local checkout that is behind reports errors
    # for code that was already fixed — and one that is ahead hides errors that
    # would only appear at build time. Neither is what gets packaged.
    # Always refresh, never "only if missing": an src/ left over from an earlier
    # run is exactly the stale tree this is meant to avoid checking, and it is
    # indistinguishable from a fresh one by looking at it.
    src="$REPO_DIR/$name/src/$app"
    (cd "$REPO_DIR/$name" && makepkg -o --nodeps --noconfirm >/dev/null 2>&1) || true

    if [[ -d "$src" ]]; then
      CHECK_ARGS+=(-D "$src")
    elif [[ -d "$WORKSPACE/$app" ]]; then
      # No fetched tree — a package built from something other than a git
      # source. The working copy is the best available stand-in, and saying so
      # is better than checking nothing.
      echo "${YELLOW}   $app: sin fuentes descargadas, se revisa la copia local${OFF}" >&2
      CHECK_ARGS+=(-a "$app")
    fi
  done
  if [[ ${#CHECK_ARGS[@]} -gt 0 ]]; then
    echo "${CYAN}==> Pre-flight: checking the apps about to be built${OFF}"

    # The output is shown *and* parsed: one app that does not compile used to
    # abort the whole run, which is the wrong trade when nineteen others are
    # ready. Only the broken ones are dropped; the rest are built and the
    # summary says what was left out.
    check_log="$(mktemp)"
    "$REPO_DIR/check-all.sh" "${CHECK_ARGS[@]}" >"$check_log" 2>&1 || true
    cat "$check_log"

    # check-all.sh prints "No compilan (N): app (frontend) app (backend)".
    # Dropping the parenthesised part leaves the app names.
    mapfile -t failed_apps < <(
      sed -n 's/^No compilan ([0-9]*): //p' "$check_log" |
        tr ' ' '\n' | grep -v '^(' | grep -v '^$' | sort -u
    )
    rm -f "$check_log"

    for app in "${failed_apps[@]+"${failed_apps[@]}"}"; do
      for i in "${!BUILD[@]}"; do
        [[ "${BUILD[$i]%-git}" == "$app" ]] || continue
        NOCOMPILE+=("${BUILD[$i]}")
        unset 'BUILD[i]'
      done
    done
    BUILD=("${BUILD[@]+"${BUILD[@]}"}")   # reindexar tras los unset

    if [[ ${#NOCOMPILE[@]} -gt 0 ]]; then
      echo
      if [[ $STRICT_CHECK -eq 1 ]]; then
        echo "!! Abortando (--strict-check): ${NOCOMPILE[*]}" >&2
        exit 1
      fi
      echo "${YELLOW}==> Se saltean ${#NOCOMPILE[@]} paquete(s) que no compilan:${OFF} ${NOCOMPILE[*]}"
      echo "${DIM}    El resto se compila igual. Con --no-check se intentan todos.${OFF}"
    fi
    echo

    if [[ ${#BUILD[@]} -eq 0 ]]; then
      echo "${RED}No queda nada por compilar: todos los paquetes pendientes fallan el pre-vuelo.${OFF}" >&2
      exit 1
    fi
  fi
fi

[[ -n "$OUTPUT" ]] && mkdir -p "$OUTPUT"

if [[ $NODEPS -eq 1 ]]; then
  # -d skips the dependency check entirely, so makepkg never needs pacman and
  # therefore never needs root — enough to prove the sources compile.
  MK_ARGS=(-fd --noconfirm)
else
  MK_ARGS=(-sf --noconfirm --needed)
fi
[[ $INSTALL -eq 1 ]] && MK_ARGS+=(-i)

# Lo que makepkg deja en el directorio del paquete, una vez que ya no sirve.
#
# Un directorio de PKGBUILD debería tener sólo archivos planos: PKGBUILD,
# .install, .service, parches. Todo lo demás lo produce makepkg: el árbol de
# compilación (src/, pkg/), el clon bare del repositorio de origen, y el
# paquete terminado. Entre las 20 recetas eso llegó a ocupar 8,4 GB, y los
# `target/` de Cargo que quedan adentro de src/ son la mayor parte.
#
# Se borra **sólo si la compilación salió bien**. Cuando falla, src/ es
# exactamente lo que hace falta para entender por qué, así que ahí se deja.
#
# El clon bare se va con el resto a propósito: la próxima compilación clona de
# nuevo desde el remoto, que es la única forma de tener la certeza de que se
# está compilando lo que está publicado y no lo que quedó cacheado.
limpiar_trabajo() {
  local name="$1" publicado="$2"
  local dir="$REPO_DIR/$name"

  # Cualquier subdirectorio: src/, pkg/ y el clon, que se llama como la fuente
  # y por eso no se puede nombrar de antemano.
  find "$dir" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} + 2>/dev/null || true

  # El paquete sólo se borra si ya está guardado en otro lado. Sin repositorio
  # ni --output, el único ejemplar es éste y borrarlo sería tirar la
  # compilación.
  if [[ $publicado -eq 1 ]]; then
    rm -f "$dir"/*.pkg.tar.* 2>/dev/null || true
  fi
}

for name in "${BUILD[@]+"${BUILD[@]}"}"; do
  echo "──────────────────────────────────────────────────────────────"
  echo "${CYAN}==> $name${OFF}"
  if ( cd "$REPO_DIR/$name" && makepkg "${MK_ARGS[@]}" ); then
    OK+=("$name")
    _publicado=0
    [[ $USE_PACREPO -eq 1 ]] && { publish "$name"; _publicado=1; }
    if [[ -n "$OUTPUT" ]]; then
      cp -f "$REPO_DIR/$name"/*.pkg.tar.* "$OUTPUT"/ 2>/dev/null || true
      _publicado=1
    fi
    [[ $KEEP_WORK -eq 0 ]] && limpiar_trabajo "$name" "$_publicado"
  else
    FAIL+=("$name")
    echo "!! build failed: $name" >&2
    [[ $STOP -eq 1 ]] && break
  fi
done

echo
echo "════════════════════════════════════════════════════════════════"
echo "${GREEN}Built OK (${#OK[@]}):${OFF} ${OK[*]:-none}"
[[ ${#ADOPTED[@]} -gt 0 ]] && echo "${CYAN}Adopted (${#ADOPTED[@]}):${OFF} ${ADOPTED[*]}"
[[ ${#UPTODATE[@]} -gt 0 ]] && echo "${DIM}Up to date (${#UPTODATE[@]}): ${UPTODATE[*]}${OFF}"
[[ ${#FAIL[@]} -gt 0 ]] && echo "${RED}Failed (${#FAIL[@]}):${OFF} ${FAIL[*]}"
[[ ${#BROKEN[@]} -gt 0 ]] && echo "${RED}Broken PKGBUILDs (${#BROKEN[@]}):${OFF} ${BROKEN[*]}"

if [[ ${#NOCOMPILE[@]} -gt 0 ]]; then
  echo "${YELLOW}No compilan, no se intentaron (${#NOCOMPILE[@]}):${OFF} ${NOCOMPILE[*]}"
  echo "${DIM}  Su versión sigue siendo la que ya estaba publicada; el repositorio no queda"
  echo "  a medias, sólo sin esa actualización. Arreglalos y volvé a correr: sólo se"
  echo "  compilan esos.${OFF}"
fi

if [[ $USE_PACREPO -eq 1 ]]; then
  echo
  echo "Repository: $PACREPO"
  if [[ ${#PUBLISHED[@]} -gt 0 ]]; then
    echo "  ${GREEN}added (${#PUBLISHED[@]}):${OFF}"
    printf '    + %s\n' "${PUBLISHED[@]}"
  fi
  if [[ ${#REMOVED[@]} -gt 0 ]]; then
    echo "  ${YELLOW}removed (${#REMOVED[@]}):${OFF}"
    printf '    - %s\n' "${REMOVED[@]}"
  fi
  [[ ${#PUBLISHED[@]} -gt 0 ]] && echo "
Next: run repository-script/build-db.sh to regenerate and sign the database."
fi

[[ -n "$OUTPUT" ]] && echo "Packages copied to: $OUTPUT"

# Saltear un paquete roto no es un éxito: la salida distinta de cero es lo que
# hace que update-repo.sh y cualquier automatización se enteren.
[[ ${#FAIL[@]} -eq 0 && ${#BROKEN[@]} -eq 0 && ${#NOCOMPILE[@]} -eq 0 ]]
