#!/usr/bin/env bash
#
# check-all.sh — verify every VasakOS app is packageable, before building it.
#
# A full makepkg run of the whole set takes a long time, and the failures we
# actually hit are cheap to detect: a Tauri PKGBUILD runs `bun run tauri build`,
# whose beforeBuildCommand is `vue-tsc --noEmit && vite build`. So a single
# type error — even an unused import — stops the package from being produced,
# and nothing in `bun run dev` ever surfaces it.
#
# For each app repo in the workspace this checks:
#
#   frontend  `vue-tsc --noEmit`, when the build script gates on it
#   lint      `biome check` y `cargo clippy -D warnings`
#   backend   `cargo check`
#   git       whether HEAD is ahead of its remote
#
# El lint entra acá por lo que costó dejarlo en cero: la causa de que fallara
# siempre no eran los archivos, era `biome.json` —el `$schema` apuntaba a una
# versión vieja y `recommended` estaba obsoleto—, así que cada corrida terminaba
# en rojo sin importar el estado del código y **los avisos nuevos no se veían**.
# Cuando por fin miró de verdad, aparecieron dos `!` que tapaban un crash, un
# `parseInt` sin base y un crate que no compilaba en el MSRV que declaraba. Un
# lint que siempre falla es un lint que nadie mira; el gate es para que no vuelva
# a pasar.
#
# That last one matters more than it looks: the PKGBUILDs fetch sources with
# `git+https://...`, so makepkg builds the *pushed* branch. Commits sitting in
# the working copy are invisible to the build, which silently packages older
# code — including code you just fixed.
#
# Usage:
#   ./check-all.sh [options]
#
# Options:
#   -a, --app NAME     Check only this app directory (repeatable).
#   -t, --tests        Also run `cargo test --lib` for each Rust backend.
#       --no-lint      Skip the lint checks (biome + clippy).
#       -D, --dir DIR  Check this directory instead of the working copy. This is
#                      how the sources makepkg fetched are checked — the code
#                      that will actually be packaged, rather than whatever the
#                      local checkout happens to be at.
#       --no-install   Don't run `bun install` when node_modules is missing.
#       --no-git       Skip the unpushed-commits check.
#   -h, --help         Show this help.
#
# Exits non-zero if any check fails, so it can gate a build.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$REPO_DIR/.." && pwd)"

ONLY=()
DIRS=()
RUN_TESTS=0
DO_INSTALL=1
DO_GIT=1
DO_LINT=1

usage() { sed -n '2,48p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--app) ONLY+=("${2:?--app needs a name}"); shift 2 ;;
    -D|--dir) DIRS+=("${2:?--dir needs a path}"); shift 2 ;;
    -t|--tests) RUN_TESTS=1; shift ;;
    --no-install) DO_INSTALL=0; shift ;;
    --no-lint) DO_LINT=0; shift ;;
    --no-git) DO_GIT=0; shift ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

# Rust lives in ~/.cargo/bin, which isn't always on a non-login shell's PATH.
[[ -d "$HOME/.cargo/bin" ]] && PATH="$HOME/.cargo/bin:$PATH"

have() { command -v "$1" >/dev/null 2>&1; }

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; OFF=$'\033[0m'
[[ -t 1 ]] || { RED=""; GREEN=""; YELLOW=""; DIM=""; OFF=""; }

