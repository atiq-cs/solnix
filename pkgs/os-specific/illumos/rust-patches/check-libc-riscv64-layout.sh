#!/usr/bin/env bash
# check-libc-riscv64-layout.sh -- regression harness for the riscv64 solarish
# arch module in the `libc` crate.
#
# WHAT: applies libc-solarish-riscv64-arch-module.patch to a pristine copy of
# the libc crate, then compiles a set of COMPILE-TIME layout assertions for the
# custom riscv64gc-unknown-illumos target. Build succeeds => layout is right.
#
# WHY it exists: the first version of that patch shipped an x86 FXSAVE-shaped
# union view (`[[u32; 16]; 17]`) copied from solarish/x86_64.rs. On RV64 that
# inflates mcontext_t from 520 to 1088 bytes -- a libc ucontext_t LARGER than
# the kernel's, i.e. a signal handler that smashes the stack. It compiled fine
# and the five-type probe passed; only a size assertion catches it. The patch
# also shipped a truncated hunk header (+1,150 for a 162-line body) which made
# `patch` silently drop the whole AV_RISCV_* hwcap block including AV_RISCV_V.
# Both classes of bug are invisible without this check.
#
# RUN IT WHEN:
#   - the libc crate is bumped (the solarish tree may shift),
#   - the patch is edited,
#   - a real illumos riscv64 <sys/regset.h> lands (then update the EXPECTED
#     values here to match the header and re-verify -- see NGREG note below).
#
# NGREG / REG_* PROVENANCE: the expected register indices below are NOT from a
# real illumos riscv64 <sys/regset.h> (none exists yet). They follow the solnix
# kernel's own trap frame (src/riscv/uts/regs.h `struct regs`: x1..x31 then
# r_sepc) cross-checked against the NetBSD riscv gregset in
# src/riscv/bsd-ref/netbsd/nb_mcontext.h (_REG_X1==0 .. _REG_X31==30,
# _REG_PC==31). When the real header lands, IT wins and this file changes.
#
# Usage:
#   ./check-libc-riscv64-layout.sh                  # uses a cached libc-0.2.189
#   LIBC_SRC=/path/to/libc-crate ./check-...sh      # explicit crate source
#   PREPATCHED=1 LIBC_SRC=... ./check-...sh         # source ALREADY carries the
#                                                   # riscv64 module; skip patch
# Requires: a nightly rustc with rust-src (for -Zbuild-std). Exits non-zero on
# any layout drift.
#
# SELF-TEST (proves the assertions are not vacuous -- do this after editing
# them): copy a patched libc, put the x86-shaped fp union view back, and confirm
# this script FAILS:
#   sed -i 's/\[\[u32; 33\]; 2\]/[[u32; 16]; 17]/' <copy>/src/unix/solarish/riscv64.rs
#   PREPATCHED=1 LIBC_SRC=<copy> ./check-libc-riscv64-layout.sh   # must exit 1
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PATCH="$HERE/libc-solarish-riscv64-arch-module.patch"
TARGET_JSON="${TARGET_JSON:-$HERE/../rust-targets/riscv64gc-unknown-illumos.json}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -f "$PATCH" ] || { echo "FAIL: no patch at $PATCH"; exit 1; }
[ -f "$TARGET_JSON" ] || { echo "FAIL: no target json at $TARGET_JSON"; exit 1; }

# Locate a pristine libc crate: explicit LIBC_SRC, else the newest cargo-cached
# libc-0.2.*, else vendor it with `cargo add`-style fetch.
if [ -n "${LIBC_SRC:-}" ]; then
	SRC="$LIBC_SRC"
else
	SRC="$(ls -d "$HOME"/.cargo/registry/src/*/libc-0.2.* 2>/dev/null | sort -V | tail -1 || true)"
fi
[ -n "$SRC" ] && [ -d "$SRC" ] || {
	echo "SKIP: no libc crate source found. Set LIBC_SRC=/path/to/libc-0.2.x"
	exit 77
}
echo "libc source: $SRC"

cp -r "$SRC" "$WORK/libc"
chmod -R u+w "$WORK/libc"

if [ -n "${PREPATCHED:-}" ]; then
	echo "--- PREPATCHED=1: using $SRC as-is (not applying the patch)"
	[ -f "$WORK/libc/src/unix/solarish/riscv64.rs" ] || {
		echo "FAIL: PREPATCHED set but src/unix/solarish/riscv64.rs is absent"
		exit 1
	}
else
	echo "--- applying $PATCH"
	( cd "$WORK/libc" && patch -p1 --fuzz=0 ) < "$PATCH"
fi

# The assertions. Each is a const-eval `assert!`, so a mismatch is a BUILD
# ERROR, not a runtime failure -- no riscv64 hardware or emulator needed.
mkdir -p "$WORK/layout/src"
cat > "$WORK/layout/Cargo.toml" <<EOF
[package]
name = "layout"
version = "0.1.0"
edition = "2021"
[dependencies]
libc = { path = "$WORK/libc", default-features = false, features = ["extra_traits"] }
[workspace]
EOF

cat > "$WORK/layout/src/lib.rs" <<'RS'
//! Compile-time layout assertions for libc's solarish riscv64 arch module.
//! A failure here is an ABI mismatch against the kernel's ucontext.
use core::mem::{align_of, size_of};

