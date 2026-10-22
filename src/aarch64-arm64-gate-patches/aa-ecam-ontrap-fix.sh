#!/bin/bash
# aa-ecam-ontrap-fix.sh — THE named PCIe-config-read fix for the Graviton ZFS/PCIe-scan
# silent reset.
#
# ⛔ BOOT-TESTED 2026-10-22: does NOT stop the reset loop (c6g.metal i-06729f50676ec9979,
#    2 cycles). With aa-ecam-diag.py on top, ZERO [AAECAM] lines: ecam_cfgspace_acc was never
#    entered before the reset. The "confirmed" mechanism below was code-read only; the fault
#    is earlier. Kept as a correct hardening, not as the fix. docs/aarch64-ecam-ontrap-metal-result.md
#
# MECHANISM (confirmed by code-read on the gate @ 6cd2521c1, this stream):
#   The ZFS device scan drives PCIe config-space enumeration.  Each probe lands in
#   ecam_cfgspace_acc() (usr/src/uts/aarch64/io/pciex/ecam/ecam.c), which does a RAW,
#   UNPROTECTED MMIO config read: ddi_get8/16/32/64(ec_handle, ec_base+ECAM(bdf,reg)).
#   On AWS Graviton, a config access to a bus/device/function the fabric rejects raises
#   a SYNCHRONOUS EXTERNAL ABORT.  In EL1 (kernel) that is ESR EC=0x25
#   (T_NV2_DATA_ABORT, "data abort from current EL") -> from_current_el_sync_handler ->
#   trap().  The kernel-mode T_NV2_DATA_ABORT case in trap() (uts/armv8/os/trap.c) ALREADY
#   honors on_trap(OT_DATA_ACCESS)/t_lofault and recovers via ot_trampoline -- BUT the
#   ecam config read sets NEITHER, so trap() falls through to die() and the box
#   silent-resets (0 panic on console: die()'s frame is unreliable at that point).
#
#   This is why the prior SError-vector fix (aa-serror-vector-fix.sh) did NOT help: the
#   fault is NOT an SError (EC=0x2f); it is a same-EL data abort (EC=0x25) that was
#   already routed to trap() and already had recovery available -- it just was never
#   armed around the config read.  The result doc (lines ~149-157) named this exact fix.
#
# FIX: wrap the ecam config access in on_trap(OT_DATA_ACCESS).  On a trapped abort,
#   return the width-correct all-1s (PCI_EINVAL8/16/32/64 == 0xFF.. == PCI "no function"
#   convention) so the config probe treats the slot as absent and the scan continues.
#   Unguarded config access elsewhere still dies; only ecam_cfgspace_acc is protected,
#   which is the single point every config probe routes through.
exec >>/var/log/aa-ecamfix.log 2>&1
set -x
echo "=== ECAM ON_TRAP FIX START $(date) ==="
G=/aarch64/arm64-gate/illumos-gate
F=$G/usr/src/uts/aarch64/io/pciex/ecam/ecam.c
cp "$F" "$F.pre-ecam-ontrap"

python3.9 - "$F" <<"PYEOF"
import sys
f=sys.argv[1]
s=open(f).read()

# 1. include sys/ontrap.h (on_trap/no_trap/OT_DATA_ACCESS) and sys/pci.h (PCI_EINVAL*).
#    sys/pcie_impl.h is already included; add ontrap.h + pci.h after it if absent.
anchor_inc="#include <sys/pcie_impl.h>\n"
add_inc="#include <sys/pcie_impl.h>\n#include <sys/ontrap.h>\n#include <sys/pci.h>\n"
if "#include <sys/ontrap.h>" not in s:
    if anchor_inc not in s:
        print("FATAL: pcie_impl.h include anchor not found"); sys.exit(2)
    s=s.replace(anchor_inc, add_inc, 1)

