# aarch64: the ZFS-scan stall is PCIe root-complex enumeration, not ITS/MSI

Diagnosed from the console evidence already in hand, no hardware spend. I had ranked
**ITS/MSI** as the leading suspect. **That was wrong**, and the console rules it out.

## The evidence

On real Graviton (`artifacts/a6uart-metal-console-raw.txt`), the tail of the boot is:

```
scsi_vhci0 at root
scsi_vhci0 is /scsi_vhci
gicthree0 at root: <GICD + all 4 GICR regions>
arm_gtmr0 at root
NOTICE: Performing full ZFS device scan!
<nothing further>
```

**Nothing attaches after `arm_gtmr0`.** No `ecam0`, no `pcie`, no `pcierc`, no `nvme`, no
`blkdev`. The PCIe root complex never appears at all.

## Why that rules out ITS/MSI

An interrupt-delivery problem requires a device that enumerated and is waiting for
completions. Here **there is no device**: ZFS is scanning because it has nothing to scan.
MSI/ITS cannot be the cause of a device that was never attached — it would be the *next*
problem after enumeration works, not this one.

So the ordering is: **enumerate the RC → find the NVMe function → attach → then MSI matters.**
We are at step one.

## Why nothing has ever caught this

The working QEMU boot roots off **virtio-mmio**, not PCIe
(`artifacts/aarch64-a5/qemu-console-a5.log`):

```
Block device: blkdev@0,0, blkdev0
blkdev0 is /virtio_mmio@a003c00/vioblk@a003c00/blkdev@0,0
```

So **the PCIe/ECAM attach path has never been exercised on any platform** — QEMU took an
entirely different route to a root device. Every prior leg's success on QEMU said nothing
about it. (Same trap as the earlier refuted hypothesis, where QEMU ran GICv2 while the metal
runs GICv3: *confirm both sides of a comparison execute the same code.*)

## What is known to be in place

The synthesized FDT does emit the pieces:

* an **ECAM node per MCFG allocation** (`synth_scan_mcfg`, `bi_pcierc_cnt`), with the
  IO/MMIO32/MMIO64 windows taken from the PCIe host-bridge `_CRS` as the DT `ranges`;
* **ITS/MSI plumbing** — `msi-controller`, `msi-map`, and the GIC as `msi-parent`.

So the FDT is likely not empty. The failure is more probably on the *consumer* side: no
driver binds to the emitted node, or it binds and finds nothing.

## The ordered hypotheses to test (cheap now — the console is ~130x faster)

1. **No driver binds the ECAM node.** A prior agent was mid-investigation on exactly this
   when it terminated, asking whether **`ecam` appears in the image's `driver_aliases`**. If
   the FDT node's `compatible` does not match any alias, illumos silently attaches nothing —
   which looks precisely like this. **Check `driver_aliases` in the image first; it is one
   grep and needs no boot.**
2. **The node is emitted but malformed** — wrong `#address-cells`/`#size-cells`,
   `bus-range`, or `ranges` encoding, so the nexus rejects it. Note an earlier DTS fix in
   this project had to add exactly those PCI-bridge properties to satisfy a conforming
   parser.
3. **The RC attaches but enumeration finds no functions** — config-space accesses returning
   all-ones (the classic unposted/unclocked signature), which on this platform would need the
   ECAM base or the `_CRS`-derived windows checked against the real hardware.

Distinguishing 1 from 2/3 is cheap: `-B prom_debug=1` is affordable now, and a bounded
marker at the nexus attach point says whether the driver is even entered.

## Note on cost

Four agents have now been dispatched at this blocker; three truncated (one at 30 tool uses,
during initial reading) and none reached a metal boot. This diagnosis came from re-reading
console logs already committed — worth doing before spending another agent or another
`c6g.metal`.
