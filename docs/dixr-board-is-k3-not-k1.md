# ⚠️ The board is a **SpacemiT K3**, not a K1 — the RISC-V payload targets the wrong SoC

## What `/tmp/dixr-system.txt` establishes

`sudo lshw` is unambiguous:

```
product: SpacemiT K3 Pico ITX
```

And the CPU topology contradicts every assumption in `src/riscv/uts/k1.dts`:

| fact | our `k1.dts` | **the real board** |
|---|---|---|
| SoC | SpacemiT **K1** (X60 cores) | **SpacemiT K3 Pico ITX** |
| CPUs | 8 `cpu@` nodes | **16** — `Spacemit(R) A100` ×8 **+** `Spacemit(R) X100` ×8 |
| vendor id | — | `0x710` |
| topology | uniform | **heterogeneous** (two core types, big.LITTLE-style) |
| clock | — | X100 at 2200 MHz |
| root device | microSD | `sda` 119.3 G + seven `mtdblock` SPI-flash devices — **UFS, and the boot chain is in SPI NOR; there is no SD path at all** (see `k3-vendor-dtb-findings.md`) |
| PCIe | none modelled | **`SpacemiT X100 PCIe Root Complex`**, two root complexes, 128 M windows at `0x1108000000` / `0x1110000000` |

**So there is no image ready for this board, and I should not pretend otherwise.** `solnix-k1-sd.img`
(65 MiB) exists locally, but it embeds `k1.dtb` describing a 4/8-core K1 with a 2 GiB flat memory map. On a
16-core heterogeneous K3 that DTB is wrong in the details that matter most for early boot: hart count, hart
ids, and the memory map.

## What the file *does* settle — three open questions closed for free

**1. No USB-C console.** `ls /dev/ttyUSB* /dev/ttyACM*` → nothing, and `lsusb` shows no USB-serial bridge
(the Realtek devices are Bluetooth, a hub, and an `RTL8153` gigabit NIC). **The USB-to-UART adapter is still
required.** That was the highest-value adapter-free check and the answer is no.

**2. The console is `serial0` at 115200.**
```
/proc/device-tree/chosen/stdout-path -> serial0:115200
```
Our `k1.dts` assumed `115200` and `serial@d4017000`. The baud is confirmed. ⚠️ **The address is not** —
`serial0` is an alias, and the file does not include the alias target. The one measurement still needed is:

```sh
ls -l /proc/device-tree/aliases/ && cat /proc/device-tree/aliases/serial0
cat /proc/device-tree/soc*/serial*/compatible
```

That resolves the "UNVERIFIED-until-hardware" risk in the console-bind fix.

**3. The board runs Linux 6.18.3 and has a working userland.** So it is healthy, and the vendor DTB is
readable — which is the fastest route to a correct `k3.dts`.

## The honest position on `dixr`

The plan called for `dixr` = solnix on RISC-V as a COSMIC daily driver. That is unchanged in ambition, but
this board is **further** from our port than assumed, not closer:

* A **heterogeneous** 16-core SoC is materially harder than a uniform 8-core one. The tenth kernel bug was
  an **OpenSBI boot-hart lottery** — hart identity handling is already the most fragile area, and two core
  types with different capabilities makes hart enumeration harder, not easier.
* PCIe root complexes mean real enumeration work, which on aarch64 cost weeks and produced the
  `_CRS`-in-SSDT finding.
* The good news: it boots Linux, so **every address we need is readable from the running system** rather
  than guessed. That is a far better position than the aarch64 bring-up started from.

## Next step, cheap and decisive

Rather than build a K3 payload from assumptions, **dump the vendor device tree**:

```sh
sudo dtc -I fs -O dts /proc/device-tree > /tmp/k3-vendor.dts
# or, if dtc is absent:
sudo tar czf /tmp/k3-dt.tar.gz /proc/device-tree
```

That single file gives the UART address and compatible, the hart ids and topology, the memory map, and the
PCIe windows — everything `k3.dts` needs, measured instead of assumed. It is the RISC-V equivalent of
reading the real ACPI tables off a Linux instance, which settled two aarch64 blockers for ~$0.07.
