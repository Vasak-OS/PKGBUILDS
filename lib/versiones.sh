#!/usr/bin/env bash
#
# La versión de un proyecto, leída de su propio manifiesto.
#
# # Por qué existe
#
# Cinco recetas tenían el `pkgver=` escrito a mano. Como nadie lo recalcula, la
# versión derivaba: `vasak-accounts` iba **cuatro versiones** atrás (0.13.0 en
# la receta, 0.17.3 en el repo), `vasak-contacts` cinco parches. El ISO se
# armaba con metadatos de versión equivocados, y toda comparación de
# dependencias que los use hereda el error.
#
# Que la deriva fuera silenciosa es lo que la hacía difícil de ver. Un paquete
# con la versión vieja se publica, se instala y anda: nada falla. Lo único que
# delata el número es ir a mirarlo.
#
# # Qué versión se usa, y por qué no lleva el hash
#
# La versión es la que declara el proyecto: `package.json` o `tauri.conf.json`
# para las aplicaciones Tauri, `Cargo.toml` para los demonios de Rust.
#
# **No** se le agrega `.rN.gHASH`, que es lo que hacen los otros paquetes `-git`
# de este repo. Acá el sufijo `-git` del nombre del directorio está para marcar
# **procedencia** —que el paquete sale del repo y no de los `.deb` ya
# compilados de los releases—, no para adoptar la convención de versions de
# VCS. La nomenclatura es estable, y es una decisión del usuario.
#
# La consecuencia, para que nadie la descubra por sorpresa: si el upstream hace
# commit sin cambiar su versión, el `pkgver` no se mueve y `build-all.sh` va a
# decir que el paquete está al día. El escape ya está documentado en
# `build-all.sh`: **nombrar el directorio fuerza el rebuild** (línea 29, "el
# escape hatch para reconstruir un `-git` cuyo pkgver no cambió pero cuyo
# upstream sí").
#
# # Por qué la sección importa
#
# En los `Cargo.toml` de este workspace la línea `version =` correcta aparece
# **antes** de `[workspace.dependencies]`, así que un `grep -m1 '^version'`
# acierta por casualidad. No se puede confiar en ese orden: `vasak-accounts`
# tiene docenas de `version = "1"` en dependencias, y mañana alguien mete
# `[dependencies]` arriba de `[package]` y el `grep` se rompe en silencio
# entregando la versión de una dependencia.
#
# Por eso `version_de_cargo` entra en la sección correcta y corta en el
# próximo `[`. El orden del archivo deja de importar.
#
# # Por qué los tres manifiestos tienen que coincidir
#
# En una aplicación Tauri la versión está escrita en tres lugares:
# `package.json`, `src-tauri/tauri.conf.json` y `src-tauri/Cargo.toml`. El CI
# ya tiene un paso que los compara y falla si divergen
# (`.github-shared/.github/workflows/app.yml`, "Los manifiestos dicen la misma
# versión").
#
# Acá se vuelve a comparar, y no es paranoia: durante el trabajo que motivó
# esta librería, dos PRs seguidos del mismo agente fallaron ese check por
# haber bumpeado `Cargo.toml` y no los otros dos. Es un olvido que se repite y
# que nadie ve hasta que el CI lo dice. Que el packaging sea el **cuarto**
# lugar donde se descubre sería una obligación innecesaria. Si divergen, esta
# función falla con ruido en vez de elegir una y seguir.
#
# Uso:
#   source lib/versiones.sh
#   version=$(version_de_arbol "$srcdir/$pkgname")
#
# Devuelve la versión pelada, sin sufijo. Sale por stdout; los errores, por
# stderr, y con código distinto de cero.

# Extrae `version` de la sección indicada de un `Cargo.toml`.
#
# Los secciones son `[package]` y `[workspace.package]`. No se usa `awk` con
# expresión regular sobre el nombre de la sección porque hay que separar el
# `workspace.package` del `package` sin que uno sea prefijo del otro a ojos de
# la comparación.
version_de_cargo() {
    local archivo="$1" seccion="$2" dentro=0

    [ -f "$archivo" ] || return 1

    while IFS= read -r linea || [ -n "$linea" ]; do
        case "$linea" in
            '['*)
                # Fin de la sección: en cuanto se abre otra, se terminó.
                [ "$dentro" -eq 1 ] && break
                # `[[package]]` es otra cosa; acá interesa la línea pelada.
                if [ "$linea" = "[$seccion]" ]; then
                    dentro=1
                fi
                ;;
            version*)
                [ "$dentro" -eq 1 ] || continue
                # `version = "1.2.3"`, admitiendo espacios alrededor del `=`.
                local valor
                valor="$(printf '%s' "$linea" | sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p')"
                [ -n "$valor" ] && { printf '%s' "$valor"; return 0; }
                ;;
        esac
    done < "$archivo"

    return 1
}

