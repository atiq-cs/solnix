# solnix aarch64 on Nitro VMs (aa64vm, 2026-10-30): image v4

m4 (aa64rb) booted only on c6gd.metal. On a Nitro VM (m6gd/m7gd/c6g), the loader printed "Booting..." and nothing else.
v4 = m4 + p10 (ena admin poll, unchanged) + three fixes. It boots on a **c6g.large** (2 vCPU, 4 GB) in about 3 minutes.

| patch | what | evidence |
|---|---|---|
| p11 dboot -mstrict-align | dboot read `rsdp->XsdtPhysicalAddress` with an unaligned 8-byte `ldr` while the MMU was off (Device memory): ESR 0x96000021 alignment fault at get_acpi_xsdt+0x18. The VM's RSDP is at an address where that field is unaligned; metal's isn't. | disassembly matched the fault PC exactly (aa64vm progress 15:30Z) |
| p12 16550 console | Graviton's SPCR says 16550 (byte registers), but dboot forced PL011 for OEM AMAZON. On a VM every PL011 FR read traps (about 3 us) and reads 0xffffffff, so each character waited out the 10000-poll cap, about 30 ms. | measured on c6g.large |
| p13 ITS BASER page size | the VM's ITS accepts only 64K BASER pages and reads back 64K when you write 4K, so gicv3_its failed and PCI fell back to INTx and hit a VERIFY. Retry with the page size the ITS reports, as Linux does. | console "hardware rejected page size" |

Verified 2026-10-30, kiwi us-west-2, c6g.large i-074745305179354ca:
- launch boot: `console login:` about 3 min after launch, ssh as root, ena0 up (MTU 9216), aa64-archive-sync online, `svcs -x`
  showing only the 3 services the site profile disables;
- one EC2 API reboot: back with ssh and ena0, and no DL_BADPPA, panic or default-instance lines;
- `nix --version` as an unprivileged user: 2.24.15 (the image has the full 310-line /etc/minor_perm).
Not re-verified on metal with v4. m4 is the metal reference, and p11-p13 only touch paths metal didn't fail on.

Images (raw sha256 3f579dd48542ef9be68706bf9edfa80365fe466cae23cbba66181b62f823bf3c, banked
~/solnix-bank/aa64vm-20261030/v4.img.gz, read back): solnix-ami us-west-2 **ami-0e08aa06f629ffbac**, us-east-1
**ami-0ecdc3a731f13adff**. Both are shared with the work account 399683337502. m4 is tagged superseded.
Build: bh-vm-k.sh (the kernel build on an OI build host) with `FIX=p10p11p12p13.py`, then the m4 image recipe
(docs/aarch64-image-rebuild-recipe.md, archive-sync-20261029/rb-img.sh).
