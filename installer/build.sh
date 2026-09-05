#!/bin/bash
# Build the solnix graphical installer (libcosmic) to an x86_64-illumos ELF.
# Uses the shared COSMIC build env + warm cargo cache on the builder.
set -eu
source /root/cosmic-env.sh
export PKG_CONFIG_PATH=/root/illumos-shims/udev
export RUSTFLAGS="-L /root/illumos-shims/udev"
export LD_LIBRARY_PATH=/root/illumos-shims/udev
export CARGO_BUILD_JOBS=6
export CARGO_TARGET_DIR=/nix/cosmic/solnix-installer/target
cd "$(dirname "$0")"
cargo build --release --target x86_64-unknown-illumos --offline
echo "built: $CARGO_TARGET_DIR/x86_64-unknown-illumos/release/solnix-installer"
