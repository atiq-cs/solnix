# aarch64 A6-mem: the `bmemlist_alloc Out of memory` root cause + fix

## Where the boot dies (real Graviton, c6g.metal, get-console-output)
The aarch64 kernel proper runs on real silicon and dies right after the version banner:

```
[A6KCON:BOP]
[A6KCON:BCONS]
[AK:FR=00000000]              # Graviton console UART FR-poll quirk (bounded, continues)
[A6KCON:PUT hang txfe]
module .../unix:   text at [0xfffffffffe02a000, 0xfffffffffe156fff] data at 0xfffffffffe157000
module .../genunix: text at [0xfffffffffe621a20, 0xfffffffffe8f08e7] data at 0xfffffffffe8f0900
module .../platmod: text at [0xfffffffffe95da48, 0xfffffffffe95dd47] data at 0xfffffffffe95dd48
illumos Version arm64-gate-0-gae3cab2471 64-bit
DEBUG enabled
bmemlist_alloc Out of memory       <-- dies here
Press any key to reboot.
```
Modules load at valid high addresses -> boot memory exists -> the failure is in the
kernel's FIRST memory-list construction, not in a bad map.

## Root cause (from source analysis of fakebop.c)
`bmemlist_init()` (uts/armv8/os/fakebop.c ~1819) primes a STATIC free-list arena then
dups three bootloader-provided memory lists into kernel form:

```c
static memlist_t boot_list[MMU_PAGESIZE * 8 / sizeof (memlist_t)];   // ~819 nodes
...
for (i = 0; i < ...; i++) bmemlist_free(&boot_list[i]);   // prime the arena
phys_avail   = bmemlist_dup((memlist_t *)xbp->bi_phys_avail);       // 1 node / segment
phys_install = bmemlist_dup((memlist_t *)xbp->bi_phys_installed);   // 1 node / segment
boot_scratch = bmemlist_dup((memlist_t *)xbp->bi_boot_scratch);     // 1 node / segment
```

Each `bmemlist_dup`/`bmemlist_insert` consumes ONE arena node per memory segment.
The arena is `MMU_PAGESIZE * 8` = 32 KiB / sizeof(memlist_t) ~= **819 nodes** -- sized for
QEMU-virt, whose RAM map is a handful of segments. On a real Graviton (c6g.metal), the
UEFI/ACPI memory map is large and FRAGMENTED (many usable/reserved/MMIO segments), so the
three dups together exceed 819 nodes; the arena runs dry mid-dup and the next
`bmemlist_alloc()` returns OOM. QEMU never hit this because its map is tiny.

## The fix (correct by inspection)
Grow the boot-memlist arena from QEMU-sizing to a Graviton-generous size:

```c
-static memlist_t boot_list[MMU_PAGESIZE * 8 / sizeof (memlist_t)];    // ~819 nodes
+static memlist_t boot_list[MMU_PAGESIZE * 128 / sizeof (memlist_t)];  // ~13k nodes, ~512 KiB
```

512 KiB of static boot memory is trivial (freed after boot memlist construction) and
covers any realistic fragmented server memory map. Captured in
`src/aarch64-arm64-gate-patches/a6-mem-arena-grow-and-diag.patch` (grow + the [A6MEM]
diagnostic that dumps arena_total/inuse/hwm + the raw phys_avail/phys_install/boot_scratch
segment counts, to CONFIRM the fix + show Graviton's real fragmentation on the next boot).

## Status: fix written, rebuild BLOCKED on a cross-assembler wiring gap
The fix + the [A6MEM] diagnostic are applied to fakebop.c on the build node and captured
as a durable patch. Rebuilding the aarch64 `unix` to test it on metal is currently blocked:
`bldenv <env/aarch64>` builds, but the `.S` kernel sources assemble with the HOST (x86)
assembler instead of the cross `aarch64-unknown-solaris2.11-as` (`no such instruction:
'stxrb w4,w2,[x0]'` -- a valid AArch64 instruction rejected by x86 gas). The cross gcc/ld/
objcopy ARE present (`/aarch64/arm64-gate/build/cross/bin/`), but the assembler isn't wired
for `.S` compilation in a from-scratch rebuild on this node -- the same reproducibility gap
as R-P63: the exact build wiring that produced `gae3cab2471` lived on prior nodes.

## Verification path (when the cross-as wiring is restored)
The transfer + boot mechanics are now PROVEN and hang-proof (used successfully this session):
1. Rebuild `unix` (armv8) with the grown arena via bldenv once `.S` files use the cross-as.
2. Rebuild the image (build_qemu.sh -- DROP pv), lofi-verify it's bootable.
3. Linux-helper transfer (build-node `gzip -c disk.img | ssh helper 'gunzip | dd of=/dev/nvmeXn1'`
   ~80 MB/s vs illumos raw-dd ~1 MB/s), snapshot, register arm64 UEFI AMI.
4. Boot ONE c6g.metal, read `get-console-output --latest` (a plain API call, CANNOT hang):
   the [A6MEM] init line prints the real segment counts; boot should proceed PAST bmemlist
   -> SunOS banner -> device probe -> root-mount -> multi-user on real silicon.

## Anti-wedge note
Three agents wedged on this leg on un-timeout'd serial/SSH. The reliable pattern (this
session) for a hang-prone illumos node: `timeout -s KILL <n> setsid ssh ...` with ONE short
non-interactive command, background long ops on-node with `nohup ... > logfile`, and POLL
the logfile with separate short reads. NEVER an interactive disk-probe (`format`, chained
`prtvtoc`/`diskinfo` loops) over SSH -- those block and wedge. get-console-output for all
metal console reads.
