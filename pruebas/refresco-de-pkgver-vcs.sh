#!/usr/bin/env bash
#
# Que build-all.sh refresque por omisión el pkgver() de los paquetes -git.
#
# `makepkg --printsrcinfo` no corre `pkgver()`, así que sin el refresco el
# «¿está al día?» se decide con el `pkgver=` estático de la receta: un -git cuyo
# valor viejo coincide con lo publicado queda saltado para siempre aunque
# upstream avance. El refresco (`makepkg -o`) es ahora el comportamiento por
# omisión y `--no-refresh-vcs` es el camino rápido.
#
# Sin red: una receta de juguete, sin fuentes, cuyo `pkgver()` escribe un
# archivo centinela. Que el centinela aparezca es la prueba de que `makepkg -o`
# corrió, que es lo que el refresco hace. Se copia build-all.sh a un directorio
# temporal para que la receta de juguete sea la única del «repositorio».
#
# Uso: pruebas/refresco-de-pkgver-vcs.sh
#      BUILD_ALL=/ruta/a/otro/build-all.sh pruebas/refresco-de-pkgver-vcs.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
REPO_DIR="$PWD"
BUILD_ALL="${BUILD_ALL:-$REPO_DIR/build-all.sh}"

fallos=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
mal()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fallos=$((fallos + 1)); }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# Corre build-all.sh en seco sobre una copia con una sola receta -git y devuelve
# si el centinela de pkgver() apareció. Argumentos: las opciones a probar.
corre() {
  local sandbox="$T/$RANDOM" centinela
  mkdir -p "$sandbox/repo/lib" "$sandbox/repo/juguete-git" "$sandbox/publicado"
  cp "$BUILD_ALL" "$sandbox/repo/build-all.sh"
  cp "$REPO_DIR"/lib/*.sh "$sandbox/repo/lib/"
  centinela="$sandbox/centinela"
  cat > "$sandbox/repo/juguete-git/PKGBUILD" <<PKG
pkgname=juguete-git
pkgver=1
pkgrel=1
arch=('any')
source=()
pkgver() { touch "$centinela"; echo 2; }
package() { :; }
PKG
  SRCINFO_CACHE="$sandbox/cache" bash "$sandbox/repo/build-all.sh" \
    --dry-run --no-check --repo "$sandbox/publicado" "$@" >"$sandbox/salida" 2>&1
  [[ -e "$centinela" ]] && echo si || { echo no; sed 's/^/      /' "$sandbox/salida" >&2; }
}

printf '\033[1mRefresco de pkgver() de los -git\033[0m\n'

[[ "$(corre)" == si ]] \
  && ok 'sin opciones, build-all.sh refresca el pkgver() del -git' \
  || mal 'sin opciones, build-all.sh NO refresca el pkgver() del -git (el default es el viejo)'

[[ "$(corre --refresh-vcs)" == si ]] \
  && ok '--refresh-vcs sigue aceptada y refresca' \
  || mal '--refresh-vcs dejó de refrescar'

[[ "$(corre --no-refresh-vcs)" == no ]] \
  && ok '--no-refresh-vcs no refresca' \
  || mal '--no-refresh-vcs refrescó igual (o la opción no existe)'

echo
if [[ $fallos -eq 0 ]]; then echo "Todo bien."; else echo "$fallos fallo(s)."; exit 1; fi
