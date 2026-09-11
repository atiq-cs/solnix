#!/usr/bin/env python3
"""
gen-k3-dts.py -- GENERATE k3.dts from the board's own vendor devicetree dump.

WHY A GENERATOR AND NOT AN EDITOR: k1.dts was hand-written before the board
existed and was wrong on four boot-critical points (hart count, interrupt
controller, MMC IP, UART bind string). Hand-editing it into a k3.dts would
carry the same risk in the same places -- a wrong hart count is invisible in a
diff and fatal at bring-up. So every boot-critical value here is EXTRACTED from
the vendor dump and the extraction ASSERTS on what it found: if the dump does
not contain 16 harts, or contains no memory node, or the console UART is not
where we think, this script FAILS instead of emitting a plausible-looking file.

Input : the vendor devicetree, dumped from the running board with
        `dtc -I fs -O dts /proc/device-tree` (default /tmp/dts).
Output: k3.dts -- a faithful SUBSET carrying only what solnix's fdt.c must
        discover, with each value's provenance recorded in the file.

usage: gen-k3-dts.py [vendor.dts] [out.dts]
"""
import re
import sys

SRC = sys.argv[1] if len(sys.argv) > 1 else "/tmp/dts"
OUT = sys.argv[2] if len(sys.argv) > 2 else "k3.dts"

# The board this generator is FOR. Refuse to generate from a dump of something
# else -- the whole point is that the values are measured from THIS board.
WANT_MODEL = "SpacemiT K3 Pico ITX"
WANT_HARTS = 16
WANT_CONSOLE = "serial@d4017000"

src = open(SRC, encoding="utf-8", errors="replace").read()
fail = []


def need(cond, what):
    if not cond:
        fail.append(what)
    return cond


def cells(text):
    """Parse a `reg = <...>;` value into a list of ints."""
    return [int(t, 16) if t.startswith("0x") else int(t)
            for t in text.replace("<", " ").replace(">", " ").split()]


def prop(body, name):
    """First `name = <...>;` or `name = "...";` value in a node body."""
    m = re.search(r'\b' + re.escape(name) + r'\s*=\s*([^;]+);', body)
    return m.group(1).strip() if m else None


def node_body(text, name, start=0):
    """Extract the brace-balanced body of the node called `name`."""
    m = re.search(r'^([ \t]*)' + re.escape(name) + r'\s*\{', text[start:], re.M)
    if not m:
        return None
    i = start + m.end()
    depth = 1
    while depth and i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
        i += 1
    return text[start + m.end():i - 1]


# ---------------------------------------------------------------- provenance
model = prop(src[:src.index("{", src.index("/ {")) + 4000], "model")
need(model and WANT_MODEL in model,
     f"root model is {model!r}, expected to contain {WANT_MODEL!r}")

# ------------------------------------------------------------------- memory
mem = re.search(r'memory@([0-9a-f]+)\s*\{(.*?)\}', src, re.S)
need(mem, "no memory@ node in the dump")
if mem:
    mreg = cells(prop(mem.group(2), "reg"))
    need(len(mreg) == 4, f"memory reg has {len(mreg)} cells, expected 4 (2+2)")
    dram_base = (mreg[0] << 32) | mreg[1]
    dram_size = (mreg[2] << 32) | mreg[3]
    need(dram_base == int(mem.group(1), 16),
         f"memory reg base {dram_base:#x} != unit address {mem.group(1)}")
    need(dram_size > 0, "memory size is zero")

# ----------------------------------------------------------------- timebase
cpus = node_body(src, "cpus")
need(cpus, "no /cpus node")
timebase = cells(prop(cpus, "timebase-frequency"))[0] if cpus else 0
need(timebase > 0, "no /cpus/timebase-frequency")

# --------------------------------------------------------------------- harts
# Collect every cpu@N: its hart id (reg), ISA, MMU and vendor model string.
harts = {}
for m in re.finditer(r'^\t\tcpu@([0-9a-f]+)\s*\{', src, re.M):
    body = node_body(src, "cpu@" + m.group(1))
    if body is None or prop(body, "device_type") != '"cpu"':
        continue
    hid = cells(prop(body, "reg"))[0]
    harts[hid] = {
        "isa": (prop(body, "riscv,isa") or "").strip('"'),
        "mmu": (prop(body, "mmu-type") or "").strip('"'),
        "model": (prop(body, "model") or "").strip('"'),
        "status": (prop(body, "status") or '"okay"').strip('"'),
    }
need(len(harts) == WANT_HARTS,
     f"found {len(harts)} harts, expected {WANT_HARTS}")
need(sorted(harts) == list(range(len(harts))),
     f"hart ids are not contiguous from 0: {sorted(harts)}")
