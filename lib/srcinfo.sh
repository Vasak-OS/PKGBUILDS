#!/usr/bin/env bash
#
# El `.SRCINFO` de cada receta: una sola vez, en paralelo, y recordado.
#
# # Por qué existe
#
# Saber qué hay que reconstruir no debería costar tres minutos, y costaba.
# Medido sobre las 32 recetas de este repositorio, `build-all.sh --dry-run`
# tardaba **174 segundos** sin compilar nada. El tiempo no estaba en ningún
# paso lento: estaba en llamar a `makepkg` dos veces por receta —una para
# `--printsrcinfo` y otra para `--packagelist`— y en serie. Cada invocación
# cuesta cerca de un segundo porque `makepkg` lanza unos doscientos procesos
# para leer un PKGBUILD, uno por cada campo que puede tener.
#
# Acá se ataca por los tres lados:
#
#   1. **Una sola llamada.** El `.SRCINFO` ya contiene todo lo que hace falta
#      para saber cómo se van a llamar los paquetes, así que `--packagelist`
#      sobra. Ver `srcinfo_paquetes`.
#   2. **En paralelo.** Las recetas no dependen entre sí para esto.
#   3. **Recordado.** La salida depende sólo del texto del PKGBUILD y de la
#      configuración de makepkg, así que se guarda bajo el hash de los dos. Una
#      corrida donde no se tocó ninguna receta no llama a `makepkg` ni una vez.
#
# La caché no puede quedar vieja por construcción: si el PKGBUILD cambia, cambia
# su hash y la entrada es otra. Eso cubre también `--refresh-vcs`, que actualiza
# el `pkgver=` **escribiendo el PKGBUILD**, así que invalida su propia entrada
# sin que nadie tenga que acordarse.
#
# Uso:
#   source lib/srcinfo.sh
#   srcinfo_precalentar dir1 dir2 ...   # las calcula todas juntas
#   srcinfo_de dir                      # el texto
#   srcinfo_paquetes dir                # las rutas de los paquetes que produce

SRCINFO_CACHE="${SRCINFO_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/vasakos-pkgbuilds/srcinfo}"

# Cuántas recetas a la vez. Esto es E/S y arranque de procesos, no cálculo, así
# que conviene pasarse de los núcleos en vez de quedarse corto.
SRCINFO_PARALELO="${SRCINFO_PARALELO:-$(( $(nproc 2>/dev/null || echo 4) * 2 ))}"

