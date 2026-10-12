#!/bin/bash
# aa-serror-vector-fix.sh — route the SError (async abort) exception vector through
# trap() instead of UNEXPECTED() (a bare `bl panic` with NO register/frame save).
# WHY: on real Graviton the ZFS/PCIe config-space scan raises an SError; the current
# from_current_el_error vector does UNEXPECTED() which calls panic WITHOUT saving a
# frame, so panic runs on an unreliable stack and the box SILENT-RESETS (0 panic text
# on the console - exactly what we measured). Mirroring the sync vector
# (clrex; __SAVE_REGS_EL1; __SAVE_FRAME; b <handler>) gives trap() a valid frame + the
# ESR/FAR, so the SError is REPORTED (visible panic with the faulting address) and, if
# a protected access set t_lofault/t_ontrap, RECOVERED (see aa-serror-lofault-fix.sh).
exec >>/var/log/aa-serrorvec.log 2>&1
set -x
echo "=== SERROR VECTOR FIX START $(date) ==="
G=/aarch64/arm64-gate/illumos-gate
E=$G/usr/src/uts/armv8/ml/exceptions.S
cp $E $E.pre-serror

python3.9 - "$E" <<"PYEOF"
import sys
f=sys.argv[1]
s=open(f).read()

# 1. Rewrite the current-EL SError vector to save a frame and branch to a handler.
old_vec="""ALTENTRY(from_current_el_error)
	UNEXPECTED()
	CHECK_VECTOR_ENTRY(from_current_el_error)
SET_SIZE(from_current_el_error)"""
new_vec="""ALTENTRY(from_current_el_error)
	clrex
	__SAVE_REGS_EL1
	__SAVE_FRAME
	b	from_current_el_error_handler
	CHECK_VECTOR_ENTRY(from_current_el_error)
SET_SIZE(from_current_el_error)"""
if old_vec not in s:
    print("FATAL: from_current_el_error vector not found verbatim"); sys.exit(2)
s=s.replace(old_vec,new_vec,1)

# 2. Add the C-side handler, mirroring from_current_el_sync_handler (ESR/FAR -> trap()).
#    Insert right after the sync handler's SET_SIZE.
anchor="""	__RESTORE_REGS_EL1
	eret
	SET_SIZE(from_current_el_sync_handler)"""
addition=anchor+"""

	/*
	 * Current-EL SError (async abort) handler.  Mirror the sync handler:
	 * hand trap() the EC/ESR/FAR and a valid frame so an SError is reported
	 * (or recovered via t_lofault/t_ontrap) instead of silently resetting
	 * the box from a frameless panic.  See aa-serror-vector-fix.sh.
	 */
	ENTRY(from_current_el_error_handler)
	mrs	x1, esr_el1
	lsr	w0, w1, #ESR_EC_SHIFT	// w0 <- EC
	mrs	x2, far_el1
	mov	x3, sp
	mov	x29, sp
	bl	trap
	cbz	x0, 1f
	b	_sys_rtt
1:
	__RESTORE_REGS_EL1
	eret
	SET_SIZE(from_current_el_error_handler)"""
if anchor not in s:
    print("FATAL: sync handler anchor not found"); sys.exit(2)
s=s.replace(anchor,addition,1)

open(f,"w").write(s)
print("patched exceptions.S: SError vector -> from_current_el_error_handler -> trap()")
PYEOF
echo "patch_rc=$?"
grep -n "from_current_el_error_handler" $E
echo "=== SERROR VECTOR FIX DONE $(date) ==="
