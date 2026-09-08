#!/usr/bin/env python3
"""
Static measurement of the size of the FDT blob that dboot_synth_fdt() emits,
computed for REAL Graviton ACPI tables vs QEMU-virt, to test whether
SYNTH_FDT_MAX (16384) overflows on real hardware.

This is a faithful mirror of libfdt's SEQUENTIAL-WRITE space accounting
(usr/src/common/fdt/fdt_sw.c), not an approximation:

  fdt_create(buf, bufsize):
      off_mem_rsvmap = FDT_ALIGN(sizeof(fdt_header)=40, sizeof(rsv_entry)=16) = 48
      off_dt_struct  = off_mem_rsvmap
      off_dt_strings = bufsize          (strings grow DOWN from the end)
  fdt_grab_space_(len) fails (-FDT_ERR_NOSPACE) when
      size_dt_struct + len > totalsize - off_dt_struct - size_dt_strings
  fdt_begin_node(name)      -> 4 (tag) + FDT_ALIGN(strlen(name)+1, 4)
  fdt_end_node()            -> 4 (tag)
  fdt_property(name,val,n)  -> 12 (tag+len+nameoff) + FDT_ALIGN(n, 4)
                               + strlen(name)+1 into the strings block (deduped)
  fdt_finish()              -> 4 (FDT_END tag)

Every one of those calls in dboot_synth_fdt.c is `(void)`-cast, so a NOSPACE
return is silent: the node/property is simply not written and emission carries on.

Usage: aa-synth-fdt-size.py <MADT.bin>
"""
import struct
import sys

HDR = 40                      # sizeof(struct fdt_header)
RSV_ENTRY = 16                # sizeof(struct fdt_reserve_entry)
SYNTH_FDT_MAX = 16384         # dboot_synth_fdt.c:121


def align(n, a):
    return (n + a - 1) & ~(a - 1)


class SwFdt:
    """libfdt sequential-write space accounting."""

    def __init__(self, bufsize):
        self.totalsize = bufsize
        self.off_dt_struct = align(HDR, RSV_ENTRY)   # 48
        self.size_dt_struct = 0
        self.size_dt_strings = 0
        self.strings = {}          # name -> offset (dedup, like fdt_find_add_string_)
        self.nospace = []          # log of what got silently dropped
        self.first_nospace_at = None
        self.tail = []             # emission log, for the truncation boundary

    # --- space checks -----------------------------------------------------
    def _spaceleft(self):
        return self.totalsize - self.off_dt_struct - self.size_dt_strings

    def _grab(self, n, what):
        if self.size_dt_struct + n > self._spaceleft():
            self.nospace.append(what)
            if self.first_nospace_at is None:
                self.first_nospace_at = what
            return False
        self.size_dt_struct += n
        return True

    def _add_string(self, s):
        """fdt_find_add_string_: dedup, else grow the strings block downward."""
        if s in self.strings:
            return True
        n = len(s) + 1
        # fdt_splice_struct_/strings space check
        if self.size_dt_struct + 0 > self._spaceleft() - n:
            self.nospace.append("string:" + s)
            if self.first_nospace_at is None:
                self.first_nospace_at = "string:" + s
            return False
        self.size_dt_strings += n
        self.strings[s] = self.size_dt_strings
        return True

    # --- emitter API ------------------------------------------------------
    def begin_node(self, name):
        ok = self._grab(4 + align(len(name) + 1, 4), "node:" + (name or "/"))
        self.tail.append(("node", name or "/", ok))
        return ok

    def end_node(self):
        return self._grab(4, "end_node")

    def prop(self, name, nbytes):
        # libfdt adds the name string first, then grabs struct space.
        ok = self._add_string(name)
        ok = self._grab(12 + align(nbytes, 4), "prop:" + name) and ok
        return ok

    def prop_string(self, name, s):
        return self.prop(name, len(s) + 1)

    def prop_cell(self, name, _v=0):
        return self.prop(name, 4)

    def add_reservemap_entry(self):
        return self._grab(RSV_ENTRY, "rsvmap")

    def finish(self):
        self._grab(4, "FDT_END")
        return HDR + 32 + self.size_dt_struct + self.size_dt_strings

    def used(self):
        return self.off_dt_struct + self.size_dt_struct + self.size_dt_strings


