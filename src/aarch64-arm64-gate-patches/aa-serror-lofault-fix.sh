#!/bin/bash
# aa-serror-lofault-fix.sh — targeted fix for the metal ZFS/PCIe-scan silent reset.
# MECHANISM (observed by code-reading): the ZFS device scan drives PCIe config-space
# enumeration (ecam_cfgspace_acc -> ddi_get32 at ECAM base). A config read to a
# device/bus the Graviton fabric rejects raises an SError (async abort). The kernel
# T_SERROR case in trap() unconditionally die()s -> panic -> but on an imprecise
# SError the panic frame is unreliable and the box silent-resets (0 panic on console).
# FIX: give the kernel-mode T_SERROR case the SAME t_ontrap/t_lofault recovery the
# T_DATA_ABORT case has, so a config probe guarded by on_trap()/ddi_peek (which set
# t_ontrap OT_DATA_ACCESS / t_lofault) RECOVERS (returns EFAULT / jumps to the
# lofault label) instead of dying. Enumeration then skips the bad device and continues.
exec >>/var/log/aa-serrorfix.log 2>&1
set -x
echo "=== SERROR FIX START $(date) ==="
G=/aarch64/arm64-gate/illumos-gate
T=$G/usr/src/uts/armv8/os/trap.c
cp $T $T.pre-serror

# In the kernel-mode switch (the 'else' branch ~line 892), move T_SERROR out of the
# fatal die() group and give it t_ontrap/t_lofault recovery. We do this with a precise
# python edit: replace the fatal "case T_SERROR:" line in the kernel switch with a
# recovery block, leaving the user-mode T_SERROR (siginfo) case untouched.
python3.9 - "$T" <<"PYEOF"
import sys,re
f=sys.argv[1]
s=open(f).read()

# The kernel-mode fatal group:
#   case T_FP_EXCEPTION:
#   case T_PC_ALIGNMENT:
#   case T_SP_ALIGNMENT:
#   case T_SERROR:
#   case T_ILLEGAL_STATE:
#   default:
#       die(ec, esr, addr, rp);
#       break;
# Remove T_SERROR from this group and add a recovering case before it.
old="""		case T_FP_EXCEPTION:
		case T_PC_ALIGNMENT:
		case T_SP_ALIGNMENT:
		case T_SERROR:
		case T_ILLEGAL_STATE:
		default:
			die(ec, esr, addr, rp);
			break;"""
new="""		/*
		 * A kernel-mode SError raised while a protected access is in
		 * flight (on_trap(OT_DATA_ACCESS) or a t_lofault handler, as set
		 * by ddi_peek()/the PCIe config-space accessor) is recoverable:
		 * recover exactly as the data-abort path does rather than dying.
		 * This is what lets PCIe config-space enumeration survive a
		 * device/bus the fabric rejects (observed on AWS Graviton: the
		 * ZFS device scan's config probe SErrors, which previously
		 * silent-reset the box).  An unguarded kernel SError still dies.
		 */
		case T_SERROR:
			if ((ct->t_ontrap != NULL) &&
			    (ct->t_ontrap->ot_prot & OT_DATA_ACCESS)) {
				ct->t_ontrap->ot_trap |= OT_DATA_ACCESS;
				rp->r_pc = ct->t_ontrap->ot_trampoline;
				goto cleanup;
			}
			if (ct->t_lofault != 0) {
				rp->r_x0 = EFAULT;
				rp->r_pc = ct->t_lofault;
				goto cleanup;
			}
			die(ec, esr, addr, rp);
			break;
		case T_FP_EXCEPTION:
		case T_PC_ALIGNMENT:
		case T_SP_ALIGNMENT:
		case T_ILLEGAL_STATE:
		default:
			die(ec, esr, addr, rp);
			break;"""
if old not in s:
    print("FATAL: kernel SERROR fatal group not found verbatim")
    sys.exit(2)
s=s.replace(old,new,1)
open(f,"w").write(s)
print("patched trap.c kernel T_SERROR -> t_ontrap/t_lofault recovery")
PYEOF
echo "patch_rc=$?"
grep -n "A kernel-mode SError raised" $T
echo "=== SERROR FIX DONE $(date) ==="
