#!/usr/bin/env bash
#
# Que la versión que lee `version_de_arbol` sea la de verdad, y que avise cuando
# los manifiestos de un proyecto no dicen lo mismo.
#
# # Por qué existe
#
# Cinco recetas tenían el `pkgver=` escrito a mano y **ninguna** recálculalo, así
# que la versión derivaba sin que nada lo dijera: `vasak-accounts` iba cuatro
# versiones atrás (0.13.0 en la receta, 0.17.3 en el repo), `vasak-contacts`
# cinco parches. El ISO se armaba con metadatos de versión equivocados.
#
# Lo que hace esta prueba es reemplazar al `makpkg` como forma de ver el
# número. Con `pkgver()` la deriva ya no se puede ver a ojo —un paquete con la
# versión vieja se publica, se instala y anda— y `makpkg` tampoco la señala: no
# tiene contra qué comparar. La única referencia es el árbol de fuentes, y eso
# es lo que se contrasta acá.
#
# Los casos que fallan por sí solos, sin `makpkg`, son la razón de que esto sea
# un archivo y no una línea en el reporte:
#
#   - Los tres manifiestos de una app Tauri que **divergen**. El CI ya lo
#     comprueba, pero el CI mira el repo, no el paquete: si el segundo lugar
#     que lee la versión no exige lo mismo, la divergencia se descubre tarde y
#     en el lugar equivocado.
#   - Un `Cargo.toml` con `version = "1"` de una dependencia **antes** de la
#     sección real. Un `grep -m1` acierta por casualidad hoy, porque en estos
#     archivos la versión va antes que `[workspace.dependencies]`; el día que
#     alguien reordene, se rompe callando.
#   - Un crate miembro con `version.workspace = true`, que **hereda** y por lo
#     tanto no es una versión que pueda discrepar. Contarlo como desacuerdo
#     haría fallar la receta por un archivo que está bien.
#
# Uso: pruebas/versiones.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
REPO_DIR="$PWD"
# shellcheck source=../lib/versiones.sh
source "$REPO_DIR/lib/versiones.sh"

fallos=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; }
mal() { printf '  \033[31m✗\033[0m %s\n' "$1"; fallos=$((fallos + 1)); }

# El workspace está al lado de este repo; es donde vive cada árbol de fuentes.
WORKSPACE="$(cd "$REPO_DIR/.." && pwd)"

# Cada receta, y el repo cuyo manifiesto manda.
RECETAS=(
    vasak-accounts-git:vasak-accounts
    vasak-calendar-git:vasak-calendar
    vasak-contacts-git:vasak-contacts
    vasak-keyring-git:vasak-keyring
    vasak-permissions:vasak-permissions
)

printf '\033[1mLa versión de las %d recetas, contra su árbol de fuentes\033[0m\n' "${#RECETAS[@]}"
for par in "${RECETAS[@]}"; do
    receta="${par%%:*}"
    repo="${par##*:}"
    arbol="$WORKSPACE/$repo"

    if [ ! -d "$arbol" ]; then
        mal "$receta: no está el repo $repo al lado del workspace"
        continue
    fi

    obtenida="$(version_de_arbol "$arbol")"
    if [ -z "$obtenida" ]; then
        mal "$receta: no se pudo leer la versión de $repo"
        continue
    fi

    # La referencia es el `pkgver=` que la receta declara hoy. Si divergen, lo
    # que hay que actualizar es la receta: es el número viejo el que está mal.
    declarada="$(sed -n 's/^pkgver=//p' "$REPO_DIR/$receta/PKGBUILD" | head -1)"
    if [ "$obtenida" = "$declarada" ]; then
        ok "$receta: $obtenida"
    else
        mal "$receta: la receta dice $declarada y el repo dice $obtenida"
    fi
done

# ── Manifiestos que divergen ────────────────────────────────────────────────
#
# Un árbol de mentira, en `/tmp`, que no depende de ningún repo: si el caso
# dependiera del workspace, dejaría de probar algo el día que el workspace
# cambie.
temporal="$(mktemp -d)"
trap 'rm -rf "$temporal"' EXIT

printf '\n\033[1mCuando los manifiestos no dicen lo mismo\033[0m\n'

mkdir -p "$temporal/divergente/src-tauri"
cat > "$temporal/divergente/package.json" <<'JSON'
{
  "name": "app",
  "private": true,
  "version": "1.2.3",
  "dependencies": {
    "alguien": { "version": "^4.5.6" }
  }
}
JSON
cat > "$temporal/divergente/src-tauri/tauri.conf.json" <<'JSON'
{
  "version": "1.2.2"
}
JSON
cat > "$temporal/divergente/src-tauri/Cargo.toml" <<'TOML'
[package]
name = "app"
version = "1.2.3"
TOML

salida="$(version_de_arbol "$temporal/divergente" 2>&1)"
if [ $? -ne 0 ] && printf '%s' "$salida" | grep -q 'no coinciden'; then
    ok "un manifiesto desactualizado se niega a contarse"
else
    mal "una app con manifiestos divergentes no dio error: ${salida:-<vacío>}"
fi

