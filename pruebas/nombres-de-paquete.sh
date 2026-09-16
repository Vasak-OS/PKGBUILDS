#!/usr/bin/env bash
#
# Que los nombres de paquete derivados del `.SRCINFO` sean **los mismos** que
# imprime `makepkg --packagelist`.
#
# # Por qué existe
#
# `build-all.sh` decide qué reconstruir comparando los nombres que una receta va
# a producir contra lo que hay publicado en el repositorio. Esos nombres salían
# de `makepkg --packagelist`, una invocación por receta además de la de
# `--printsrcinfo`: entre las dos, saber qué había que construir costaba 174
# segundos sin compilar nada. Ahora salen del `.SRCINFO`, que ya se lee, y la
# decisión entera tarda menos de un segundo.
#
# El riesgo de haberlo hecho así es de los que no se ven: si la derivación y
# `makepkg` dejan de coincidir —un `epoch`, un subpaquete con su propio `arch`,
# un `PKGEXT` distinto—, el script cree que un paquete ya publicado falta y lo
# reconstruye **todas las veces**, o peor, cree que uno que cambió ya está y no
# lo sube nunca. Nada de eso da error: da una corrida que parece normal.
#
# Por eso esto compara las dos salidas receta por receta contra el `makepkg` de
# verdad. Es la única prueba que puede notar que la optimización se rompió.
#
# Uso: pruebas/nombres-de-paquete.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
REPO_DIR="$PWD"
# shellcheck source=../lib/srcinfo.sh
source "$REPO_DIR/lib/srcinfo.sh"

fallos=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; }
mal() { printf '  \033[31m✗\033[0m %s\n' "$1"; fallos=$((fallos + 1)); }

mapfile -t dirs < <(for d in */; do [ -f "${d}PKGBUILD" ] && echo "$REPO_DIR/${d%/}"; done)
if [ ${#dirs[@]} -eq 0 ]; then
    echo "No hay recetas que comprobar." >&2
    exit 1
fi

printf '\033[1mDerivando los nombres de %d recetas\033[0m\n' "${#dirs[@]}"
srcinfo_precalentar "${dirs[@]}"

comprobadas=0
for dir in "${dirs[@]}"; do
    nombre="${dir##*/}"

    # La referencia es `makepkg` mismo. Se filtran los paquetes de depuración
    # porque son un subproducto de las OPTIONS y nunca se publican; el
    # `.SRCINFO` tampoco los nombra.
    if ! esperado="$(cd "$dir" && makepkg --packagelist 2>/dev/null | grep -v -- '-debug-')"; then
        esperado=""
    fi
    if [ -z "$esperado" ]; then
        mal "$nombre: makepkg no pudo leer el PKGBUILD"
        continue
    fi

    obtenido="$(srcinfo_paquetes "$dir")"
    if [ "$obtenido" = "$esperado" ]; then
        comprobadas=$((comprobadas + 1))
    else
        mal "$nombre: los nombres no coinciden"
        diff <(printf '%s\n' "$esperado") <(printf '%s\n' "$obtenido") | sed 's/^/      /'
    fi
done

[ "$comprobadas" -gt 0 ] && ok "$comprobadas receta(s) con los mismos nombres que makepkg"

# Que la caché no invente: dos lecturas seguidas tienen que dar lo mismo, y la
# segunda sin volver a llamar a makepkg.
primera="$(srcinfo_paquetes "${dirs[0]}")"
segunda="$(srcinfo_paquetes "${dirs[0]}")"
if [ "$primera" = "$segunda" ]; then
    ok "leer dos veces la misma receta da lo mismo"
else
    mal "la segunda lectura difiere de la primera"
fi

# Y que olvidar una receta no cambie lo que devuelve: sólo obliga a recalcularla.
srcinfo_olvidar "${dirs[0]}"
tercera="$(srcinfo_paquetes "${dirs[0]}")"
if [ "$tercera" = "$primera" ]; then
    ok "olvidar una receta la recalcula sin cambiar el resultado"
else
    mal "tras olvidarla, la receta devuelve algo distinto"
fi

echo
if [ "$fallos" -eq 0 ]; then
    printf '\033[32mTodo bien.\033[0m\n'
    exit 0
fi
printf '\033[31m%d comprobación(es) fallaron.\033[0m\n' "$fallos"
exit 1
