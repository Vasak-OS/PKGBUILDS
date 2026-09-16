#!/usr/bin/env bash
#
# Que reconocer un ELF sin lanzar procesos dé el mismo veredicto que `od`.
#
# # Por qué existe
#
# `check-portability.sh` le pregunta a **cada archivo de cada paquete** si es un
# binario, y sólo desensambla los que lo son. Esa pregunta se hacía con un `od`
# por archivo, o sea un proceso por archivo, y la pagaba sobre todo el paquete
# que no tiene un solo binario: `vasakos-icon-theme` tardaba 64,8 segundos
# —cuatro veces más que cualquier otro— lanzando un `od` por cada icono.
#
# Ahora se leen los cuatro bytes con el builtin de bash. El riesgo es el clásico
# de reemplazar una herramienta por código propio: que difieran en algún caso
# raro. Si el nuevo dijera «no es ELF» sobre algo que sí lo es, el paquete
# pasaría el control de portabilidad **sin haberse revisado**, y eso no se ve:
# la salida diría «todos corren en cualquier x86-64».
#
# Uso: pruebas/deteccion-de-elf.sh
set -uo pipefail

fallos=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; }
mal() { printf '  \033[31m✗\033[0m %s\n' "$1"; fallos=$((fallos + 1)); }

# Lo que hace check-portability.sh.
es_elf_builtin() {
    local magia
    LC_ALL=C IFS= read -r -N 4 magia < "$1" 2>/dev/null || return 1
    [[ "$magia" == $'\x7fELF' ]]
}

# La referencia: lo que hacía antes.
es_elf_od() {
    [[ "$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')" == "7f454c46" ]]
}

# Una mezcla a propósito: binarios, bibliotecas, iconos, texto y lo que haya.
mapfile -t archivos < <(
    find /usr/bin /usr/lib /usr/share/icons /usr/share/doc -type f 2>/dev/null | head -600
)

if [ "${#archivos[@]}" -lt 50 ]; then
    mal "sólo se encontraron ${#archivos[@]} archivos para comparar; la prueba no dice nada"
    exit 1
fi

printf '\033[1mComparando el detector contra od sobre %d archivos\033[0m\n' "${#archivos[@]}"

desacuerdos=0
elfs=0
for f in "${archivos[@]}"; do
    a=0; b=0
    es_elf_builtin "$f" && a=1
    es_elf_od "$f" && b=1
    [ "$b" = 1 ] && elfs=$((elfs + 1))
    if [ "$a" != "$b" ]; then
        desacuerdos=$((desacuerdos + 1))
        [ "$desacuerdos" -le 5 ] && printf '      builtin=%s od=%s  %s\n' "$a" "$b" "$f"
    fi
done

if [ "$desacuerdos" -eq 0 ]; then
    ok "mismo veredicto en los ${#archivos[@]} archivos"
else
    mal "$desacuerdos archivo(s) con veredicto distinto"
fi

# Que la muestra haya tenido de los dos, o comparar no prueba nada: un detector
# que dijera «no» siempre coincidiría perfecto sobre una carpeta sin binarios.
if [ "$elfs" -gt 0 ] && [ "$elfs" -lt "${#archivos[@]}" ]; then
    ok "la muestra tenía $elfs ELF y $(( ${#archivos[@]} - elfs )) que no lo son"
else
    mal "la muestra tenía $elfs ELF de ${#archivos[@]}: no sirve para comparar"
fi

# Casos construidos a mano, por si la máquina donde corre esto no tuviera de todo.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf '\177ELF\002\001\001\000resto' > "$tmp/parece-elf"
printf 'no soy un binario, soy texto\n'  > "$tmp/texto"
printf '\177EL'                          > "$tmp/truncado"
: > "$tmp/vacio"

es_elf_builtin "$tmp/parece-elf" && ok 'reconoce la firma ELF' || mal 'no reconoció la firma ELF'
es_elf_builtin "$tmp/texto"      && mal 'tomó un archivo de texto por ELF'      || ok 'descarta el texto'
es_elf_builtin "$tmp/truncado"   && mal 'tomó tres bytes por una firma entera'  || ok 'descarta un archivo más corto que la firma'
es_elf_builtin "$tmp/vacio"      && mal 'tomó un archivo vacío por ELF'         || ok 'descarta el archivo vacío'

echo
if [ "$fallos" -eq 0 ]; then
    printf '\033[32mTodo bien.\033[0m\n'
    exit 0
fi
printf '\033[31m%d comprobación(es) fallaron.\033[0m\n' "$fallos"
exit 1