need(all(h["mmu"] == "riscv,sv39" for h in harts.values()),
     "not every hart is sv39: " + repr({h["mmu"] for h in harts.values()}))

# ------------------------------------------------------------------- console
al = node_body(src, "aliases")
need(al, "no /aliases node")
serial0 = (prop(al, "serial0") or "").strip('"') if al else ""
need(serial0.endswith(WANT_CONSOLE),
     f"serial0 resolves to {serial0!r}, expected .../{WANT_CONSOLE}")

chosen = node_body(src, "chosen")
stdout = (prop(chosen, "stdout-path") or "").strip('"') if chosen else ""
need(stdout.startswith("serial0:"), f"stdout-path is {stdout!r}")
baud = stdout.split(":")[1] if ":" in stdout else ""
need(baud.startswith("115200"), f"console baud is {baud!r}, expected 115200")

uart = node_body(src, WANT_CONSOLE)
need(uart, f"no {WANT_CONSOLE} node")
if uart:
    ureg = cells(prop(uart, "reg"))
    uart_base = (ureg[0] << 32) | ureg[1]
    uart_len = (ureg[2] << 32) | ureg[3]
    uart_compat = prop(uart, "compatible")
    uart_shift = cells(prop(uart, "reg-shift"))[0]
    uart_width = cells(prop(uart, "reg-io-width"))[0]
    uart_irq = cells(prop(uart, "interrupts"))[0]
    need(uart_base == 0xd4017000, f"console UART at {uart_base:#x}")
    need(uart_shift == 2 and uart_width == 4,
         f"UART reg-shift={uart_shift} reg-io-width={uart_width}")

# -------------------------------------------------- interrupt controllers
clint = re.search(r'clint@([0-9a-f]+)\s*\{(.*?)\n\t\t\}', src, re.S)
need(clint, "no clint@ node")
if clint:
    clint_base = int(clint.group(1), 16)
    clint_reg = cells(prop(clint.group(2), "reg"))
    clint_len = (clint_reg[2] << 32) | clint_reg[3]
    need("riscv,clint0" in (prop(clint.group(2), "compatible") or ""),
         "clint is not riscv,clint0")

aplic = imsic = None
for m in re.finditer(r'interrupt-controller@([0-9a-f]+)\s*\{', src):
    body = node_body(src, "interrupt-controller@" + m.group(1))
    compat = prop(body, "compatible") or ""
    reg = cells(prop(body, "reg"))
    ent = {"base": int(m.group(1), 16),
           "len": (reg[2] << 32) | reg[3],
           "nsrc": (cells(prop(body, "riscv,num-sources") or "<0>"))[0],
           "nids": (cells(prop(body, "riscv,num-ids") or "<0>"))[0],
           "hib": (cells(prop(body, "riscv,hart-index-bits") or "<0>"))[0]}
    if "riscv,aplic" in compat:
        aplic = ent
    elif "riscv,imsics" in compat:
        imsic = ent
need(aplic, "no riscv,aplic node -- the K3 external intc is an APLIC")
need(imsic, "no riscv,imsics node")

# ----------------------------------------------------------------- MMC / SD
# Recorded because their state is the reason an SD image is not the boot
# vehicle for this board. Faithfully carried through as disabled.
mmcs = []
for m in re.finditer(r'^\t\tmmc@([0-9a-f]+)\s*\{', src, re.M):
    body = node_body(src, "mmc@" + m.group(1))
    reg = cells(prop(body, "reg"))
    mmcs.append({"base": int(m.group(1), 16),
                 "len": (reg[2] << 32) | reg[3],
                 "compat": (prop(body, "compatible") or "").strip('"'),
                 "status": (prop(body, "status") or '"okay"').strip('"')})
need(mmcs, "no mmc@ nodes at all -- unexpected, check the dump")

if fail:
    print(f"gen-k3-dts: REFUSING to generate from {SRC}", file=sys.stderr)
    for f in fail:
        print(f"  FAIL {f}", file=sys.stderr)
    sys.exit(1)

# ------------------------------------------------------------------- emit
isa_kinds = {}
for hid, h in sorted(harts.items()):
    isa_kinds.setdefault(h["isa"], []).append(hid)
mmc_summary = ", ".join(f"mmc@{m['base']:x} {m['status']}" for m in mmcs)

