#!/bin/sh
# llama-vulkan-lavapipe-bench.sh -- the measurement the GGML_VULKAN work never did:
# wire the lavapipe ICD under the Vulkan loader and RUN a small model through
# llama.cpp's Vulkan backend on solnix, measuring tok/s. Compare to the CPU
# baseline (~70 tok/s, docs/design-gpu-compute-parity.md C0).
#
# HONEST EXPECTATION (do NOT assume): software Vulkan (lavapipe) JITs the
# rasterizer/compute on the CPU, so it may be SLOWER than llama.cpp's native CPU
# backend (which uses hand-tuned AVX2 + OpenMP, not a generic SPIR-V->LLVM JIT).
# The POINT is to prove the Vulkan-compute PATH works end to end on solnix NOW
# (software), so that when a hardware DRM render node lands the SAME GGML_VULKAN
# binary + ICD mechanism uses the GPU. We MEASURE and report the real number,
# faster or slower.
#
# This is the first time lavapipe (an ICD) is actually loaded under the llama.cpp
# Vulkan backend on illumos -- prior runs reported "(none)" because no ICD was on
# VK_ICD_FILENAMES (src/drm-port/ggml-vulkan/GGML-VULKAN-STATUS.md).
#
# Usage:
#   LVP_PREFIX=/nix/store/...-mesa-lavapipe-25.1.4 \
#   LLAMA_DIR=/root/ggml-vulkan/src/llama.cpp/build/bin \
#   LOADER_PREFIX=/root/ggml-vulkan/prefix \
#   MODEL=/root/models/qwen2.5-0.5b-instruct-q4_k_m.gguf \
#   sh llama-vulkan-lavapipe-bench.sh
set -u
LVP_PREFIX="${LVP_PREFIX:?set LVP_PREFIX to the mesa-lavapipe store path}"
LLAMA_DIR="${LLAMA_DIR:-/root/ggml-vulkan/src/llama.cpp/build/bin}"
LOADER_PREFIX="${LOADER_PREFIX:-/root/ggml-vulkan/prefix}"
GCC="${GCC:-/root/buildimg/usr/gcc/14}"
MODEL="${MODEL:-}"
NGL="${NGL:-99}"       # offload all layers to the "GPU" (lavapipe) for the Vulkan run

ICD=$(ls "$LVP_PREFIX"/share/vulkan/icd.d/*lvp*.json "$LVP_PREFIX"/share/vulkan/icd.d/*.json 2>/dev/null | head -1)
[ -n "$ICD" ] || { echo "FAIL: no lavapipe ICD under $LVP_PREFIX"; exit 1; }
export LD_LIBRARY_PATH="$LOADER_PREFIX/lib:$LVP_PREFIX/lib:$GCC/lib/amd64:$GCC/lib:$LLAMA_DIR:${LD_LIBRARY_PATH:-}"
BENCH="$LLAMA_DIR/llama-bench"; CLI="$LLAMA_DIR/llama-cli"
[ -x "$BENCH" ] || BENCH=""
[ -x "$CLI" ] || { echo "FAIL: no llama-cli at $CLI"; exit 1; }

echo "=== lavapipe ICD: $ICD ==="
echo "=== loader: $LOADER_PREFIX  llama: $LLAMA_DIR ==="

# 0) confirm the Vulkan backend now SEES lavapipe (the step that was (none) before)
echo; echo "[0] llama --list-devices WITH the lavapipe ICD (expect a Vulkan device, not (none)):"
VK_ICD_FILENAMES="$ICD" VK_DRIVER_FILES="$ICD" "$CLI" --list-devices 2>&1 | sed 's/^/    /' | head -15

if [ -z "$MODEL" ] || [ ! -f "$MODEL" ]; then
  echo
  echo "NO MODEL supplied (set MODEL=path.gguf). Fetch a small one, e.g.:"
  echo "  curl -fkLo /root/models/qwen2.5-0.5b-q4.gguf \\"
  echo "    https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf"
  echo "Then re-run with MODEL=/root/models/qwen2.5-0.5b-q4.gguf"
  echo "[0] above already proves the loader->lavapipe-ICD dispatch; the tok/s needs the model."
  exit 0
fi

run_tg() {  # $1 = label, rest = extra llama-cli args (backend selection via env/args)
  label="$1"; shift
  # generate 128 tokens from a fixed prompt; parse the eval tok/s from llama's timings
  out=$("$CLI" -m "$MODEL" -p "The quick brown fox" -n 128 -t "$(psrinfo|wc -l|tr -d ' ')" --no-warmup "$@" 2>&1)
  tps=$(printf '%s\n' "$out" | grep -iE "eval time|tokens per second|tok/s" | grep -iE "eval|generation" | grep -oE '[0-9]+\.[0-9]+ tokens per second' | head -1)
  [ -z "$tps" ] && tps=$(printf '%s\n' "$out" | grep -oE '[0-9]+\.[0-9]+ (tokens per second|t/s|tok/s)' | tail -1)
  echo "  $label: ${tps:-<no tok/s parsed>}"
  printf '%s\n' "$out" | tail -3 | sed 's/^/      /'
}

echo; echo "[1] CPU baseline (ngl=0, native CPU backend):"
VK_ICD_FILENAMES=/dev/null run_tg "CPU" -ngl 0

echo; echo "[2] Vulkan on lavapipe (software, ngl=$NGL):"
VK_ICD_FILENAMES="$ICD" VK_DRIVER_FILES="$ICD" run_tg "VULKAN(lavapipe)" -ngl "$NGL"

echo
echo "=== HONEST VERDICT ==="
echo "Report BOTH numbers. If VULKAN(lavapipe) < CPU, that is EXPECTED and honest:"
echo "software Vulkan JITs on the CPU vs llama.cpp's tuned AVX2 CPU path. The win is"
echo "that the Vulkan-compute PATH runs end-to-end on solnix NOW -- the SAME binary +"
echo "ICD mechanism uses a real GPU once a hardware DRM render node lands (RADV/ANV/NVK)."
