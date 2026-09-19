#!/usr/bin/env bash
#
# check-portability-test.sh — que el detector siga distinguiendo las dos cosas.
#
# Esta prueba existe porque el detector se **aflojó**: la regla original pedía
# que el control de CPU estuviera a menos de 128 KB de las instrucciones, y eso
# deja afuera lo que Rust genera con `#[target_feature]`, donde la detección
# vive en la biblioteca estándar y el enlazador la pone a megabytes de
# distancia. Aflojar un control sin una prueba que lo sostenga es quedarse sin
# control.
#
# Se compila el mismo programa dos veces, una apuntada a esta máquina y otra a
# la base, y se comprueba que el detector diga cosas distintas. Necesita cargo.
#
#   ./check-portability-test.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRABAJO="$(mktemp -d)"
trap 'rm -rf "$TRABAJO"' EXIT

command -v cargo >/dev/null || { echo "hace falta cargo"; exit 1; }

mkdir -p "$TRABAJO/canario/src"
cat >"$TRABAJO/canario/Cargo.toml" <<'EOF'
[package]
name = "canario"
version = "0.0.0"
edition = "2021"

[[bin]]
name = "canario"
path = "src/main.rs"

[profile.release]
opt-level = 3
codegen-units = 1
strip = true
EOF

# La clase de cuentas que el compilador convierte en BMI cuando se le permite:
# desplazamientos variables, máscaras y multiplicaciones anchas.
cat >"$TRABAJO/canario/src/main.rs" <<'EOF'
use std::hint::black_box;

fn revolver(datos: &[u64], corrimientos: &[u32]) -> u64 {
    let mut acumulado = 0u64;
    for (indice, valor) in datos.iter().enumerate() {
        let corrimiento = corrimientos[indice % corrimientos.len()] & 63;
        let alto = (*valor as u128 * 0x9E37_79B9_7F4A_7C15u128) >> 64;
        acumulado ^= (valor << corrimiento) ^ (valor >> (64 - corrimiento).min(63));
        acumulado = acumulado.wrapping_add(alto as u64);
        acumulado &= (1u64 << (corrimiento + 1)) - 1;
    }
    acumulado
}

fn main() {
    let datos: Vec<u64> = (0..4096).map(|i| i * 0x0123_4567_89AB_CDEF).collect();
    let corrimientos: Vec<u32> = (0..64).collect();
    println!("{}", revolver(black_box(&datos), black_box(&corrimientos)));
}
EOF

armar() { # <target-cpu> <destino>
  ( cd "$TRABAJO/canario" && CARGO_TARGET_DIR="$TRABAJO/target-$1" \
      RUSTFLAGS="-C target-cpu=$1" cargo build --release -q ) || return 1
  mkdir -p "$TRABAJO/pkg-$1/usr/bin"
  cp "$TRABAJO/target-$1/release/canario" "$TRABAJO/pkg-$1/usr/bin/canario-$1"
  ( cd "$TRABAJO/pkg-$1" && bsdtar -czf "$2" usr )
}

fallos=0
comprobar() { # <qué> <esperado: portable|no> <paquete>
  local salida
  salida="$("$REPO_DIR/check-portability.sh" "$3" 2>&1)"
  local estado=$?
  if [[ "$2" == portable && $estado -ne 0 ]]; then
    echo "FALLA: $1 tendría que pasar y se marcó como no portable"
    echo "$salida" | sed 's/^/    /'
    fallos=1
  elif [[ "$2" == no && $estado -eq 0 ]]; then
    echo "FALLA: $1 tendría que marcarse y pasó"
    echo "$salida" | sed 's/^/    /'
    fallos=1
  else
    echo "ok: $1"
  fi
}

echo "==> Compilando los dos canarios"
armar native "$TRABAJO/canario-nativo-1-1-x86_64.pkg.tar.zst" || exit 1
armar x86-64 "$TRABAJO/canario-base-1-1-x86_64.pkg.tar.zst" || exit 1

echo "==> Comprobando"
# El nativo tiene las instrucciones repartidas por todo lo que compiló y ni un
# solo cpuid: nada las guarda porque no hay nada que decidir.
comprobar "el canario compilado para esta máquina" no \
  "$TRABAJO/canario-nativo-1-1-x86_64.pkg.tar.zst"
comprobar "el canario compilado para la base" portable \
  "$TRABAJO/canario-base-1-1-x86_64.pkg.tar.zst"

# Y un paquete de verdad con rutas guardadas, si está construido. No se exige:
# el repositorio puede estar vacío en una máquina recién clonada.
REAL="$(ls "${VASAKOS_REPO_DIR:-$REPO_DIR/../repository-script/x86_64}"/vasak-store-*.pkg.tar.zst 2>/dev/null | head -1)"
if [[ -n "$REAL" ]]; then
  comprobar "vasak-store, que tiene ring y zlib-rs guardados por CPUID" portable "$REAL"
else
  echo "omitido: no hay un vasak-store construido para comprobar el caso real"
fi

exit $fallos