L = []
w = L.append
w("/dts-v1/;")
w("")
w("/*")
w(" * k3.dts - a faithful SUBSET of the SpacemiT K3 Pico ITX devicetree,")
w(" * GENERATED by gen-k3-dts.py from the board's own vendor DTB dump.")
w(" *")
w(" * DO NOT HAND-EDIT. Re-run:")
w(" *     ./gen-k3-dts.py <vendor.dts> k3.dts")
w(" * Every boot-critical value below was EXTRACTED from the dump, and the")
w(" * generator refuses to emit a file if the dump disagrees with what it")
w(" * expects (16 contiguous sv39 harts, a memory node, an APLIC, and the")
w(" * console UART at 0xd4017000 with reg-shift 2 / reg-io-width 4).")
w(" *")
w(" * The predecessor k1.dts was hand-written before its board existed and was")
w(" * wrong on hart count, interrupt controller, MMC IP and UART bind string.")
w(" * Generating removes exactly that class of error.")
w(" *")
w(f" * Source dump : {SRC}")
w(f" * Board model : {model.strip(chr(34))}")
w(" *")
w(" * MEASURED (from the dump, not inferred):")
w(f" *   DRAM         {dram_base:#x} .. {dram_base + dram_size:#x}"
  f"  ({dram_size / (1 << 30):.1f} GiB)")
w(f" *                ^ note this is {(dram_base - (1 << 32)) >> 20} MiB ABOVE the 4 GiB line,")
w(" *                  so neither 0x80200000 nor a flat 4 GiB is inside DRAM.")
w(f" *   timebase     {timebase} Hz  (the `time` CSR / CLINT rate)")
w(f" *   harts        {len(harts)}: " + "; ".join(
    f"{isa} x{len(ids)}" for isa, ids in sorted(isa_kinds.items())))
w(f" *   console      {serial0} @ {uart_base:#x}, {stdout}")
w(f" *                compatible = {uart_compat}")
w(f" *                reg-shift = {uart_shift}, reg-io-width = {uart_width},"
  f" IRQ {uart_irq}")
w(f" *   CLINT        {clint_base:#x} riscv,clint0")
w(f" *   APLIC        {aplic['base']:#x} riscv,aplic, {aplic['nsrc']} sources")
w(f" *   IMSIC        {imsic['base']:#x} riscv,imsics, {imsic['nids']} ids,"
  f" hart-index-bits {imsic['hib']}")
w(f" *   SD/MMC       {mmc_summary}")
w(" *                ^ ALL DISABLED on this board. There is no SD card path:")
w(" *                  the boot chain lives in SPI NOR (boot_mode=nor) and the")
w(" *                  root device is UFS. Carried through as disabled so the")
w(" *                  kernel does not bind a controller the board does not use.")
w(" *")
w(" * The K3 is an AIA part (APLIC + IMSIC), so fdt_intc_is_aia() selects")
w(" * uts/aia.c here, NOT the PLIC path uts/plic.c that qemu-virt uses.")
w(" */")
w("")
w("/ {")
w("\t#address-cells = <2>;")
w("\t#size-cells = <2>;")
w(f'\tmodel = "SpacemiT K3 Pico ITX (solnix subset)";')
w('\tcompatible = "spacemit,k3-pico-itx";')
w("")
w("\tchosen {")
w(f'\t\tstdout-path = "serial0:{baud}";')
w("\t};")
w("")
w("\taliases {")
w("\t\tserial0 = &uart0;")
w("\t};")
w("")
w("\tcpus {")
w("\t\t#address-cells = <1>;")
w("\t\t#size-cells = <0>;")
w(f"\t\ttimebase-frequency = <{timebase}>;\t/* measured: "
  f"{timebase // 1000000} MHz */")
w("")
w(f"\t\t/*")
w(f"\t\t * {len(harts)} harts. SMP bring-up must handle all of them: hart 0")
w("\t\t * boots and the rest come up via SBI HSM hart_start. The two ISA")
w("\t\t * strings differ ONLY by the `h` (hypervisor) extension, which we do")
w("\t\t * not use, and every hart is sv39 -- so this is not a big.LITTLE")
w("\t\t * problem for the kernel. The COUNT is what matters.")
w("\t\t */")
for hid, h in sorted(harts.items()):
    w(f"\t\tcpu{hid}: cpu@{hid:x} {{")
    w('\t\t\tdevice_type = "cpu";')
    w('\t\t\tcompatible = "riscv";')
    w(f"\t\t\treg = <{hid}>;")
    w(f'\t\t\triscv,isa = "{h["isa"]}";')
    w(f'\t\t\tmmu-type = "{h["mmu"]}";')
    w(f'\t\t\tstatus = "{h["status"]}";\t/* {h["model"]} */')
    w(f"\t\t\tcpu{hid}_intc: interrupt-controller {{")
    w('\t\t\t\tcompatible = "riscv,cpu-intc";')
    w("\t\t\t\t#interrupt-cells = <1>;")
    w("\t\t\t\tinterrupt-controller;")
    w("\t\t\t};")
    w("\t\t};")
    w("")
