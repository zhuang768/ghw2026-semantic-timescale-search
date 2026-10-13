#!/usr/bin/env bash
set -euo pipefail
LAB_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$LAB_ROOT"
test -x runtime/bin/pg_config
mkdir -p sources build
export CARGO_HOME="$LAB_ROOT/build/cargo"
export RUSTUP_HOME="$LAB_ROOT/build/rustup"
export PGRX_HOME="$LAB_ROOT/build/pgrx"
export CARGO_TARGET_DIR="$LAB_ROOT/build/cargo-target"
export CARGO_BUILD_JOBS="${LAB_JOBS:-6}"
export PATH="$CARGO_HOME/bin:$PATH"

# Official pinned macOS ARM bootstrap. This lab's actual build used this platform.
if [[ "$(uname -m)" != arm64 || "$(uname -s)" != Darwin ]]; then
  printf 'This pinned bootstrap targets macOS ARM. Use official Rust tooling for your platform.\n' >&2
  exit 1
fi
if [[ ! -x "$CARGO_HOME/bin/cargo" ]]; then
  curl --fail --location https://static.rust-lang.org/rustup/archive/1.29.1/aarch64-apple-darwin/rustup-init -o build/rustup-init
  printf '%s  %s\n' ec1b9233e7f72990ecd8e62063fa7f6c3dfc2bec8e97f88bff165f9100ac696a build/rustup-init | shasum -a 256 -c -
  chmod +x build/rustup-init
  build/rustup-init --no-modify-path --profile minimal --default-toolchain 1.91.0 -y
fi
rustup toolchain install 1.91.0 --profile minimal
export RUSTUP_TOOLCHAIN=1.91.0
curl --fail --location https://github.com/timescale/pgvectorscale/archive/refs/tags/0.9.1.tar.gz -o sources/pgvectorscale-0.9.1.tar.gz
printf '%s  %s\n' 9c5a78a3eaa044c78bfba80473e65a2f748b11bb788cdb06d3b88c93cc7a19aa sources/pgvectorscale-0.9.1.tar.gz | shasum -a 256 -c -
tar -xf sources/pgvectorscale-0.9.1.tar.gz -C sources
cp pgvectorscale-Cargo.lock sources/pgvectorscale-0.9.1/Cargo.lock
cargo install --locked cargo-pgrx --version 0.16.1
cargo pgrx init --pg17 "$LAB_ROOT/runtime/bin/pg_config" --no-run
export LIBCLANG_PATH=/Library/Developer/CommandLineTools/usr/lib

# Run from the source project so its committed macOS dynamic_lookup flags load.
cd sources/pgvectorscale-0.9.1/pgvectorscale
cargo pgrx install --release --pg-config "$LAB_ROOT/runtime/bin/pg_config" \
  --no-default-features --features pg17,build_parallel