wanted() {
  [[ ${#ONLY[@]} -eq 0 ]] && return 0
  local name="$1" want
  for want in "${ONLY[@]}"; do [[ "$name" == "$want" ]] && return 0; done
  return 1
}

# Apps are workspace dirs carrying a frontend or a Tauri backend — unless
# explicit directories were given, which is how the sources makepkg fetched are
# checked instead of the working copy.
declare -A DIR_OF=()
if [[ ${#DIRS[@]} -gt 0 ]]; then
  APPS=()
  for d in "${DIRS[@]}"; do
    name="$(basename "$d")"
    APPS+=("$name")
    DIR_OF["$name"]="$d"
  done
else
  mapfile -t APPS < <(
    cd "$WORKSPACE" && for d in */; do
      name="${d%/}"
      [[ -f "$name/package.json" || -f "$name/src-tauri/Cargo.toml" ]] && echo "$name"
    done | sort
  )
fi

FAILED=()
UNPUSHED=()
STALE=()
declare -A NOTE=()

report() { printf '  %-10s %s\n' "$1" "$2"; }

for app in "${APPS[@]}"; do
  wanted "$app" || continue
  dir="${DIR_OF[$app]:-$WORKSPACE/$app}"
  # Say which commit is being checked. Without it, an unexpected error is
  # indistinguishable from checking the wrong tree — and telling those apart by
  # hand costs far more than printing eleven characters.
  commit="$(cd "$dir" && git rev-parse --short HEAD 2>/dev/null)"
  echo "── $app${commit:+ ${DIM}@ $commit${OFF}}"

  # Si hay que correr `bun install` en este directorio.
#
# Falta `node_modules`, o el manifiesto o el candado son más nuevos que él —que
# es como se ve una dependencia agregada después de la última instalación—.
necesita_instalar() {
  local dir="$1"
  [[ ! -d "$dir/node_modules" ]] && return 0
  local f
  for f in package.json bun.lock bun.lockb package-lock.json; do
    [[ -f "$dir/$f" && "$dir/$f" -nt "$dir/node_modules" ]] && return 0
  done
  return 1
}

# ── frontend ───────────────────────────────────────────────────────────────
  if [[ -f "$dir/package.json" ]]; then
    if grep -q 'vue-tsc --noEmit' "$dir/package.json"; then
      if ! have bun; then
        report frontend "${YELLOW}skipped${OFF} ${DIM}(bun not installed)${OFF}"
      else
        # Se instala también cuando `node_modules` está pero quedó viejo.
        #
        # Sólo mirar si existe alcanzaba mientras las dependencias no cambiaran,
        # pero el árbol de fuentes se refresca en cada corrida y su
        # `node_modules` no: una aplicación que suma una dependencia fallaba con
        # «Cannot find module», que parece un error del código y es un
        # `bun install` que faltó. Pasó con el plugin de idiomas en
        # vasak-permissions y con el de iconos en vasak-session-manager, y dejó
        # ocho paquetes sin compilar.
        if [[ $DO_INSTALL -eq 1 ]] && necesita_instalar "$dir"; then
          report frontend "${DIM}installing dependencies…${OFF}"
          (cd "$dir" && bun install >/dev/null 2>&1)
        fi
        if [[ ! -d "$dir/node_modules" ]]; then
          report frontend "${YELLOW}skipped${OFF} ${DIM}(no node_modules)${OFF}"
        else
          out="$(cd "$dir" && bunx vue-tsc --noEmit 2>&1)"
          n="$(grep -c 'error TS' <<<"$out")"
          if [[ "$n" -eq 0 ]]; then
            report frontend "${GREEN}ok${OFF}"
          else
            report frontend "${RED}${n} type error(s)${OFF} ${DIM}— blocks packaging${OFF}"
            grep 'error TS' <<<"$out" | head -5 | sed 's/^/             /'
            FAILED+=("$app (frontend)")
          fi
        fi
      fi
    else
      report frontend "${DIM}not gated on vue-tsc${OFF}"
    fi

    # biome. Se mira el propio biome.json además de los archivos: sus errores de
    # configuración son los que hacían fallar la corrida entera.
    if [[ $DO_LINT -eq 1 ]] && grep -q '"lint"' "$dir/package.json" && have bun; then
      if [[ ! -d "$dir/node_modules" ]]; then
        report lint "${YELLOW}skipped${OFF} ${DIM}(no node_modules)${OFF}"
      else
        out="$(cd "$dir" && bunx --bun biome check . 2>&1)"
        n="$(grep -cE '^[^ ]+\.(ts|vue|js|css|json)[: ]' <<<"$out")"
        if [[ "$n" -eq 0 ]]; then
          report lint "${GREEN}ok${OFF}"
        else
          report lint "${RED}${n} aviso(s) de biome${OFF}"
          grep -E '^[^ ]+\.(ts|vue|js|css|json)[: ]' <<<"$out" | sed 's/ .*//' | head -5 | sed 's/^/             /'
          FAILED+=("$app (biome)")
        fi
      fi
    fi
  fi

  # ── backend ────────────────────────────────────────────────────────────────
  if [[ -f "$dir/src-tauri/Cargo.toml" ]]; then
    if ! have cargo; then
      report backend "${YELLOW}skipped${OFF} ${DIM}(cargo not installed)${OFF}"
    else
      if (cd "$dir/src-tauri" && cargo check --quiet >/dev/null 2>&1); then
        report backend "${GREEN}ok${OFF}"
        # `-D warnings` para que un aviso cuente como fallo: en cero cuesta
        # mantenerlo, y volver a juntar cincuenta cuesta mucho más.
        if [[ $DO_LINT -eq 1 ]]; then
          if (cd "$dir/src-tauri" && cargo clippy --workspace --all-targets --quiet -- -D warnings >/dev/null 2>&1); then
            report clippy "${GREEN}ok${OFF}"
          else
            report clippy "${RED}avisos${OFF}"
            (cd "$dir/src-tauri" && cargo clippy --workspace --all-targets 2>&1 \
              | grep -E '^(warning|error)' | head -5 | sed 's/^/             /')
            FAILED+=("$app (clippy)")
          fi
        fi
        if [[ $RUN_TESTS -eq 1 ]]; then
          if (cd "$dir/src-tauri" && cargo test --lib --quiet >/dev/null 2>&1); then
            report tests "${GREEN}ok${OFF}"
          else
            report tests "${RED}failing${OFF}"
            FAILED+=("$app (tests)")
          fi
        fi
      else
        report backend "${RED}does not compile${OFF}"
        (cd "$dir/src-tauri" && cargo check 2>&1 | grep -E '^error' | head -5 | sed 's/^/             /')
        FAILED+=("$app (backend)")
      fi
    fi
  fi

  # ── git ────────────────────────────────────────────────────────────────────
  if [[ $DO_GIT -eq 1 && ${#DIRS[@]} -eq 0 && -d "$dir/.git" ]]; then
    ahead="$(cd "$dir" && git rev-list --count '@{u}..HEAD' 2>/dev/null)"
    behind="$(cd "$dir" && git rev-list --count 'HEAD..@{u}' 2>/dev/null)"
    dirty="$(cd "$dir" && git status --porcelain 2>/dev/null | wc -l)"
    if [[ -z "$ahead" ]]; then
      report git "${YELLOW}no upstream branch${OFF}"
      UNPUSHED+=("$app")
      NOTE["$app"]="sin rama remota"
    else
      if [[ "$ahead" -gt 0 ]]; then
        report git "${YELLOW}${ahead} commit(s) unpushed${OFF} ${DIM}— makepkg builds the pushed branch${OFF}"
        UNPUSHED+=("$app")
        NOTE["$app"]="$ahead sin pushear"
      fi
      # Behind matters as much as ahead, and is easier to misread. This check
      # runs against the working copy while makepkg builds from the remote, so
      # an out-of-date checkout reports failures for code that was fixed
      # upstream — and blocks a build that would have succeeded.
      if [[ "$behind" -gt 0 ]]; then
        report git "${YELLOW}${behind} commit(s) behind${OFF} ${DIM}— esta copia está vieja; los errores pueden estar ya corregidos${OFF}"
        STALE+=("$app")
        NOTE["$app"]="${NOTE[$app]:+${NOTE[$app]}, }$behind atrás"
      fi
      if [[ "$ahead" -eq 0 && "$behind" -eq 0 && "$dirty" -gt 0 ]]; then
        report git "${DIM}${dirty} uncommitted file(s)${OFF}"
      fi
    fi
  fi
done

echo
echo "════════════════════════════════════════════════════════════════"

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "${RED}No compilan (${#FAILED[@]}):${OFF} ${FAILED[*]}"
else
  echo "${GREEN}Todas las apps compilan.${OFF}"
fi

if [[ ${#STALE[@]} -gt 0 ]]; then
  echo
  echo "${YELLOW}Atención:${OFF} estas copias locales están atrasadas respecto del remoto."
  echo "Esta comprobación lee la copia local, pero makepkg compila desde el remoto:"
  echo "los errores de arriba pueden estar ya corregidos. Actualizá antes de creerles:"
  for app in "${STALE[@]}"; do
    printf '  %-24s %s\n' "$app" "${NOTE[$app]}"
  done
  echo
  echo "  git -C <repo> pull"
fi

if [[ ${#UNPUSHED[@]} -gt 0 ]]; then
  echo
  echo "${YELLOW}Ojo:${OFF} los PKGBUILD compilan desde el remoto, así que estos cambios"
  echo "no entrarían en el paquete hasta hacer push:"
  for app in "${UNPUSHED[@]}"; do
    printf '  %-24s %s\n' "$app" "${NOTE[$app]}"
  done
fi

[[ ${#FAILED[@]} -eq 0 ]]
