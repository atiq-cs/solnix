# solnix x86_64 installer crash on Intel Alder Lake (X1 Extreme Gen5) — investigation handback

**Image under test:** `/home/gburd/solnix-trueimg-final/solnix-x86_64-usb.img`
sha256 `ed166d6f…`, md5 `4a737fb35a2c9c9e34b75073afa62050` (verified byte-identical on the EC2 repro host).
**Repo HEAD during this work:** `4bde00e` (no commits made — orchestrator commits).
**Gate rev the image kernel was built from:** `ac45d71fc2b04a5422e72a14b54dd1e746e7be07` (illumos-gate, 2026-07-23).
**Substrate:** EC2 `c6i.metal` (kiwi, us-east-2), Debian 12, KVM nested virt + QEMU 7.2.22 and 10.0.2 + OVMF 4M. **TERMINATED** (see cleanup).

---

## TL;DR

* **The hybrid-topology hypothesis is REFUTED** — both at the source level and empirically. The illumos kernel in this image does not fault on Alder Lake P/E hybrid topology. It never *looks at* the hybrid info.
* The crash is **not** reproducible under QEMU/KVM — and, importantly, it is **not reproducible even in principle** there, because the remaining suspect (the **Iris Xe GOP framebuffer handoff**) is exactly the thing QEMU's VGA/virtio-gpu does not replicate. That is also why qemu-TCG "boot-verified" never caught it.
* The evidence points to the **GOP/EFI-framebuffer console handoff** (`console=text` / `os_console=text` → the kernel's `boot_fb.c` / `consconfig` GOP console), specific to Iris Xe's newer GOP vs the Gen1 UHD630 that worked. The source path is identified below.
* **Confirming it needs the real X1 + a serial capture.** A ready-to-run **maintainer X1 test kit** (console-variant boots + decision tree) is below — it turns "we think it's GOP" into a cheap, falsifiable test on silicon and localises the fix.

---

## 1. Hybrid hypothesis — REFUTED (how, with evidence)

### 1a. Source-level proof (airtight)

`git grep` across the pinned gate's x86 kernel (`usr/src/uts/intel/*`, `usr/src/uts/i86pc/*`) for every hybrid signal:

```
0x1A | leaf_1a | CPUID_LEAF_1A | hybrid | HYBRID | core_type | P_CORE | E_CORE | atom-core
```

→ **ZERO Intel-hybrid handling.** (The only `0x1A` hits are a Nehalem model-id `#define`, PCI-BIOS `int 0x1A`, and unrelated register offsets; the only `hybrid` hits are the AMD DDR4/LPDDR5 memory-controller tables in `zen_umc.c`.)

The kernel **never reads CPUID leaf 0x1A or the hybrid feature bit (CPUID.07H:EDX[15])**, so it cannot "fault on" information it never reads. It treats every logical CPU as a uniform core. The places that *could* trip on non-uniformity are all guarded or degrade gracefully:

| Path | File | Behaviour on hybrid/asymmetric input |
|---|---|---|
| core count | `cpuid.c:cpuid_intel_ncores` | `ncores = BITX(leaf4.eax,31,26) + 1` — never 0, no divide-by-zero |
| per-CPU IDs | `cpuid.c:cpuid_leafB_getids` | leaf-0xB x2apic shift math, per-CPU; bounds OK |
| MADT parse | `mp_platform_common.c` | `LOCAL_APIC` + `LOCAL_X2APIC` both bounds-checked (`< NCPU`, `< boot_ncpus`); `Id==255` sentinel → warning, not crash |
| CMT scheduler | `disp/cmt.c:pg_cmt_lineage_validate` | a non-concentric / unrecoverable lineage (what hybrid produces) → `pg_cmt_disable()` which **logs a NOTE and sets a flag — it never panics** |

### 1b. Empirical proof (clean boots across every crafted hybrid-ish topology)

All booted the **actual** image to the login prompt under KVM, serial-captured (via `-vga none`, see §4). None panicked, reset, or disabled CMT:

| Test | QEMU `-cpu`/`-smp` | What it exercises (that qemu-TCG never did) | Result |
|---|---|---|---|
| t4 | `host` / `2` | x2APIC first-ever exposure (TCG dropped x2apic/pcid/tsc-deadline) | **CLEAN → login** |
| t5 | `host` / `20,cores=10,threads=2` | 20-CPU x2APIC `mp_startup` | **CLEAN → login** |
| t6 | `host` / `20,dies=2,cores=5,threads=2` | asymmetric cache domains (leaf 0x1F/4 split) | **CLEAN → login** |
| t7 | `host` / `20,sockets=2,cores=5,threads=2` + 2-node NUMA, uneven 14/6 cpu split | asymmetric lgroups (the CMT `PG_SPANS_LGRPS` stressor) | **CLEAN → login** |
| q10 | same under QEMU **10.0.2** | newer QEMU CPUID model | **CLEAN → login** |

In-guest confirmation (t7-shaped probe): `psrinfo` enumerated **all 20 vCPUs** correctly (2 physical × 5 cores × 2 threads); CMT was **not** disabled.

### 1c. Honest limitation of the repro

Neither QEMU 7.2 nor 10.0.2 has a toggleable `hybrid` CPU feature or an `Alderlake` model that sets CPUID leaf 0x1A, and the host (Ice Lake Xeon 8375C) has no hybrid bit to pass through. **So I could not present a byte-perfect Alder Lake CPUID.** This does not weaken the conclusion: since illumos ignores leaf 0x1A entirely (§1a), a perfect hybrid CPUID would change *nothing* in its boot path, and every *downstream* observable of a hybrid part (mixed APIC IDs, mixed cache leaves, asymmetric lgroups) **was** presented and handled cleanly (§1b).

**Conclusion:** the X1 Gen5 installer crash is **not** the illumos hybrid-topology path.

---

## 2. The remaining suspect: Iris Xe GOP framebuffer handoff (hypothesis + source path)

### Why GOP, not hybrid

* The crash happened with the **real framebuffer console** (`console=text` / `os_console=text`, which the image ships — `make-iso-usb.sh`, `make-installer-image.sh`). On the X1 that drives the **GOP** framebuffer.
* qemu-TCG/OVMF "boot-verified" the image only against QEMU's std-VGA/virtio framebuffer — **not** an Iris Xe GOP. That is precisely why QEMU never hit it, and why it is not reproducible on QEMU.
* The earlier **X1 Carbon Gen1 (UHD630)** booted this console path fine (the loader-knob history in `make-iso-usb.sh` is all Gen1 evidence). **Gen5 is a different GOP** (newer Iris Xe GOP: different framebuffer stride/pixel-format/base, 4K panel). The console *drawing* code is fine on a normal framebuffer (I captured a full boot rendered on a standard VGA framebuffer — `shot-fb-std.png`), so the problem is in the **GOP handoff values / fb-device binding**, not the glyph-drawing logic.

### The exact source path (so a fix has a target before the serial capture lands)

GOP flows **loader → kernel** in three stages:

1. **EFI loader grabs GOP** and fills the multiboot2 framebuffer tag:
   `usr/src/boot/efi/libefi/efi_console.c` (`efi_find_framebuffer`, `efi_framebuffer_setup`) → `usr/src/boot/common/gfx_fb.c` (`gfx_fb` tag) → `usr/src/boot/common/multiboot2.c:753,1155` copies `gfx_fb` into the boot info the kernel reads.
   *The loader got far enough to show its menu on the X1, so basic GOP query worked — but the menu uses the loader's own text renderer; the tag it hands the kernel is what matters next.*

2. **Early kernel framebuffer console** consumes the tag:
   `usr/src/uts/i86pc/boot/boot_fb.c:167-213` reads `paddr / pitch / bpp / width / height` and the RGB field masks from the tag, then `boot_fb.c:423` uses `fb_info.paddr` **directly** as the framebuffer pointer (identity-mapped early). An Iris Xe 4K fb is large (3840×2160×4 ≈ 33 MB) at a high physical address; a wrong pitch/stride or a non-32bpp/odd-mask handoff is drawn here. This path *validates* the tag type (EGA_TEXT/INDEXED/RGB) and returns `B_FALSE` for unknown — so a malformed-type tag degrades rather than faults, but a *well-formed-but-wrong* tag (wrong pitch/base) writes to the wrong memory.

3. **Full console bind at `consconfig`** (the most likely fault point for a *mid-boot* stop):
   `usr/src/uts/i86pc/io/consplat.c:plat_fbpath()` (lines 377-406) walks the device tree (`find_fb_dev`) for the framebuffer device. For a PCI/pciex `device_type == "display"` node it **requires `PCI_COMM_IO` (I/O-space enable)** to select it (consplat.c:352-356). **Modern Iris Xe is frequently MMIO-only with no legacy VGA I/O space** → `plat_fbpath()` may not select it (both rounds), which *should* fall back to `CONS_TTY` (consplat.c:148-149) rather than crash — but if it *does* select it, the kernel console framebuffer driver `usr/src/uts/i86pc/io/gfx_private/gfxp_fb.c` / `gfxp_vgatext.c` then maps and drives the Iris Xe fb, and that attach/map on a newer GOP device is a plausible fault site.

**Where to look first when the serial capture arrives:** the last line before the stop localises it to one of the three stages. The strongest single candidate is stage 2/3 — the kernel-side GOP console (`boot_fb.c` paddr/pitch assumptions, or `consplat.c`/`gfxp_fb.c` fb-device binding) on the Iris Xe GOP.

---

## 3. Maintainer X1 Gen5 test kit (cheap, falsifiable, no rebuild needed)

The whole point: **capture serial** so that if the GOP console dies, the kernel's last words still reach a serial line. The image already supports every knob below; the first three need **no rebuild** (loader prompt only).

### Prerequisite: a serial line to capture on
The X1 has no built-in RS-232. Use a **USB-serial adapter** (illumos has `usbftdi`/`usbsksp`; a cheap FTDI works) on the X1, **or** capture over the loader/kernel `ttya` only if the firmware exposes a serial port — if not, these tests still change *behaviour* observably on-screen (boots further vs same stop), which is itself the signal. 115200 8N1. On another laptop: `picocom -b 115200 /dev/ttyUSB0` (or `screen /dev/ttyUSB0 115200`).

### Test A — serial-capture the existing boot (confirms *where* it dies)
At the solnix loader menu, press a key to pause, then option **3** (Escape to loader prompt). At the `OK` prompt:
```
set console=text,ttya
set os_console=text,ttya
boot
```
* **Expected if GOP:** the framebuffer may go black/freeze, **but the serial line keeps printing** — you get the panic text / last kernel line. **Capture that line — it is the single most useful artifact.**
* This does not change the console *path* (still text-fb-first); it only adds a serial *mirror*.

### Test B — bypass the kernel GOP console entirely (the decisive one)
At the `OK` loader prompt:
```
set console=ttya
set os_console=ttya
boot
```
* `os_console=ttya` makes the **kernel** put its console on serial, so the kernel never binds the Iris Xe GOP framebuffer console (`boot_fb.c` / `consplat.c` / `gfxp_fb.c`).
* **Boots further / reaches login on serial ⇒ the GOP console handoff IS the culprit** (hypothesis §2 confirmed; fix is in stage 2/3).
* **Still dies at the same point ⇒ it is deeper** (loader-side GOP query in stage 1, ACPI, or a non-console driver) — then the serial capture from Test A names the next thing.
* Keyboard note: with `console=ttya` the *keyboard* input moves to serial (per the `make-iso-usb.sh` comment on how `console=` drives both stdin+stdout). That's fine for a diagnostic boot; you drive it from the serial console.

### Test C — keep the panel but kill the text-fb takeover
At the `OK` loader prompt, try serial-primary with the framebuffer only as a *secondary* output:
```
set console=ttya,text
set os_console=ttya
boot
```
* Isolates "loader GOP query / mode-set" (still happens) from "kernel text-fb console bind" (now on serial). If this boots but Test's plain `text` doesn't, the kernel-side bind is the fault.

### Test D — only if A–C are inconclusive: a serial-default image
If the loader-prompt route is impractical, rebuild the image with the serial default the build system already supports:
```
SOLNIX_CONSOLE="text,ttya"   # scripts/make-iso-usb.sh honours this (loader.conf console/os_console)
```
or `ttya` alone for Test-B semantics. No code change — it's an existing env knob.

### Decision tree
```
Boot with serial captured (Test A)
├─ serial prints a PANIC/last-line → send it; localise to stage 1/2/3 in §2
└─ serial also goes dark at the same instant → firmware/loader-side (stage 1) or hard hang

Test B (os_console=ttya):
├─ reaches login / boots past the old stop → GOP KERNEL CONSOLE is the culprit
│     fix target: boot_fb.c paddr/pitch assumptions OR consplat.c find_fb_dev PCI_COMM_IO
│     gate OR gfxp_fb.c/gfxp_vgatext.c Iris-Xe fb attach
└─ same stop → NOT the kernel GOP console; look at loader gfx_fb.c / ACPI (newer tables)
```

---

## 4. Repro-harness notes (for anyone re-running under KVM)

* **You must use `-vga none`** so OVMF routes the illumos "text" (framebuffer) console to the **serial** line; otherwise QEMU's std-VGA framebuffer eats it and `-nographic` shows nothing past the loader's console list. (The old clean TCG runs used `-cdrom` which incidentally had the same effect.)
* Boot the image as a **USB stick** (`-device qemu-xhci -device usb-storage,drive=…,removable=on`), `readonly=on` on the image drive (never mutate the shipped image; also avoids the qemu write-lock).
* KVM needs the host user in group `kvm` *or* run qemu under `sudo` (group change needs a fresh login).
* QEMU 10.0.2 is in Debian 12 `bookworm-backports` if a newer CPUID model is wanted — but it still has no hybrid/Alderlake toggle, so it does not help present a true hybrid part.

---

## 5. EC2 cleanup

| Resource | Id | State |
|---|---|---|
| instance (c6i.metal, Project=solnix, Name=hybrid-20261012) | `i-0875b40d8c9fa8fe4` | **terminated** |
| key pair | `hybrid-key-20261012` | **deleted** |
| security group (ingress 22 ← 73.4.58.0/24 only, never 0.0.0.0/0) | `sg-0d47189b44194816d` | delete pending ENI release — **retry `aws ec2 delete-security-group --region us-east-2 --group-id sg-0d47189b44194816d` once the instance is fully `terminated`** |

Root EBS was DeleteOnTermination. No snapshots/AMIs/extra volumes created.

---

## 6. Deliverables on disk (floki)

* `/home/gburd/streamHYBRID-out/HANDBACK-REPORT.md` — this file.
* `/home/gburd/streamHYBRID-out/shot-fb-std.png` — the image booting cleanly on a standard VGA framebuffer under KVM (proves the console *drawing* path works; the X1 issue is the Iris-Xe GOP *handoff*, not glyph drawing).
* `/tmp/streamHYBRID-progress.txt` — running checkpoint (full paths, EC2 ids, every test result).
