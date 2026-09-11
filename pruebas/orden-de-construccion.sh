#!/usr/bin/env bash
#
# Que el orden de construcción respete las dependencias entre paquetes propios.
#
# La invariante es una sola: si A necesita a B y los dos salen de este
# repositorio, B tiene que construirse antes. Cuando no se cumple, `makepkg`
# corta con «target not found» — y lo hace después de haber compilado todo lo
# que venía antes, que en esta tanda son minutos largos.
#
# Esto existía como una lista escrita a mano (`FIRST=(vasak-permissions)`) y
# quedó vieja en cuanto `vasak-desktop-settings` pasó a depender de
# `vasak-wayfire-plugins`: la `d` va antes que la `w` en el alfabeto. Ahora el
# orden sale de los propios PKGBUILD; esta prueba comprueba que efectivamente
# salga bien, porque un orden mal calculado se ve igual que uno bien calculado
# hasta que falla la compilación.
#
# Uso: pruebas/orden-de-construccion.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

fallos=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
mal()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fallos=$((fallos + 1)); }

printf '\033[1mLeyendo las recetas\033[0m\n'

declare -A DIR_DE_PKG=()
declare -A DEPS_DE_DIR=()
dirs=()

for d in */; do
    d=${d%/}
    [ -f "$d/PKGBUILD" ] || continue
    info=$(cd "$d" && makepkg --printsrcinfo 2>/dev/null)
    if [ -z "$info" ]; then
        mal "$d: makepkg no pudo leer el PKGBUILD"
        continue
    fi
    dirs+=("$d")
    while IFS= read -r n; do
        [ -n "$n" ] && DIR_DE_PKG["$n"]="$d"
    done < <(sed -n 's/^pkgname = //p' <<<"$info")
    DEPS_DE_DIR["$d"]=$(
        sed -n 's/^[[:space:]]*\(make\|check\)\?depends = //p' <<<"$info" |
            sed -E 's/[<>=].*$//' | sort -u | tr '\n' ' '
    )
done

printf '  %s recetas\n' "${#dirs[@]}"

printf '\n\033[1mEl orden que produce build-all.sh\033[0m\n'

# Se le pregunta al script de verdad y no se recalcula acá: una prueba que
# reimplementa lo que prueba sólo comprueba que dos copias coincidan.
mapfile -t orden < <(
    ./build-all.sh --dry-run --no-check --no-repo 2>/dev/null |
        sed -n 's/^==> Will build [0-9]* package(s): //p' | tr ' ' '\n' | grep -v '^$'
)

if [ "${#orden[@]}" -eq 0 ]; then
    mal 'build-all.sh --dry-run no dijo qué construiría'
    printf '\n\033[31mNo se pudo comprobar nada.\033[0m\n'
    exit 1
fi
ok "${#orden[@]} paquetes en la lista"

if [ "${#orden[@]}" -ne "${#dirs[@]}" ]; then
    # Una receta que se pierde entre el listado y el orden es la peor forma de
    # fallar: no se construye y nadie lo nota hasta que falta el paquete.
    mal "hay ${#dirs[@]} recetas y el orden trae ${#orden[@]}"
else
    ok 'están todas'
fi

declare -A POSICION=()
for i in "${!orden[@]}"; do POSICION["${orden[$i]}"]=$i; done

printf '\n\033[1mCada dependencia propia va antes\033[0m\n'

pares=0
desordenados=0
for d in "${dirs[@]}"; do
    for dep in ${DEPS_DE_DIR["$d"]:-}; do
        antes="${DIR_DE_PKG[$dep]:-}"
        # Sólo las que salen de este repositorio: las de Arch ya están.
        [ -n "$antes" ] && [ "$antes" != "$d" ] || continue
        pares=$((pares + 1))
        pa="${POSICION[$antes]:-}"
        pd="${POSICION[$d]:-}"
        if [ -z "$pa" ] || [ -z "$pd" ]; then
            mal "$d necesita $dep ($antes) y alguno no está en el orden"
            desordenados=$((desordenados + 1))
        elif [ "$pa" -ge "$pd" ]; then
            mal "$d (posición $pd) necesita $dep, que se construye en la $pa"
            desordenados=$((desordenados + 1))
        fi
    done
done

if [ "$pares" -eq 0 ]; then
    # Si nunca hay un par, la prueba no comprueba nada y no lo dice. Pasó con
    # otra prueba de este proyecto que daba verde con la lista vacía.
    mal 'no se encontró ninguna dependencia entre paquetes propios: la prueba no comprobó nada'
elif [ "$desordenados" -eq 0 ]; then
    ok "$pares dependencias entre paquetes propios, todas en orden"
else
    mal "$desordenados de $pares dependencias quedaron al revés"
fi

printf '\n'
if [ "$fallos" -eq 0 ]; then
    printf '\033[32mTodo bien.\033[0m\n'
else
    printf '\033[31m%s comprobación(es) fallaron.\033[0m\n' "$fallos"
fi
exit "$((fallos > 0 ? 1 : 0))"