# El hash de la configuración de makepkg, calculado una vez por corrida.
#
# Va en la clave porque `PKGEXT` y `CARCH` salen de ahí y los dos cambian el
# nombre de los paquetes: sin esto, tocar makepkg.conf dejaría la caché
# devolviendo nombres de la configuración anterior.
_srcinfo_entorno() {
    if [[ -z "${_SRCINFO_ENTORNO:-}" ]]; then
        _SRCINFO_ENTORNO="$(
            cat /etc/makepkg.conf /etc/makepkg.conf.d/*.conf 2>/dev/null |
                sha256sum | cut -c1-12
        )"
    fi
    printf '%s' "$_SRCINFO_ENTORNO"
}

declare -gA _SRCINFO_RUTA=()

# Calcula de una sola vez el hash de varios PKGBUILD.
#
# `sha256sum` con todos los archivos en una invocación en lugar de una por
# receta: con 32 recetas eso es un proceso en lugar de 32, y esta función la
# llama todo el mundo antes de mirar nada.
_srcinfo_rutas_de() {
    local dir archivos=() hash ruta entorno
    entorno="$(_srcinfo_entorno)"

    for dir in "$@"; do
        [[ -n "${_SRCINFO_RUTA[$dir]:-}" ]] && continue
        [[ -f "$dir/PKGBUILD" ]] && archivos+=("$dir/PKGBUILD")
    done
    [[ ${#archivos[@]} -eq 0 ]] && return 0

    while read -r hash ruta; do
        [[ -n "$hash" && -n "$ruta" ]] || continue
        _SRCINFO_RUTA["${ruta%/PKGBUILD}"]="$SRCINFO_CACHE/${hash:0:32}-$entorno.srcinfo"
    done < <(sha256sum "${archivos[@]}" 2>/dev/null)
    return 0
}

# `CARCH` y `PKGEXT`, leídos una vez por corrida.
#
# Salían de un subshell que hacía `source /etc/makepkg.conf` **en cada**
# derivación: dos procesos por receta para leer dos variables que no cambian.
_srcinfo_config() {
    [[ -n "${_SRCINFO_CARCH:-}" ]] && return 0
    local carch ext
    eval "$(grep -E '^(CARCH|PKGEXT)=' /etc/makepkg.conf 2>/dev/null)"
    _SRCINFO_CARCH="${CARCH:-x86_64}"
    _SRCINFO_PKGEXT="${PKGEXT:-.pkg.tar.zst}"
    return 0
}

# La ruta de caché que le toca a una receta.
_srcinfo_ruta() {
    [[ -n "${_SRCINFO_RUTA[$1]:-}" ]] || _srcinfo_rutas_de "$1"
    [[ -n "${_SRCINFO_RUTA[$1]:-}" ]] || return 1
    printf '%s' "${_SRCINFO_RUTA[$1]}"
}

# Calcula las que falten, todas juntas.
#
# Se le pasan los directorios y devuelve cuando están todas en la caché. Lo que
# ya estaba no se vuelve a calcular.
srcinfo_precalentar() {
    local dir ruta faltan=()
    mkdir -p "$SRCINFO_CACHE" || return 1
    _srcinfo_rutas_de "$@"

    for dir in "$@"; do
        ruta="$(_srcinfo_ruta "$dir")" || continue
        [[ -s "$ruta" ]] && continue
        faltan+=("$dir" "$ruta")
    done

    [[ ${#faltan[@]} -eq 0 ]] && return 0

    # En pares directorio/destino, separados por NUL: hay rutas con espacios y
    # no hay por qué confiar en que nunca los haya.
    printf '%s\0' "${faltan[@]}" |
        xargs -0 -P "$SRCINFO_PARALELO" -n 2 sh -c '
            # A un archivo temporal y después se mueve: si la corrida se corta a
            # la mitad, lo que quede en la caché tiene que ser una entrada
            # entera o ninguna, nunca media.
            tmp="$2.$$"
            if (cd "$1" && makepkg --printsrcinfo) >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then
                mv -f "$tmp" "$2"
            else
                rm -f "$tmp"
            fi
        ' _
    return 0
}

# Olvida lo que se recordaba de una receta.
#
# Hace falta cuando algo **reescribe el PKGBUILD durante la corrida**, que es
# exactamente lo que hace `--refresh-vcs`: `makepkg -o` actualiza el `pkgver=`
# en el archivo. El contenido nuevo tiene otro hash y por lo tanto otra entrada
# de caché, pero la ruta ya calculada quedó memorizada en esta misma corrida y
# seguiría apuntando a la anterior.
srcinfo_olvidar() {
    local dir
    for dir in "$@"; do unset "_SRCINFO_RUTA[$dir]"; done
    return 0
}

# El `.SRCINFO` de una receta. Vacío si `makepkg` no la pudo leer.
srcinfo_de() {
    local ruta
    ruta="$(_srcinfo_ruta "$1")" || return 0
    [[ -s "$ruta" ]] || srcinfo_precalentar "$1"
    [[ -s "$ruta" ]] && cat "$ruta"
    return 0
}

# Las rutas de los paquetes que una receta va a producir.
#
# Es lo que imprime `makepkg --packagelist`, derivado del `.SRCINFO` en vez de
# pagando otra invocación de `makepkg`. Hay una prueba
# —`pruebas/nombres-de-paquete.sh`— que compara las dos salidas receta por
# receta: si alguna vez dejan de coincidir, el script creería que un paquete
# publicado falta y lo reconstruiría para siempre.
#
# `any` es lo único que cambia el arch del nombre; cualquier otra cosa se
# construye para `CARCH`. Un subpaquete puede declarar el suyo y pisa al de
# `pkgbase`.
srcinfo_paquetes() {
    local dir="$1" info
    info="$(srcinfo_de "$dir")"
    [[ -n "$info" ]] || return 0

    _srcinfo_config

    # Absoluta, como la imprime `makepkg --packagelist`: quien llama compara
    # contra esa salida y con una ruta relativa el `-f` fallaría según desde
    # dónde se haya corrido el script.
    [[ "$dir" == /* ]] || dir="$PWD/$dir"

    awk -v CARCH="$_SRCINFO_CARCH" -v EXT="$_SRCINFO_PKGEXT" -v DIR="$dir" '
        BEGIN { FS = " = "; n = 0 }
        /^pkgbase = / { seccion = "base"; next }
        /^pkgname = / { n++; nombre[n] = $2; seccion = "pkg"; next }
        NF < 2 { next }
        {
            clave = $1; sub(/^[ \t]+/, "", clave)
            if (seccion == "base") {
                if (clave == "pkgver") pkgver = $2
                else if (clave == "pkgrel") pkgrel = $2
                else if (clave == "epoch") epoch = $2
                else if (clave == "arch") base_arch = (base_arch == "" ? $2 : base_arch " " $2)
            } else if (clave == "arch") {
                propio[n] = (propio[n] == "" ? $2 : propio[n] " " $2)
            }
        }
        END {
            for (i = 1; i <= n; i++) {
                a = (propio[i] != "" ? propio[i] : base_arch)
                arch = (a == "any" ? "any" : CARCH)
                ver = (epoch != "" ? epoch ":" : "") pkgver "-" pkgrel
                print DIR "/" nombre[i] "-" ver "-" arch EXT
            }
        }
    ' <<<"$info"
}
