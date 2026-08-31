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

## Status: fix written AND the aarch64 unix REBUILDS from scratch (reproducibility gap SOLVED)
The fix + the [A6MEM] diagnostic are applied to fakebop.c and the aarch64 `unix` now
rebuilds cleanly from a fresh checkout (aarch64 ELF, BLDRC=0, 1.8MB, carrying the
`boot_list[MMU_PAGESIZE*128]` arena fix). The rebuild had been blocked on the build wiring
(the gap that lived on prior nodes); three fixes make it deterministic:

1. **`bldenv -T aarch64`** -- the TARGET-MACH flag. `bldenv` sets `MACH=${flags.T}` and
   `NATIVE_MACH=$(uname -p)`; without `-T aarch64`, MACH defaults to the native i386 and the
   env file's `if [[ ${MACH} == "aarch64" ]]` cross branch never fires -> the whole build
   goes `-m32 -Di386` with the host x86 gcc/as (THAT was the `stxrb no such instruction` --
   x86 gas fed AArch64 asm, not a missing cross-as). With `-T aarch64` the build correctly
   uses `--primary gcc14,.../aarch64-unknown-solaris2.11-gcc` + sysroot + `-Daarch64`.
2. **Regenerate the empty `assym.h`** -- `unix/debug64/assym.h` was a stale 0-byte file, so
   `dboot_srt0.S` (which `#include`s `assym.h`) couldn't resolve `HCR_TGE`/`ICC_SRE_EL2_EN`/
   `CPACR_FPEN_MASK` (register-bit immediates emitted from `genassym.cf`). `dmake
   debug64/assym.h` regenerates it (6362 bytes, all constants present).
3. **gcc-14 `-Werror` suppressions** -- 30 benign sites (`unused-variable`,
   `unused-but-set-variable`, `empty-body`) in common vm/disp/cmt/kobj code that a newer gcc
   flags. `Makefile.uts` already has `-Wno-unused`/`-Wno-empty-body` but gated behind
   `$(RELEASE_BUILD)`; added them to `CERRWARN` unconditionally so the DEBUG cross-build gets
   them too. Plus 2 source fixes: `HATSTAT_INC(x) (0)` -> `((void)0)`; `hment.c` `hm2`
   -> `hm2 __unused` (used only by a DEBUG `ASSERT`). All captured in
   `src/aarch64-arm64-gate-patches/a6-mem-plus-gcc14-build-fixes.patch`.

**Remaining (last reproducibility item):** the IMAGE-assembly recipe (pack the new `unix`
into the boot_archive inside `illumos-disk.img`) still lived on a prior node -- a
`build_qemu.sh`-class script. To metal-test the arena fix, rebuild the boot image with the
fresh unix (swap unix + rebuild boot_archive in the ZFS image), then use the proven transfer
+ get-console path below. A reproducible `build-image.sh` is the aarch64 analog of the
RISC-V `build-all.sh` follow-up.

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