# 2. Replace the whole config-access body (from the computed addr through the switch)
#    with an on_trap(OT_DATA_ACCESS)-guarded version.  Match verbatim.
old='''	caddr_t addr = softc->ec_base + PCIE_CADDR_ECAM(bus, dev, func, reg);

	switch (req->size) {
	case PCI_CFG_SIZE_BYTE:
		if (req->write) {
			ddi_put8(softc->ec_handle, (uint8_t *)addr, VAL8(req));
		} else {
			VAL16(req) = ddi_get8(softc->ec_handle,
			    (uint8_t *)addr);
		}
		break;
	case PCI_CFG_SIZE_WORD:
		if (req->write) {
			ddi_put16(softc->ec_handle, (uint16_t *)addr,
			    VAL16(req));
		} else {
			VAL16(req) = ddi_get16(softc->ec_handle,
			    (uint16_t *)addr);
		}
		break;
	case PCI_CFG_SIZE_DWORD:
		if (req->write) {
			ddi_put32(softc->ec_handle, (uint32_t *)addr,
			    VAL32(req));
		} else {
			VAL32(req) = ddi_get32(softc->ec_handle,
			    (uint32_t *)addr);
		}
		break;
	case PCI_CFG_SIZE_QWORD:
		if (req->write) {
			ddi_put64(softc->ec_handle, (uint64_t *)addr,
			    VAL64(req));
		} else {
			VAL64(req) = ddi_get64(softc->ec_handle,
			    (uint64_t *)addr);
		}
		break;
	default:
		dev_err(softc->ec_dip, CE_PANIC,
		    "weird %d bit config space access", req->size * NBBY);
	}
}'''

new='''	caddr_t addr = softc->ec_base + PCIE_CADDR_ECAM(bus, dev, func, reg);

	/*
	 * The ECAM config access is a raw MMIO load/store.  On real hardware
	 * (notably AWS Graviton) a config access to a bus/device/function the
	 * host fabric rejects raises a synchronous external abort.  In EL1 that
	 * is a same-EL data abort (ESR EC=0x25), routed to trap(), whose
	 * kernel-mode data-abort case honors on_trap(OT_DATA_ACCESS): if we arm
	 * it here, the abort recovers to ot_trampoline instead of calling die()
	 * (which, on this abort class, silent-resets the box).  On a trapped
	 * read we return the width-correct all-1s -- the PCI "no function"
	 * convention -- so a config probe skips the absent slot and the scan
	 * continues.  Writes to a rejected target are simply dropped.
	 */
	on_trap_data_t otd;

	if (on_trap(&otd, OT_DATA_ACCESS) != 0) {
		/* Took an external abort on the access below; recover. */
		no_trap();
		if (!req->write) {
			switch (req->size) {
			case PCI_CFG_SIZE_BYTE:
				VAL16(req) = PCI_EINVAL8;
				break;
			case PCI_CFG_SIZE_WORD:
				VAL16(req) = PCI_EINVAL16;
				break;
			case PCI_CFG_SIZE_DWORD:
				VAL32(req) = PCI_EINVAL32;
				break;
			case PCI_CFG_SIZE_QWORD:
				VAL64(req) = PCI_EINVAL64;
				break;
			default:
				VAL64(req) = PCI_EINVAL64;
				break;
			}
		}
		return;
	}

	switch (req->size) {
	case PCI_CFG_SIZE_BYTE:
		if (req->write) {
			ddi_put8(softc->ec_handle, (uint8_t *)addr, VAL8(req));
		} else {
			VAL16(req) = ddi_get8(softc->ec_handle,
			    (uint8_t *)addr);
		}
		break;
	case PCI_CFG_SIZE_WORD:
		if (req->write) {
			ddi_put16(softc->ec_handle, (uint16_t *)addr,
			    VAL16(req));
		} else {
			VAL16(req) = ddi_get16(softc->ec_handle,
			    (uint16_t *)addr);
		}
		break;
	case PCI_CFG_SIZE_DWORD:
		if (req->write) {
			ddi_put32(softc->ec_handle, (uint32_t *)addr,
			    VAL32(req));
		} else {
			VAL32(req) = ddi_get32(softc->ec_handle,
			    (uint32_t *)addr);
		}
		break;
	case PCI_CFG_SIZE_QWORD:
		if (req->write) {
			ddi_put64(softc->ec_handle, (uint64_t *)addr,
			    VAL64(req));
		} else {
			VAL64(req) = ddi_get64(softc->ec_handle,
			    (uint64_t *)addr);
		}
		break;
	default:
		no_trap();
		dev_err(softc->ec_dip, CE_PANIC,
		    "weird %d bit config space access", req->size * NBBY);
	}

	no_trap();
}'''

if old not in s:
    print("FATAL: ecam_cfgspace_acc access body not found verbatim"); sys.exit(3)
s=s.replace(old,new,1)
open(f,"w").write(s)
print("patched ecam.c: on_trap(OT_DATA_ACCESS) around config access, all-1s on abort")
PYEOF
echo "patch_rc=$?"
grep -n "on_trap(&otd, OT_DATA_ACCESS)" "$F"
grep -n "PCI_EINVAL32" "$F"
echo "=== ECAM ON_TRAP FIX DONE $(date) ==="