# ---------------------------------------------------------------- MADT parse
def parse_madt(path):
    b = open(path, "rb").read()
    sig, length = struct.unpack_from("<4sI", b, 0)
    oem = struct.unpack_from("<6s", b, 10)[0]
    gicd = its = None
    mpidrs = []
    gicr_bases = []
    off = 44                                   # header(36) + Address(4) + Flags(4)
    while off < length:
        t, ln = struct.unpack_from("<BB", b, off)
        if ln == 0:
            break
        if t == 12:                            # GENERIC_DISTRIBUTOR
            gicd = struct.unpack_from("<Q", b, off + 8)[0]
        elif t == 15:                          # GENERIC_TRANSLATOR (ITS)
            its = struct.unpack_from("<Q", b, off + 8)[0]
        elif t == 11:                          # GENERIC_INTERRUPT (GICC)
            gicr = struct.unpack_from("<Q", b, off + 60)[0]
            mpidr = struct.unpack_from("<Q", b, off + 68)[0]
            mpidrs.append(mpidr)
            if gicr:
                gicr_bases.append(gicr)
        off += ln
    return {
        "sig": sig.decode(), "oem": oem.decode().strip("\x00"),
        "gicd": gicd, "its": its, "mpidrs": mpidrs,
        "ngicr_distinct": len(set(gicr_bases)),
    }


def coalesce_regions(bases):
    """Mirror of synth_gicr_coalesce(): maximal constant-stride runs."""
    b = sorted(set(bases))
    if not b:
        return 0
    deltas = [b[i + 1] - b[i] for i in range(len(b) - 1)]
    pos = [d for d in deltas if d > 0]
    stride = min(pos) if pos else 0x20000
    regions, n = 0, 1
    for i in range(1, len(b)):
        if b[i] - b[i - 1] == stride:
            n += 1
        else:
            regions += 1
            n = 1
    return regions + 1


def nodename(prefix, addr):
    """Mirror of synth_nodename(): "<prefix>@<lowercase hex, no leading 0s>"."""
    return "%s@%x" % (prefix, addr)


# ------------------------------------------------------- the emitter mirror
def emit(ncpu, mpidrs, gicd, its, ngicr_regions, uart, necam, ecam,
         ncrs_win, qemu, bufsize=SYNTH_FDT_MAX):
    """Mirror dboot_synth_fdt() emission order exactly (line refs in comments)."""
    f = SwFdt(bufsize)
    f.add_reservemap_entry()                     # fdt_add_reservemap_entry(0,0)
    f.add_reservemap_entry()                     # fdt_finish_reservemap()

    f.begin_node("")                             # :980 root
    f.prop_cell("#address-cells"); f.prop_cell("#size-cells")
    f.prop_cell("interrupt-parent")
    f.prop_string("compatible", "solnix,acpi-synth")
    f.prop_cell("phandle")

    f.begin_node("chosen"); f.prop_cell("phandle"); f.end_node()          # :988

    f.begin_node("psci")                                                  # :993
    f.prop_string("compatible", "arm,psci-1.0")
    f.prop_string("method", "smc")
    for p in ("cpu_suspend", "cpu_off", "cpu_on", "migrate"):
        f.prop_cell(p)
    f.prop_cell("phandle"); f.end_node()

    f.begin_node("cpus")                                                  # :1006
    f.prop_cell("#address-cells"); f.prop_cell("#size-cells")
    f.prop_cell("phandle")
    for i in range(ncpu):                                                 # :1015
        f.begin_node(nodename("cpu", mpidrs[i] if i < len(mpidrs) else i))
        f.prop_string("device_type", "cpu")
        f.prop_string("compatible", "arm,armv8")
        f.prop_string("enable-method", "psci")
        f.prop_cell("reg"); f.prop_cell("phandle")
        f.end_node()
    f.end_node()

    f.begin_node("memory@0")                                              # :1033
    f.prop_string("device_type", "memory")
    f.prop("reg", 16); f.prop_cell("phandle"); f.end_node()

    f.begin_node("timer")                                                 # :1040 -> arm_gtmr0
    f.prop_string("compatible", "arm,armv8-timer")
    f.prop("interrupts", 48)                     # 12 cells
    f.prop("always-on", 0)
    f.prop_cell("phandle"); f.end_node()

    f.begin_node(nodename("intc", gicd))                                  # :1064 -> gicthree0
    f.prop_string("compatible", "arm,gic-v3")
    f.prop_cell("#interrupt-cells")
    f.prop("interrupt-controller", 0)
    f.prop_cell("#address-cells"); f.prop_cell("#size-cells")
    f.prop_cell("#redistributor-regions")
    f.prop("ranges", 0)
    f.prop_cell("phandle")
    f.prop("reg", 4 * 4 * (1 + ngicr_regions))   # GICD pair + one pair per region
    if its is not None:                                                   # :1117 -> gicv3_its0
        f.begin_node(nodename("its", its))
        f.prop_string("compatible", "arm,gic-v3-its")
        f.prop("msi-controller", 0)
        f.prop_cell("#msi-cells"); f.prop_cell("phandle")
        f.prop("reg", 16)
        f.end_node()
    f.end_node()                                 # intc

    if uart:                                                              # :1131 -> ns16550a1
        f.begin_node(nodename("serial", uart["base"]))
        f.prop_string("compatible", uart["compat"])
        f.prop("reg", 16)
        if uart["irq"] >= 32:
            f.prop("interrupts", 12)
        f.prop_cell("phandle")
        f.end_node()

    if qemu:                                     # 32 virtio-mmio slots, QEMU only
        for n in range(32):
            f.begin_node(nodename("virtio_mmio", 0xA000000 + n * 0x200))
            f.prop_string("compatible", "virtio,mmio")
            f.prop("reg", 16); f.prop("interrupts", 12)
            f.prop("dma-coherent", 0); f.prop_cell("phandle")
            f.end_node()

    for i in range(necam):                                                # :1183 -> ecam0
        f.begin_node(nodename("pcie", ecam["base"]))
        f.prop_string("compatible", "pci-host-ecam-generic")
        f.prop_string("device_type", "pci")
        f.prop_cell("#address-cells"); f.prop_cell("#size-cells")
        f.prop_cell("#interrupt-cells"); f.prop_cell("linux,pci-domain")
        f.prop("bus-range", 8)
        f.prop("ranges", ncrs_win * 7 * 4)
        if its is not None:
            f.prop("msi-map", 16)
        f.prop("reg", 16)
        f.prop_cell("phandle")
        f.end_node()

    f.end_node()                                 # root
    total = f.finish()
    return f, total


