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
#   backend   `cargo check`
#   git       whether HEAD is ahead of its remote
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
#       --no-install   Don't run `bun install` when node_modules is missing.
#       --no-git       Skip the unpushed-commits check.
#   -h, --help         Show this help.
#
# Exits non-zero if any check fails, so it can gate a build.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$REPO_DIR/.." && pwd)"

ONLY=()
RUN_TESTS=0
DO_INSTALL=1
DO_GIT=1

usage() { sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--app) ONLY+=("${2:?--app needs a name}"); shift 2 ;;
    -t|--tests) RUN_TESTS=1; shift ;;
    --no-install) DO_INSTALL=0; shift ;;
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

# Apps are workspace dirs carrying a frontend or a Tauri backend.
mapfile -t APPS < <(
  cd "$WORKSPACE" && for d in */; do
    name="${d%/}"
    [[ -f "$name/package.json" || -f "$name/src-tauri/Cargo.toml" ]] && echo "$name"
  done | sort
)

FAILED=()
UNPUSHED=()
STALE=()
declare -A NOTE=()

report() { printf '  %-10s %s\n' "$1" "$2"; }

for app in "${APPS[@]}"; do
  wanted "$app" || continue
  dir="$WORKSPACE/$app"
  echo "── $app"

  # ── frontend ───────────────────────────────────────────────────────────────
  if [[ -f "$dir/package.json" ]]; then
    if grep -q 'vue-tsc --noEmit' "$dir/package.json"; then
      if ! have bun; then
        report frontend "${YELLOW}skipped${OFF} ${DIM}(bun not installed)${OFF}"
      else
        if [[ ! -d "$dir/node_modules" && $DO_INSTALL -eq 1 ]]; then
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
  fi

  # ── backend ────────────────────────────────────────────────────────────────
  if [[ -f "$dir/src-tauri/Cargo.toml" ]]; then
    if ! have cargo; then
      report backend "${YELLOW}skipped${OFF} ${DIM}(cargo not installed)${OFF}"
    else
      if (cd "$dir/src-tauri" && cargo check --quiet >/dev/null 2>&1); then
        report backend "${GREEN}ok${OFF}"
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
  if [[ $DO_GIT -eq 1 && -d "$dir/.git" ]]; then
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
