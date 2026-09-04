// Compile-time layout assertions for the riscv64 solarish libc arch module.
//
// These exist because a COMPILING PROBE IS NOT A VERIFIED LAYOUT. The first
// version of libc-solarish-riscv64-arch-module.patch compiled fine and was
// reported as verified, yet carried an ABI break: the fp union's flat view was
// an x86-FXSAVE shape ([[u32;16];17]), which made mcontext_t 1088 bytes instead
// of 520 -- a libc ucontext_t LARGER than the kernel's, i.e. a signal handler
// smashing the stack on real hardware. Nothing about that shows up in a probe
// that merely names the types. Asserting sizes does show it.
//
// Run (from a checkout of the libc crate with the patch applied):
//     cargo build --target riscv64gc-unknown-illumos -Zbuild-std
// with this file included in the crate (e.g. as a module or a tests/ target);
// every assertion is `const _: () = assert!(..)` so a violation is a COMPILE
// error, not a runtime failure.
//
// Negative control: restore the x86 [[u32;16];17] view and these MUST fail. If
// they still pass, the assertions have stopped being meaningful -- fix them.
//
// Re-check whenever the libc crate is bumped, and especially when a real illumos
// riscv64 <sys/regset.h> lands: the NGREG/REG_* ordering here follows solnix's
// own kernel trap frame (src/riscv/uts/regs.h: x1..x31 in slots 0..30, PC LAST
// at 31) cross-checked against NetBSD's nb_mcontext.h, and the authoritative
// header could still differ.

// Compile-time assertions on the riscv64 solarish arch surface. These fail the
// BUILD if the layout drifts, which is what caught the x86 FXSAVE view being
// copied verbatim into the RV64 union.
use core::mem::{align_of, size_of};

// fpchip_state: 32 * u64 (f0..f31) + fcsr u32 + pad u32 == 264.
const _: () = assert!(size_of::<libc::__c_anonymous_fpchip_state>() == 264);
// Both union views must be the same 264 bytes; a mismatched view silently
// inflates ucontext_t (the x86 [[u32;13];10] view is 520).
const _: () = assert!(size_of::<libc::__c_anonymous_fp_reg_set>() == 264);
const _: () = assert!(size_of::<libc::fpregset_t>() == 264);
// mcontext_t: NGREG(32) * greg_t(8) == 256, + fpregset 264 == 520.
const _: () = assert!(size_of::<libc::mcontext_t>() == 520);
const _: () = assert!(align_of::<libc::mcontext_t>() == 8);
// Elf64_Phdr is the fixed 56-byte LP64 ELF program header.
const _: () = assert!(size_of::<libc::Elf64_Phdr>() == 56);
const _: () = assert!(size_of::<libc::greg_t>() == 8);
// ucontext_t must contain the mcontext and stay 8-aligned.
const _: () = assert!(size_of::<libc::ucontext_t>() >= 520);
const _: () = assert!(align_of::<libc::ucontext_t>() == 8);

// Register indices: 0..30 == x1..x31, PC last. No x0 slot.
const _: () = assert!(libc::REG_X1 == 0);
const _: () = assert!(libc::REG_X31 == 30);
const _: () = assert!(libc::REG_PC == 31);
const _: () = assert!(libc::NGREG == 32);
const _: () = assert!(libc::NFPREG == 33);
// Every index must be in range of the gregs array.
const _: () = assert!((libc::REG_PC as usize) < libc::NGREG);
// ABI aliases must agree with the RISC-V psABI numbering.
const _: () = assert!(libc::REG_SP == 1 && libc::REG_GP == 2 && libc::REG_TP == 3);
const _: () = assert!(libc::REG_A0 == 9 && libc::REG_A7 == 16);
const _: () = assert!(libc::REG_S0 == libc::REG_FP);
const _: () = assert!(libc::REG_FPCSR == 32 && (libc::REG_FPCSR as usize) < libc::NFPREG);
// Hwcaps are distinct single bits.
const _: () = assert!(libc::AV_RISCV_V == 0x20);
const _: () = assert!(libc::AV_RISCV_M | libc::AV_RISCV_V == 0x21);