# Extrae `"version": "1.2.3"` de un JSON de nivel superior.
#
# `package.json` y `tauri.conf.json` lo tienen así, con dos espacios de
# indentación. Se toma **la primera** aparición: en `package.json` las claves
# anidadas de `dependencies` pueden traer su propio `"version"`, pero siempre
# están después de la de nivel superior, que es la que describe el paquete.
version_de_json() {
    local archivo="$1"
    [ -f "$archivo" ] || return 1
    sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$archivo" | head -1
}

# La versión de un árbol de fuentes ya extraído.
# El árbol, no el `PKGBUILD`: `makpkg` llama a `pkgver()` con los fuentes ya
# en `$srcdir`, y es ahí donde está el manifiesto. No se usa la red ni `git`:
# `pkgver()` se invoca más de una vez por construcción, y en contextos donde
# el `.git` ya no está, así que lo único que puede leer son los archivos.
version_de_arbol() {
    local arbol="$1"
    local -a declaradas=() rutas=()

    # Se juntan **todas** las versiones que el árbol declara, de donde sean, y
    # se exige que digan lo mismo. No se elige una ni se prioriza un archivo.
    #
    # Que las cinco recetas tengan layouts distintos —dos demos Rust de
    # workspace, una app Tauri de raíz plana, y un híbrido que es workspace
    # Cargo *y* aplicación Tauri— es justo el motivo por el que una regla "si es
    # Tauri tomá `package.json`" se rompe: el híbrido declara cuatro versiones
    # repartidas en tres archivos, y la regla se corre por el lado que no es.
    local par ruta modo valor
    for par in \
        'Cargo.toml|workspace.package' \
        'Cargo.toml|package' \
        'package.json|json' \
        'src-tauri/tauri.conf.json|json' \
        'src-tauri/Cargo.toml|package'
    do
        ruta="${par%%|*}"
        modo="${par##*|}"
        case "$modo" in
            json)   valor="$(version_de_json "$arbol/$ruta")" ;;
            *)      valor="$(version_de_cargo "$arbol/$ruta" "$modo")" ;;
        esac
        # Un `Cargo.toml` de un crate **miembro** con `version.workspace = true`
        # no declara nada: hereda. No es una versión que pueda divergir, así que
        # no cuenta. Por eso `version_de_cargo` no lo devuelve y esto lo saltea
        # en vez de tratarlo como un desacuerdo.
        [ -n "$valor" ] || continue
        declaradas+=("$valor")
        rutas+=("$ruta")
    done

    if [ ${#declaradas[@]} -eq 0 ]; then
        printf 'version: %s no declara versión en ningún manifiesto (se buscó Cargo.toml, package.json, src-tauri/Cargo.toml y src-tauri/tauri.conf.json)\n' \
            "$arbol" >&2
        return 1
    fi

    local version="${declaradas[0]}" unico=1
    local -a diferencias=()
    local i
    for i in "${!declaradas[@]}"; do
        if [ "${declaradas[$i]}" != "$version" ]; then
            unico=0
            diferencias+=("${rutas[$i]}=${declaradas[$i]}")
        fi
    done

    if [ "$unico" -eq 0 ]; then
        # El mensaje nombra los archivos, no solo los números: si divergen, lo
        # que hace falta es saber *cuál* se quedó atrás, y para eso hay que
        # leer el número de arriba y compararlo con el del repo.
        printf 'version: los manifiestos de %s no coinciden: %s=%s' \
            "$arbol" "${rutas[0]}" "$version" >&2
        local d
        for d in "${diferencias[@]}"; do
            printf ', %s' "$d" >&2
        done
        printf '\n' >&2
        return 1
    fi

    printf '%s' "$version"
    return 0
}
