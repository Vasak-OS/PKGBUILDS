#!/usr/bin/env bash
#
# build-all.sh — build every VasakOS package in this repo (except Calamares).
#
# For each package directory that contains a PKGBUILD it runs `makepkg`. When
# both a release and a VCS variant exist (e.g. vasak-desktop and
# vasak-desktop-git), the `-git` one is preferred and the twin skipped. Results
# are summarised at the end; by default a failure does not stop the run.
#
# Usage:
#   ./build-all.sh [options]
#
# Options:
#   -i, --install         Also install each package (makepkg -i).
#   -o, --output DIR      Copy built packages into DIR.
#   -x, --exclude NAME    Skip package dir NAME (repeatable).
#   -s, --stop            Stop on the first failure (default: keep going).
#       --no-prefer-git   Do not skip release twins in favour of -git.
#   -h, --help            Show this help.
#
# makepkg runs with: -sf --noconfirm --needed  (installs deps, overwrites).
# Do not run as root — makepkg refuses to.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Calamares is intentionally excluded.
EXCLUDE=(vasakos-calamares vasakos-calamares-config)
INSTALL=0
STOP=0
PREFER_GIT=1
OUTPUT=""

usage() { sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--install) INSTALL=1; shift ;;
    -o|--output) OUTPUT="${2:?--output needs a dir}"; shift 2 ;;
    -x|--exclude) EXCLUDE+=("${2:?--exclude needs a name}"); shift 2 ;;
    -s|--stop) STOP=1; shift ;;
    --no-prefer-git) PREFER_GIT=0; shift ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

if [[ $EUID -eq 0 ]]; then
  echo "Do not run build-all.sh as root; makepkg must run as a regular user." >&2
  exit 1
fi

command -v makepkg >/dev/null || { echo "makepkg not found (install base-devel)." >&2; exit 1; }

[[ -n "$OUTPUT" ]] && mkdir -p "$OUTPUT"

is_excluded() {
  local name="$1" e
  for e in "${EXCLUDE[@]}"; do [[ "$name" == "$e" ]] && return 0; done
  return 1
}

# Collect candidate package dirs (those with a PKGBUILD).
mapfile -t ALL < <(cd "$REPO_DIR" && for d in */; do [[ -f "${d}PKGBUILD" ]] && echo "${d%/}"; done | sort)

TARGETS=()
for name in "${ALL[@]}"; do
  is_excluded "$name" && continue
  # Prefer the -git twin: skip "foo" when "foo-git" also exists.
  if [[ $PREFER_GIT -eq 1 && "$name" != *-git && -f "$REPO_DIR/${name}-git/PKGBUILD" ]]; then
    continue
  fi
  TARGETS+=("$name")
done

echo "==> Building ${#TARGETS[@]} package(s): ${TARGETS[*]}"
echo

MK_ARGS=(-sf --noconfirm --needed)
[[ $INSTALL -eq 1 ]] && MK_ARGS+=(-i)

OK=()
FAIL=()
for name in "${TARGETS[@]}"; do
  echo "──────────────────────────────────────────────────────────────"
  echo "==> $name"
  if ( cd "$REPO_DIR/$name" && makepkg "${MK_ARGS[@]}" ); then
    OK+=("$name")
    if [[ -n "$OUTPUT" ]]; then
      cp -f "$REPO_DIR/$name"/*.pkg.tar.* "$OUTPUT"/ 2>/dev/null || true
    fi
  else
    FAIL+=("$name")
    echo "!! build failed: $name" >&2
    [[ $STOP -eq 1 ]] && break
  fi
done

echo
echo "════════════════════════════════════════════════════════════════"
echo "Built OK (${#OK[@]}): ${OK[*]:-none}"
echo "Failed  (${#FAIL[@]}): ${FAIL[*]:-none}"
[[ -n "$OUTPUT" ]] && echo "Packages copied to: $OUTPUT"
[[ ${#FAIL[@]} -eq 0 ]]