// --- FP state: RV64 D-extension is 32 x u64 (f0..f31) + fcsr, NOT x86 FXSAVE.
// 32*8 + 4 + 4(pad) == 264.
const _: () = assert!(size_of::<libc::__c_anonymous_fpchip_state>() == 264);
// Both union views MUST be the same size. The x86 [[u32;13];10] view is 520 and
// the original patch's [[u32;16];17] is 1088 -- either silently inflates
// mcontext_t. This is the assertion that catches the ABI break.
const _: () = assert!(size_of::<libc::__c_anonymous_fp_reg_set>() == 264);
const _: () = assert!(size_of::<libc::fpregset_t>() == 264);

// --- mcontext_t: NGREG(32) * greg_t(8) == 256, + fpregset(264) == 520.
const _: () = assert!(size_of::<libc::greg_t>() == 8);
const _: () = assert!(size_of::<libc::mcontext_t>() == 520);
const _: () = assert!(align_of::<libc::mcontext_t>() == 8);

// --- ucontext_t must embed the mcontext and stay LP64-aligned.
const _: () = assert!(size_of::<libc::ucontext_t>() >= 520);
const _: () = assert!(align_of::<libc::ucontext_t>() == 8);

// --- Elf64_Phdr is the fixed 56-byte LP64 ELF program header.
const _: () = assert!(size_of::<libc::Elf64_Phdr>() == 56);

// --- gregset indices: slots 0..30 == x1..x31, PC LAST at 31, no x0 slot.
const _: () = assert!(libc::NGREG == 32);
const _: () = assert!(libc::NFPREG == 33);
const _: () = assert!(libc::REG_X1 == 0);
const _: () = assert!(libc::REG_X31 == 30);
const _: () = assert!(libc::REG_PC == 31);
// Every index must be addressable within gregs[NGREG].
const _: () = assert!((libc::REG_PC as usize) < libc::NGREG);
const _: () = assert!((libc::REG_X31 as usize) < libc::NGREG);

// --- RISC-V psABI name aliases must match the x-numbering.
const _: () = assert!(libc::REG_RA == 0);
const _: () = assert!(libc::REG_SP == 1);
const _: () = assert!(libc::REG_GP == 2);
const _: () = assert!(libc::REG_TP == 3);
const _: () = assert!(libc::REG_A0 == 9);
const _: () = assert!(libc::REG_A7 == 16);
const _: () = assert!(libc::REG_S0 == libc::REG_FP);
const _: () = assert!(libc::REG_T6 == libc::REG_X31);

// --- fpregset indices (NetBSD _REG_F0 / _REG_FPCSR).
const _: () = assert!(libc::REG_F0 == 0);
const _: () = assert!(libc::REG_FPCSR == 32);
const _: () = assert!((libc::REG_FPCSR as usize) < libc::NFPREG);

// --- hwcaps: single distinct bits. AV_RISCV_V is the K1's RVV bit and was the
// symbol the truncated hunk silently dropped, so assert it by name.
const _: () = assert!(libc::AV_RISCV_M == 0x0001);
const _: () = assert!(libc::AV_RISCV_D == 0x0008);
const _: () = assert!(libc::AV_RISCV_V == 0x0020);
const _: () = assert!(libc::AV_RISCV_M | libc::AV_RISCV_V == 0x0021);

// --- the five types the arch module exists to provide must all be nameable.
#[allow(dead_code)]
fn five_types_resolve() -> usize {
    size_of::<libc::ucontext_t>()
        + size_of::<libc::mcontext_t>()
        + size_of::<libc::fpregset_t>()
        + size_of::<libc::Elf64_Phdr>()
        + size_of::<libc::dl_phdr_info>()
}
RS

echo "--- building layout assertions for riscv64gc-unknown-illumos"
cd "$WORK/layout"
export RUSTC_BOOTSTRAP=1
if ! cargo build --release -Zjson-target-spec \
    -Zbuild-std=std,panic_abort --target "$TARGET_JSON" 2>"$WORK/err.log"; then
	echo "FAIL: layout assertions did not compile -- ABI drift:"
	grep -E 'assertion failed|error\[' "$WORK/err.log" | head -20
	exit 1
fi

# Guard against a vacuous pass: the rlib must really be riscv64.
RLIB="$(ls target/*/release/liblayout.rlib 2>/dev/null | head -1)"
if [ -n "$RLIB" ]; then
	OBJ="$(ar t "$RLIB" 2>/dev/null | grep -m1 '\.o$' || true)"
	if [ -n "$OBJ" ]; then
		ar p "$RLIB" "$OBJ" > "$WORK/probe.o" 2>/dev/null || true
		MACH="$(readelf -h "$WORK/probe.o" 2>/dev/null | awk -F: '/Machine/{print $2}' | xargs || true)"
		echo "  rlib machine: ${MACH:-unknown}"
		case "$MACH" in
		*RISC-V*) ;;
		*) echo "FAIL: rlib is not EM_RISCV (got '${MACH:-unknown}')"; exit 1 ;;
		esac
	fi
fi

echo "PASS: riscv64 solarish layout assertions hold (mcontext_t 520, fpregset 264,"
echo "      NGREG 32/NFPREG 33, REG_PC 31 last, AV_RISCV_V present, EM_RISCV)."