def report(label, f, total, bufsize=SYNTH_FDT_MAX):
    print("=== %s ===" % label)
    print("  emitted blob size      : %d bytes" % total)
    print("  SYNTH_FDT_MAX          : %d bytes" % bufsize)
    print("  headroom               : %+d bytes" % (bufsize - total))
    if f.nospace:
        print("  *** OVERFLOW: %d writes silently dropped (-FDT_ERR_NOSPACE)"
              % len(f.nospace))
        print("  first dropped write    : %s" % f.first_nospace_at)
        nodes = [n for (k, n, ok) in f.tail if k == "node"]
        wrote = [n for (k, n, ok) in f.tail if k == "node" and ok]
        lost = [n for (k, n, ok) in f.tail if k == "node" and not ok]
        print("  nodes attempted/written: %d / %d" % (len(nodes), len(wrote)))
        print("  last node written      : %s" % (wrote[-1] if wrote else "(none)"))
        print("  FIRST node LOST        : %s" % (lost[0] if lost else "(none)"))
        print("  nodes LOST             : %s" % ", ".join(lost[:12]))
    else:
        print("  fits, nothing dropped")
    print()
    return bool(f.nospace)


def main():
    madt_path = sys.argv[1]
    m = parse_madt(madt_path)
    # Real Graviton GICR bases, from the committed MADT decode.
    b = open(madt_path, "rb").read()
    length = struct.unpack_from("<I", b, 4)[0]
    gicr, off = [], 44
    while off < length:
        t, ln = struct.unpack_from("<BB", b, off)
        if ln == 0:
            break
        if t == 11:
            g = struct.unpack_from("<Q", b, off + 60)[0]
            if g:
                gicr.append(g)
        off += ln
    nreg = coalesce_regions(gicr)

    print("REAL GRAVITON GROUND TRUTH (%s)" % madt_path)
    print("  OEM=%s  ngicc=%d  distinct GICR=%d  coalesced regions=%d"
          % (m["oem"], len(m["mpidrs"]), m["ngicr_distinct"], nreg))
    print("  gicd=0x%x  its=%s" % (m["gicd"],
          ("0x%x" % m["its"]) if m["its"] else "none"))
    print("  mpidr[0..3]=%s" % [hex(x) for x in m["mpidrs"][:4]])
    print()

    # Real Graviton: SPCR UART, MCFG ECAM 0x20000000 bus 0-255, 3 _CRS windows.
    # (ECAM base / _CRS windows are the committed ground truth from
    #  docs/aarch64-A6-hw-crs-fix.md, verified against a6hw-graviton-DSDT.bin.)
    uart_hw = {"base": 0xFFFFFFF00000, "compat": "arm,pl011", "irq": 33}
    fh, th = emit(ncpu=len(m["mpidrs"]), mpidrs=m["mpidrs"], gicd=m["gicd"],
                  its=m["its"], ngicr_regions=nreg, uart=uart_hw, necam=1,
                  ecam={"base": 0x20000000}, ncrs_win=3, qemu=False)
    hw_overflow = report("REAL GRAVITON (c6g.metal, %d cpus, %d GICR regions)"
                         % (len(m["mpidrs"]), nreg), fh, th)

    # QEMU virt, 2 cpus: the configuration every prior success was measured on.
    fq, tq = emit(ncpu=2, mpidrs=[0x0, 0x1], gicd=0x8000000, its=0x8080000,
                  ngicr_regions=1,
                  uart={"base": 0x9000000, "compat": "arm,pl011", "irq": 33},
                  necam=1, ecam={"base": 0x4010000000}, ncrs_win=3, qemu=True)
    qemu_overflow = report("QEMU virt (2 cpus, 1 GICR region, +32 virtio-mmio)",
                          fq, tq)

    # Where does it start to break? Sweep cpu count.
    print("=== cpu-count sweep (real-hw shape: 4 GICR regions, no virtio) ===")
    prev_ok = True
    for n in (2, 4, 8, 16, 24, 32, 40, 48, 56, 64, 96, 128):
        mp = m["mpidrs"][:n] if n <= len(m["mpidrs"]) else \
            m["mpidrs"] + [0x10000 + i for i in range(n - len(m["mpidrs"]))]
        ff, tt = emit(ncpu=n, mpidrs=mp, gicd=m["gicd"], its=m["its"],
                      ngicr_regions=nreg, uart=uart_hw, necam=1,
                      ecam={"base": 0x20000000}, ncrs_win=3, qemu=False)
        ok = not ff.nospace
        lost = [x for (k, x, o) in ff.tail if k == "node" and not o]
        print("  %3d cpus: %6d bytes  %-8s %s" %
              (n, tt, "FITS" if ok else "OVERFLOW",
               ("first node lost: " + lost[0]) if lost else ""))
        if prev_ok and not ok:
            print("        ^^^ threshold crossed between the previous row and this one")
        prev_ok = ok
    print()

    # What buffer size would real Graviton need?
    print("=== required SYNTH_FDT_MAX for real Graviton (%d cpus) ===" % len(m["mpidrs"]))
    need = None
    for sz in range(8192, 262145, 1024):
        ff, tt = emit(ncpu=len(m["mpidrs"]), mpidrs=m["mpidrs"], gicd=m["gicd"],
                      its=m["its"], ngicr_regions=nreg, uart=uart_hw, necam=1,
                      ecam={"base": 0x20000000}, ncrs_win=3, qemu=False,
                      bufsize=sz)
        if not ff.nospace:
            need = sz
            break
    print("  smallest 1KiB-granular size that fits 64 cpus: %s bytes" % need)
    print("  (128 cpus / future Graviton needs headroom above that)")
    print()

    # ---------------- NEGATIVE CONTROL ----------------
    # A measurement that cannot fail proves nothing. Sabotage the mechanism two
    # ways and confirm the verdict flips.
    print("=== NEGATIVE CONTROLS (the check must flip) ===")
    fn, tn = emit(ncpu=len(m["mpidrs"]), mpidrs=m["mpidrs"], gicd=m["gicd"],
                  its=m["its"], ngicr_regions=nreg, uart=uart_hw, necam=1,
                  ecam={"base": 0x20000000}, ncrs_win=3, qemu=False,
                  bufsize=65536)
    print("  [NC1] real Graviton with SYNTH_FDT_MAX=65536 -> %s  (expect FITS)"
          % ("OVERFLOW" if fn.nospace else "FITS"))
    fn2, tn2 = emit(ncpu=2, mpidrs=[0, 1], gicd=m["gicd"], its=m["its"],
                    ngicr_regions=nreg, uart=uart_hw, necam=1,
                    ecam={"base": 0x20000000}, ncrs_win=3, qemu=False,
                    bufsize=1024)
        # tiny buffer must overflow even with 2 cpus
    print("  [NC2] 2 cpus with SYNTH_FDT_MAX=1024 -> %s  (expect OVERFLOW)"
          % ("OVERFLOW" if fn2.nospace else "FITS"))
    ok_nc = (not fn.nospace) and bool(fn2.nospace)
    print("  negative controls: %s" % ("PASS" if ok_nc else "FAIL"))
    print()

    print("VERDICT: real-Graviton overflow = %s ; QEMU overflow = %s"
          % (hw_overflow, qemu_overflow))
    return 0


if __name__ == "__main__":
    sys.exit(main())