# Y que el mensaje **nombre los archivos**. Si sólo dice «las versiones no
# coinciden», quien lo lea tiene que abrir los cuatro a ciegas para saber cuál
# se quedó atrás.
if printf '%s' "$salida" | grep -q 'tauri.conf.json=1.2.2'; then
    ok "el error nombra el archivo que divergió"
else
    mal "el error no dice qué archivo divergió: $salida"
fi

# El `dependencies` de `package.json` trae su propio `"version"`. La de nivel
# superior va primero, pero la función no debería depender de ese orden.
if [ "$(version_de_json "$temporal/divergente/package.json")" = "1.2.3" ]; then
    ok "una dependencia con \"version\" propia no tapa la del paquete"
else
    mal "se leyó la versión de una dependencia en vez de la del paquete"
fi

# ── El orden del Cargo.toml ─────────────────────────────────────────────────
printf '\n\033[1mCuando el Cargo.toml tiene versiones de dependencia antes\033[0m\n'

mkdir -p "$temporal/orden"
# La forma que realmente rompe un `grep -m1 '^version'`: una dependencia con
# su **propia sección**, que abre la línea con `version =`. El
# `serde = { version = "1" }` de una dependencia en línea no la abre, y por eso
# un fixture con esa forma pasa el grep ingenuo y no prueba nada.
cat > "$temporal/orden/Cargo.toml" <<'TOML'
# Las secciones en este orden, a propósito: el orden no puede cambiar lo que se
# lee.
[dependencies.algo]
version = "1.2.3"
optional = true

[package]
name = "algo"
version = "9.8.7"
TOML

if [ "$(version_de_cargo "$temporal/orden/Cargo.toml" package)" = "9.8.7" ]; then
    ok "la versión se lee de su sección, no de la primera línea"
else
    mal "se leyó la versión de una dependencia: $(version_de_cargo "$temporal/orden/Cargo.toml" package)"
fi

# Y con `[workspace.package]`, que es como estos proyectos declaran la suya.
mkdir -p "$temporal/workspace"
cat > "$temporal/workspace/Cargo.toml" <<'TOML'
[workspace]
members = ["a", "b"]

[workspace.dependencies]
chrono = "0.4"

[workspace.package]
version = "0.17.3"
TOML

if [ "$(version_de_cargo "$temporal/workspace/Cargo.toml" workspace.package)" = "0.17.3" ]; then
    ok "la versión del workspace se lee de [workspace.package]"
else
    mal "no se leyó [workspace.package]: $(version_de_cargo "$temporal/workspace/Cargo.toml" workspace.package)"
fi

# ── Herencia ────────────────────────────────────────────────────────────────
printf '\n\033[1mCuando el crate miembro hereda la versión\033[0m\n'

# `version.workspace = true` no declara una versión: hereda la del workspace.
# Contarlo como desacuerdo haría fallar la receta por un archivo que está
# perfecto, que es exactamente lo que pasaba con `vasak-permissions`.
cat > "$temporal/workspace/miembro.toml" <<'TOML'
[package]
name = "miembro"
version.workspace = true
TOML

if [ -z "$(version_de_cargo "$temporal/workspace/miembro.toml" package)" ]; then
    ok "version.workspace = true no cuenta como versión declarada"
else
    mal "la herencia se contó como una versión declarada"
fi

# El caso real: un workspace con raíz y `src-tauri` que hereda. La versión es
# la de la raíz, y tiene que salir sin que el miembro estorbe.
if [ "$(version_de_arbol "$WORKSPACE/vasak-permissions")" = "0.15.0" ]; then
    ok "el híbrido de vasak-permissions lee la versión de la raíz"
else
    mal "vasak-permissions: $(version_de_arbol "$WORKSPACE/vasak-permissions" 2>&1)"
fi

# ── Ausencia de manifiesto ──────────────────────────────────────────────────
printf '\n\033[1mCuando no hay manifiesto\033[0m\n'

mkdir -p "$temporal/vacio"
salida="$(version_de_arbol "$temporal/vacio" 2>&1)"
if [ $? -ne 0 ] && printf '%s' "$salida" | grep -q 'no declara versión'; then
    ok "un árbol sin manifiesto falla diciendo cuál falta"
else
    mal "un árbol sin manifiesto no dio error claro: ${salida:-<vacío>}"
fi

# ── Idempotencia ────────────────────────────────────────────────────────────
printf '\n\033[1mDos llamadas seguidas\033[0m\n'

# `makpkg` llama a `pkgver()` más de una vez por construcción. Si dependiera
# del estado del árbol —un archivo temporal, un contador— la segunda daría
# algo distinto y la receta quedaría con una versión que no corresponde.
arbol="$WORKSPACE/$(printf '%s' "${RECETAS[0]##*:}")"
primera="$(version_de_arbol "$arbol")"
segunda="$(version_de_arbol "$arbol")"
if [ "$primera" = "$segunda" ] && [ -n "$primera" ]; then
    ok "leer dos veces el mismo árbol da lo mismo"
else
    mal "la segunda lectura difiere: '$primera' y '$segunda'"
fi

echo
if [ "$fallos" -eq 0 ]; then
    printf '\033[32mTodo bien.\033[0m\n'
    exit 0
fi
printf '\033[31m%d comprobación(es) fallaron.\033[0m\n' "$fallos"
exit 1
