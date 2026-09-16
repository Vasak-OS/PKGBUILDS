#!/usr/bin/env bash
#
# Que recordar el veredicto de portabilidad no cambie el veredicto.
#
# # Por qué existe
#
# Revisar un paquete desensambla cada binario que tiene adentro: los treinta y
# cuatro del repositorio tardaban 49 segundos. Como el resultado depende sólo de
# los bytes del paquete —y un `.pkg.tar.zst` no cambia nunca después de
# construido—, el veredicto se guarda y una corrida donde no se construyó nada
# tarda menos de medio segundo.
#
# El riesgo es el de toda caché: servir una respuesta vieja. Acá eso significaría
# **firmar y publicar un paquete que nunca se revisó**, y no se vería — la salida
# diría «todos corren en cualquier x86-64». Por eso la clave lleva el hash del
# paquete y el de este script, y esta prueba comprueba las dos mitades.
#
# Uso: pruebas/cache-de-portabilidad.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
REPO_DIR="$PWD"

fallos=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; }
mal() { printf '  \033[31m✗\033[0m %s\n' "$1"; fallos=$((fallos + 1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export PORTABILIDAD_CACHE="$tmp/cache"

# Un paquete de verdad, chiquito: un ELF real adentro de un tar comprimido, que
# es lo que el script sabe leer.
mkdir -p "$tmp/contenido/usr/bin"
cp /bin/true "$tmp/contenido/usr/bin/programa" 2>/dev/null || {
    echo "No se pudo armar el paquete de prueba." >&2; exit 1; }
printf 'pkgname = prueba\npkgver = 1-1\n' > "$tmp/contenido/.PKGINFO"
paquete="$tmp/prueba-1-1-x86_64.pkg.tar.zst"
( cd "$tmp/contenido" && bsdtar -caf "$paquete" .PKGINFO usr ) || {
    echo "No se pudo empaquetar." >&2; exit 1; }

printf '\033[1mPrimera revisión, sin nada recordado\033[0m\n'
primera="$(./check-portability.sh --un-paquete "$paquete" 2>&1)"; estado1=$?
ok "revisado (salida $estado1)"

entradas=$(find "$PORTABILIDAD_CACHE" -name '*.veredicto' 2>/dev/null | wc -l)
if [ "$entradas" -eq 1 ]; then
    ok 'quedó guardado un veredicto'
else
    mal "se esperaba un veredicto guardado y hay $entradas"
fi

printf '\n\033[1mSegunda revisión, con el veredicto recordado\033[0m\n'
segunda="$(./check-portability.sh --un-paquete "$paquete" 2>&1)"; estado2=$?

if [ "$primera" = "$segunda" ]; then
    ok 'la salida recordada es idéntica a la calculada'
else
    mal 'la salida cambió al recordarla'
    diff <(printf '%s\n' "$primera") <(printf '%s\n' "$segunda") | sed 's/^/      /'
fi
if [ "$estado1" -eq "$estado2" ]; then
    ok "el veredicto se mantiene (salida $estado2)"
else
    mal "el veredicto cambió: $estado1 y después $estado2"
fi

printf '\n\033[1mLo que tiene que invalidarla\033[0m\n'

# Otro paquete, con otros bytes: tiene que revisarse aparte y no heredar el
# veredicto del anterior.
cp /bin/ls "$tmp/contenido/usr/bin/programa" 2>/dev/null
otro="$tmp/otro-1-1-x86_64.pkg.tar.zst"
( cd "$tmp/contenido" && bsdtar -caf "$otro" .PKGINFO usr )
./check-portability.sh --un-paquete "$otro" >/dev/null 2>&1
entradas=$(find "$PORTABILIDAD_CACHE" -name '*.veredicto' 2>/dev/null | wc -l)
if [ "$entradas" -eq 2 ]; then
    ok 'un paquete con otros bytes se revisa aparte'
else
    mal "se esperaban dos veredictos guardados y hay $entradas: un paquete distinto reusó el ajeno"
fi

# Y que la clave lleve el hash del script: si cambia cómo se mira, lo mirado
# antes no vale. Se comprueba que el nombre del archivo lo contenga.
hash_script="$(sha256sum <"$REPO_DIR/check-portability.sh" | cut -c1-12)"
if find "$PORTABILIDAD_CACHE" -name "*-$hash_script.veredicto" | grep -q .; then
    ok 'la clave incluye el hash del script que produjo el veredicto'
else
    mal 'la clave no depende del script: cambiar el detector no volvería a revisar nada'
fi

echo
if [ "$fallos" -eq 0 ]; then
    printf '\033[32mTodo bien.\033[0m\n'
    exit 0
fi
printf '\033[31m%d comprobación(es) fallaron.\033[0m\n' "$fallos"
exit 1