w("\t};")
w("")
w("\tmemory@%x {" % dram_base)
w('\t\tdevice_type = "memory";')
w(f"\t\treg = <{dram_base >> 32:#x} {dram_base & 0xffffffff:#x} "
  f"{dram_size >> 32:#x} {dram_size & 0xffffffff:#x}>;")
w("\t};")
w("")
w("\tsoc {")
w('\t\tcompatible = "simple-bus";')
w("\t\t#address-cells = <2>;")
w("\t\t#size-cells = <2>;")
w("\t\tranges;")
w("\t\tdma-noncoherent;")
w("")
w(f"\t\tuart0: serial@{uart_base:x} {{")
w(f"\t\t\tcompatible = {uart_compat};")
w(f"\t\t\treg = <0x0 {uart_base:#x} 0x0 {uart_len:#x}>;")
w(f"\t\t\treg-shift = <{uart_shift}>;")
w(f"\t\t\treg-io-width = <{uart_width}>;")
w("\t\t\tinterrupt-parent = <&aplic>;")
w(f"\t\t\tinterrupts = <{uart_irq} 4>;")
w('\t\t\tstatus = "okay";')
w("\t\t};")
w("")
w(f"\t\tclint@{clint_base:x} {{")
w('\t\t\tcompatible = "riscv,clint0";')
w(f"\t\t\treg = <0x0 {clint_base:#x} 0x0 {clint_len:#x}>;")
w("\t\t\tinterrupts-extended = <" + "\n\t\t\t    ".join(
    " ".join(f"&cpu{h}_intc 3 &cpu{h}_intc 7" for h in grp)
    for grp in [sorted(harts)[i:i + 4] for i in range(0, len(harts), 4)]) + ">;")
w("\t\t};")
w("")
w(f"\t\timsic: interrupt-controller@{imsic['base']:x} {{")
w('\t\t\tcompatible = "riscv,imsics";')
w(f"\t\t\treg = <0x0 {imsic['base']:#x} 0x0 {imsic['len']:#x}>;")
w("\t\t\tinterrupt-controller;")
w("\t\t\tmsi-controller;")
w("\t\t\t#interrupt-cells = <0>;")
w("\t\t\t#msi-cells = <0>;")
w(f"\t\t\triscv,num-ids = <{imsic['nids']:#x}>;")
w(f"\t\t\triscv,hart-index-bits = <{imsic['hib']}>;")
w("\t\t\tinterrupts-extended = <" + "\n\t\t\t    ".join(
    " ".join(f"&cpu{h}_intc 9" for h in grp)
    for grp in [sorted(harts)[i:i + 8] for i in range(0, len(harts), 8)]) + ">;")
w('\t\t\tstatus = "okay";')
w("\t\t};")
w("")
w(f"\t\taplic: interrupt-controller@{aplic['base']:x} {{")
w('\t\t\tcompatible = "riscv,aplic";')
w(f"\t\t\treg = <0x0 {aplic['base']:#x} 0x0 {aplic['len']:#x}>;")
w("\t\t\tinterrupt-controller;")
w("\t\t\t#interrupt-cells = <2>;")
w(f"\t\t\triscv,num-sources = <{aplic['nsrc']:#x}>;")
w("\t\t\tmsi-parent = <&imsic>;")
w('\t\t\tstatus = "okay";')
w("\t\t};")
w("")
for m in mmcs:
    w(f"\t\tmmc@{m['base']:x} {{")
    w(f'\t\t\tcompatible = "{m["compat"]}";')
    w(f"\t\t\treg = <0x0 {m['base']:#x} 0x0 {m['len']:#x}>;")
    w(f'\t\t\tstatus = "{m["status"]}";\t/* as measured on the board */')
    w("\t\t};")
    w("")
w("\t};")
w("};")

open(OUT, "w").write("\n".join(L) + "\n")
print(f"gen-k3-dts: wrote {OUT} from {SRC}")
print(f"  DRAM      {dram_base:#x} + {dram_size:#x} "
      f"({dram_size / (1 << 30):.1f} GiB), ends {dram_base + dram_size:#x}")
print(f"  timebase  {timebase} Hz")
print(f"  harts     {len(harts)} (" + ", ".join(
    f"{isa}x{len(i)}" for isa, i in sorted(isa_kinds.items())) + ")")
print(f"  console   {uart_base:#x} {uart_compat} shift={uart_shift} "
      f"width={uart_width} irq={uart_irq} baud={baud}")
print(f"  intc      APLIC {aplic['base']:#x} + IMSIC {imsic['base']:#x} (AIA)")
print(f"  mmc       {mmc_summary}")
