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
#       --no-check        Skip the check-all.sh pre-flight.
#   -h, --help            Show this help.
#
# Before building, check-all.sh runs a fast pre-flight: a Tauri PKGBUILD fails on
# a single type error, and finding that out after a full build of the whole set
# wastes a lot of time. It also warns about unpushed commits, since the PKGBUILDs
# fetch with git+https and therefore build the pushed branch, not your working
# copy.
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
CHECK=1
OUTPUT=""

usage() { sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--install) INSTALL=1; shift ;;
    -o|--output) OUTPUT="${2:?--output needs a dir}"; shift 2 ;;
    -x|--exclude) EXCLUDE+=("${2:?--exclude needs a name}"); shift 2 ;;
    -s|--stop) STOP=1; shift ;;
    --no-prefer-git) PREFER_GIT=0; shift ;;
    --no-check) CHECK=0; shift ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

if [[ $EUID -eq 0 ]]; then
  echo "Do not run build-all.sh as root; makepkg must run as a regular user." >&2
  exit 1
fi

command -v makepkg >/dev/null || { echo "makepkg not found (install base-devel)." >&2; exit 1; }

if [[ $CHECK -eq 1 && -x "$REPO_DIR/check-all.sh" ]]; then
  echo "==> Pre-flight: checking every app compiles"
  if ! "$REPO_DIR/check-all.sh"; then
    echo
    echo "!! Aborting: at least one app does not compile, so its package cannot be" >&2
    echo "   produced. Fix it, or re-run with --no-check to build the rest anyway." >&2
    exit 1
  fi
  echo
fi

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
