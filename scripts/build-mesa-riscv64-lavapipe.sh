#!/bin/sh
# build-mesa-riscv64-lavapipe.sh -- cross-build Mesa 25.1.4 for riscv64 with
# llvmpipe (GL/GLES) + lavapipe (software Vulkan) + the Wayland EGL platform.
#
# WHAT this proves / provides: the ENTIRE software renderer the Milk-V Jupiter
# (SpacemiT K1) COSMIC desktop depends on. The K1's PowerVR BXE-2-32 has no
# usable driver path (docs/riscv-jupiter-driver-plan.md §7), so COSMIC renders
# on the CPU and the GPU/DPU only does scanout. This script builds that CPU
# renderer for riscv64.
#
# MEASURED RESULT (Ubuntu 24.04 x86_64 host, riscv64 cross): 1124/1124 ninja
# targets, ~1m43s wall on 16 cores, ZERO source patches needed. Outputs, all
# verified EM_RISCV:
#   libvulkan_lvp.so         12 MB   lavapipe (software Vulkan), NEEDED libLLVM.so.20.1
#   libgallium-25.1.4.so     18 MB   llvmpipe (LLVMInitializeRISCVTarget* present)
#   libEGL_mesa.so.0.0.0            advertises EGL_KHR_platform_wayland +
#                                   EGL_EXT_platform_wayland (the extension the
#                                   x86 wave had to rebuild Mesa to get)
#   dri_gbm.so
#
# THE ONE NON-OBVIOUS REQUIREMENT: llvmpipe/lavapipe JIT the rasterizer, so they
# need a TARGET-SIDE LLVM (libLLVM for riscv64) AND meson must be able to RUN
# llvm-config for that target. The trick: stage the riscv64 llvm-20 debs and let
# meson invoke the riscv64 llvm-config through qemu-user binfmt (exe_wrapper).
# LLVM 20's riscv64 build reports mcjit+native present, so llvmpipe's required
# LLVM module list resolves.
#
# RVV NOTE: LLVM 20 HAS RISC-V vector codegen, but Mesa's llvmpipe has NO riscv
# SIMD path -- src/util/u_cpu_detect.c has arms only for x86/ARM-NEON/ALTIVEC,
# and lp_bld_misc.cpp's MAttrs list only ever pushes +avx/+neon/+altivec. So the
# K1's RVV1.0 is UNUSED and the rasterizer is scalar. Adding a `__riscv` arm to
# u_cpu_detect + pushing "+v,+zvl256b" into MAttrs is the upstream-shaped change
# that would let LLVM auto-vectorize the JIT-ed shaders on the K1's X60 cores.
# Leave RVV as a TUNING KNOB (vector length varies by SoC), not a hard-coded
# assumption.
#
# Host prerequisites (Debian/Ubuntu):
#   gcc-riscv64-linux-gnu g++-riscv64-linux-gnu binutils-riscv64-linux-gnu
#   qemu-user-static (for binfmt) glslang-tools bison flex pkg-config
#   python3 venv with: meson>=1.3 ninja mako pyyaml packaging
#   dpkg --add-architecture riscv64 + ports.ubuntu.com sources, then:
#     libwayland-dev:riscv64 libwayland-egl-backend-dev:riscv64
#     libxkbcommon-dev:riscv64 libdrm-dev:riscv64 libudev-dev:riscv64
#     libexpat1-dev:riscv64 zlib1g-dev:riscv64 libzstd-dev:riscv64
#     libelf-dev:riscv64 libpixman-1-dev:riscv64
#   riscv64 LLVM staged via `apt-get download llvm-20:riscv64 llvm-20-dev:riscv64
#     libllvm20:riscv64` + dpkg-deb -x into $RVSYS (llvm-config lives in the
#     `llvm-20` deb, NOT llvm-20-dev -- an easy hour to lose).
set -eu

SRC="${SRC:-/tmp/work/mesa}"          # a mesa-25.1.4 checkout
BUILD="${BUILD:-/tmp/mesa-rv64}"
RVSYS="${RVSYS:-/tmp/rvsys/root}"     # where the riscv64 llvm debs were unpacked
VENV="${VENV:-/tmp/mesavenv}"
JOBS="${JOBS:-$(nproc)}"

LLVMCFG="$RVSYS/usr/lib/llvm-20/bin/llvm-config"
[ -x "$LLVMCFG" ] || { echo "FAIL: no riscv64 llvm-config at $LLVMCFG"; exit 1; }

# WHY the sysroot copy: the staged .debs put headers under $RVSYS/usr/include,
# which the cross-gcc does not search. The three Mesa needs from there are
# zstd.h / libelf.h / the llvm headers; copy the staged trees into the sysroot
# the cross-gcc already searches. (Without this, ninja dies at compress.c:38
# "zstd.h: No such file or directory" after a fully successful meson configure.)
sudo mkdir -p /usr/riscv64-linux-gnu/include /usr/riscv64-linux-gnu/lib
sudo cp -a "$RVSYS"/usr/include/* /usr/riscv64-linux-gnu/include/ 2>/dev/null || true
sudo cp -a "$RVSYS"/usr/lib/riscv64-linux-gnu/* /usr/riscv64-linux-gnu/lib/ 2>/dev/null || true

CROSSFILE=/tmp/rv64-cross.ini
cat > "$CROSSFILE" <<INI
[binaries]
c = 'riscv64-linux-gnu-gcc'
cpp = 'riscv64-linux-gnu-g++'
ar = 'riscv64-linux-gnu-ar'
strip = 'riscv64-linux-gnu-strip'
pkg-config = 'pkg-config'
llvm-config = '$LLVMCFG'
exe_wrapper = 'qemu-riscv64-static'

[properties]
needs_exe_wrapper = true
pkg_config_libdir = '$RVSYS/usr/lib/riscv64-linux-gnu/pkgconfig:$RVSYS/usr/share/pkgconfig:/usr/lib/riscv64-linux-gnu/pkgconfig:/usr/share/pkgconfig'

[host_machine]
system = 'linux'
cpu_family = 'riscv64'
cpu = 'riscv64'
endian = 'little'
INI

PATH="$VENV/bin:$PATH"; export PATH
cd "$SRC"
meson setup "$BUILD" . --cross-file "$CROSSFILE" \
	-Dgallium-drivers=llvmpipe -Dvulkan-drivers=swrast \
	-Dplatforms=wayland -Dglx=disabled -Degl=enabled -Dgles2=enabled \
	-Dllvm=enabled -Dshared-llvm=enabled \
	-Dvideo-codecs= -Dgallium-va=disabled -Dgallium-vdpau=disabled \
	-Dbuildtype=release

ninja -C "$BUILD" -j"$JOBS"

echo "=== EM_RISCV verification (all five must say RISC-V) ==="
for f in \
	"$BUILD/src/gallium/targets/lavapipe/libvulkan_lvp.so" \
	"$BUILD/src/gallium/targets/dri/libgallium-25.1.4.so" \
	"$BUILD/src/egl/libEGL_mesa.so.0.0.0" \
	"$BUILD/src/gbm/backends/dri/dri_gbm.so"; do
	printf '%s: ' "$(basename "$f")"
	readelf -h "$f" 2>/dev/null | awk '/Machine:/{print $2; exit}'
done
echo "=== EGL wayland platform present? ==="
strings "$BUILD/src/egl/libEGL_mesa.so.0.0.0" | grep -o 'EGL_KHR_platform_wayland' | head -1
