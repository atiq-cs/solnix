#!/usr/bin/env bash
# all.sh <date> -- tryit1: kernels, images, wasm (if missing), bundle; on the EC2 build box, after env.sh.
set -euo pipefail
D=$1; R="$(cd "$(dirname "$0")/.." && pwd)"
bash "$R/tryit/build-kernels.sh" | tail -3
[ -f $HOME/w/opensbi/build/platform/generic/firmware/fw_jump.bin ] || SOURCE_DATE_EPOCH=0 bash "$R/tryit/build-opensbi.sh"
set -a; . "$R/tryit/demo.env"; set +a
OPENSBI=$HOME/w/opensbi/build/platform/generic/firmware/fw_jump.bin \
	SPLITIMG=$HOME/w/te/tinyemu-solnix/splitimg INIT=$R/uts/user/init-demo.elf bash "$R/tryit/mk-images.sh" $HOME/w/img | tail -1
[ -f $HOME/w/tew/tinyemu-solnix/js/tinyemu-solnix-$D.wasm ] || OUT=tinyemu-solnix-$D BUILD=$HOME/w/tew bash "$R/tinyemu/build.sh" wasm
[ ! -d $HOME/w/bundle ] || find $HOME/w/bundle -depth -delete
VENDOR=$HOME/w/interim/solnix-wasm-demo bash "$R/tryit/mk-bundle.sh" $D $HOME/w/img $HOME/w/tew/tinyemu-solnix/js $HOME/w/bundle
