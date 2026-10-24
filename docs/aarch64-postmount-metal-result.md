# aarch64 Graviton after root mount: the kernel reaches login, then an unhandled EL0 SError panics it

Date: 2026-10-23/24. Account: kiwi (437803535746), us-west-2. Track: aa64e. Follows
`docs/aarch64-nvme-intr-metal-result.md` ("silent after root mount, then the periodic reset").

## Headline

1. **The brief's premise was wrong. The kernel does not hang after root mount.** With the console written
   directly, every stage from `vfs_mountroot` to `sched()` prints in 6/6 boot cycles over 2 boots:
   strplumb, consconfig, release_bootstrap, forceattach, `start_other_cpus` (all 63 secondaries
   start, rc 0, `cpus 64`), init, pageout, fsflush. SMF then runs, and 2 of the 6 cycles reach
   `solnix-aa64 console login:`.
2. **The console goes silent because output is dropped, as the aa64d source trace predicted. This is now
   seen in the console log.** From `consconfig()` on, every prom/`cmn_err` console character goes into
   `sysp_putchar`'s drop branch (echoed `|D| `, 13070 chars per cycle). Every userland/SMF console
   write is freed by `wcuwsrv` because there is no tem (echoed `|W| `). The old-path control marker
   `[AA64E-P] S6` and everything after it shows up only as `|D| [AA64E-P] S6`.
3. **There is no SBSA watchdog.** The GTDT is rev 2 with **0 platform timers** (no GT block and no
   watchdog entry). The plan to refresh a watchdog has nothing to act on.
4. **The "periodic reset" seen in every earlier metal boot has two sources, and neither printed anything
   until now:**
   * (a) the `svc:/system/filesystem/usr` boot-archive self-reboot
     (`WARNING: Reboot required ... boot archive`), once per fresh image (2/6 cycles);
   * (b) a kernel panic `unexpected exception type` (3/6 cycles).
5. **The panic, decoded in boot 2:** an **asynchronous SError taken from EL0**, vector 11
   (`from_lower_el_aarch64_error`), which this kernel routes to `UNEXPECTED()`.
   `esr 0xbe000411` (EC 0x2F SError, ISS DFSC 0x11 = asynchronous SError, AET 0 = uncontainable),
   `spsr 0x40000000` (EL0t, DAIF clear), `elr 0x7fffef1801c4` (the same user PC in both decoded
   panics), process **dhcpagent** in 2/2 decoded panics, on cpu20 / cpu31 (cpu21 in boot 1, not decoded).
6. **Why it lands at EL0 (source, consistent with every observation):** the boot CPU clears all of DAIF
   (`startup.c` `enable_irq()`, DAIF_SETCLEAR_ALL). Secondary CPUs clear only I
   (`mp_startup.c:587 clear_daif(DAIF_SETCLEAR_IRQ)`), so `PSTATE.A` stays set while they run the
   kernel. An SError raised on a secondary therefore stays pending until the first `eret` to user
   mode, where it arrives on the unhandled lower-EL vector. **The origin of the SError (which device
   access) is NOT identified.** It is asynchronous and imprecise.
7. **sshd was not reached.** In boot 1, sshd could not have started:
   * `aa64-overlay.sh` uses `cp -P`, which illumos `/usr/bin/cp` rejects (usage error).
   * So **none** of the 106 braich libraries were copied, `libxml2.so.16` and `libcrypto.so.3` among them.
   * So every `svccfg apply` failed, the profiles were never applied, `network/ssh` stayed disabled,
     and sshd lacked libcrypto.
   * Boot 2 fixes the copy (GNU cp), and the `svccfg apply ... failed` warnings disappear. But the
     SError panic kills the steady-state cycle about 4 s after login (the diag got as far as `ldd`).

| claim | status |
|---|---|
| Kernel hangs after root mount | **REFUTED**: S1..S14 reached 6/6 cycles; login 2/6 |
| Console text is dropped after consconfig (sysp_putchar, wcuwsrv) | **OBSERVED** (`\|D\|`/`\|W\|` echoes; control marker dropped from S6) |
| SBSA watchdog causes the ~13 min reset | **REFUTED** (GTDT: 0 platform timers) |
| Reset source (a): boot-archive self-reboot | **OBSERVED** 2/6 cycles (1 per fresh image, both boots) |
| Reset source (b): `unexpected exception type` panic | **OBSERVED** 3/6 cycles (boot 1 c1; boot 2 c1, c3) |
| Panic = async SError taken from EL0 on vector 11 | **OBSERVED** 2/2 decoded (`esr 0xbe000411`, `spsr 0x40000000`) |
| Victim process dhcpagent | **OBSERVED** 2/2 decoded |
| PSTATE.A stays masked on secondaries, so the SError is deferred to EL0 | **SOURCE** (mp_startup.c:587 vs startup.c enable_irq); fits cpu20/21/31 and never cpu0. Not measured (DAIF of a secondary in the kernel was not read) |
| What raises the SError | **UNKNOWN** |
| `svccfg apply` fails because libxml2.so.16 is missing | **OBSERVED** in the build log (illumos `cp -P` usage error, 106 libs) + boot 2 A/B: the warnings vanish once the libs are present |
| ena0 stays INITIALIZED (not STARTED) in boot 1 | **OBSERVED** (state 0x1, link 0). Nothing plumbed it: `network/physical` runs before ena0 finishes attaching, and nothing re-plumbs. sshd needed more than this anyway (above) |
| ena0's ~9 GB allocation | **OBSERVED**: 32 rxqs x 16384 descs x 12288 B (MTU 9216, sgl 1) = 6 GiB streaming DMA. `ddi_dma_mem_alloc` -> `i_ddi_mem_alloc` -> `kalloca`; 12 KiB > PAGESIZE, so `vmem_alloc(kmem_io[].kmem_io_arena)`, not a kmem cache. One 12 KiB alloc + DMA handle per descriptor, 524288 of them. The attach takes ~100 s. Pre-MP attach (boot 2 c1): 1 rxq x 2048 = 24 MiB |
| sshd reached | **NO** (0/2 boots) |

## Boot 1: observers only

`aa64e-observers.py` (output only) on top of the reproduced aa64c boot-2 base (unix `06282bbc`):

* `machdep.c`:
  * `aa64e_putc`/`printf` write the SPCR UART (PA `0x83e00000` from `bop_init`) through a `psm_map_phys`
    KVA device mapping made at S1, before `release_bootstrap()`;
  * `sysp_putchar`'s drop branch echoes `|D| `; S1 prints the GTDT entries;
  * a 15 s `realtime_timeout` heartbeat prints: stage, cpus, nproc, freemem, drop counters, polled-io
    state, ena0 attach step / state / link, init's state, the newest 4 `pid:comm`;
  * the watchdog control frame would be mapped `PROT_READ` (a read-only PTE) and read under `on_trap`.
    It never was, because there is no watchdog.
* `fakebop.c`: keeps the UART PA. `mp_startup.c`: `>N <N:rc` per secondary CPU.
* `main.c`: S1..S14 marks, each followed by an old-path `[AA64E-P] Sn` `prom_printf` control.
* `wscons.c`: `wcuwsrv`'s `ptem == NULL` drop echoes `|W| `.
* `ena.c`: per-step attach print and the state pointer. The references are **weak**, because ena links with
  `-z defs` against the DDI mapfiles and krtld binds weak undefined symbols from unix.
* `ena_dma.c`: the three log-only DMA failures go to the console.
* `dboot_synth_fdt.c`: copies the raw GTDT into `solnix,acpi-gtdt` on the root node.

Shas:

* unix `965330bf`, genunix `7509512b`, wc `9e32d09d`, ena `944c2caf`;
* nvme `883c8941`, gicv3_its `2e3e8b13`, ecam `c3b33e42`, pcierc `50095ddb` (unchanged);
* tables `b2530338`/`f4313e7a`;
* the boot_archive was checked 8/8 against the build outputs.

Image raw `291961e4` (EBS dd readback equal), AMI `ami-0a2a1e69328fe721a`.

c6g.metal `i-0f2680bb9438f3600`, launched 03:08:51Z. 12 reads, 03:13Z-03:47:57Z (39 min), then terminated.
3 cycles:

* **c1** (md5 `c8316bc8`):
  * S1..S14;
  * HB#0: `cpu 64/64 np 7 ... pio 10 ... ena0 seq 11 st 1 link 0`;
  * SMF up to the pseudo-device attaches;
  * then `|D| panic[cpu21]/thread=ffff80338805ebc0: unexpected exception type`.
* **c2** (md5 `f2d065ab`):
  * S1..S14; ena0 attaches after MP (33 MSI-X vectors, Rx-queue step ~100 s);
  * `milestone/network`, `Hostname: solnix-aa64`;
  * then `WARNING: Reboot required` (boot archive), `syncing file systems... done`; newest process `reboot`.
* **c3** (md5 `11d8bb89` -> `cd06eebe`):
  * S1..S14, SMF;
  * `|W| solnix-aa64 console login:` at 03:40:15Z;
  * rpc/bind, shares/group, sendmail-client, fmd -> maintenance;
  * stable for 8 min (HB#37), ena0 `st 1 link 0`, no sshd, port 22 closed.

Every cycle prints `WARNING: svccfg apply /etc/svc/profile/{generic.xml,platform.xml,site} failed`.

GTDT at S1: `rev 2 len 96 ntimers 0 off 0 gsiv s-el1 0 ns-el1 30 virt 27 ns-el2 26 cntfrq 121875000`.

## Why svccfg failed and sshd could not run (build host, before boot 2)

Assembly log, `aa64-overlay.sh` library loop:

```
+ cp -P /build/braich-root/lib/libxml2.so.16 /braich_image/lib/libxml2.so.16
Usage: cp [-afinpT@/] source_file target_file
```

illumos `cp` accepts `-P` only together with `-R`. The loop's `cp -P` failed for every library, 106
times, and the script carried on. `svccfg` NEEDs `libxml2.so.16` and sshd NEEDs `libcrypto.so.3`
(elfdump), which come only from the braich overlay (the gate proto has no
libxml2; same finding on QEMU in `docs/design-aarch64-bootstrap.md:838-850`). The aa64c-era host
presumably had GNU cp first in PATH. This host's ssh PATH is `/usr/sbin:/sbin:/usr/bin`.

## Boot 2: answer the questions, plus the library fix

* **Kernel (`aa64e-b2.py`, output only, on top of boot 1):**
  * `UNEXPECTED()` becomes `UNEXPECTED_N(vector index)`, which calls `aa64e_unexpected()` before
    `panic`. That prints vector, ESR (EC/ISS), ELR, FAR, SPSR, SP, DAIF, ISR_EL1, thread and comm,
    plus the CPU's last 4 `trap()` entries (`trap()` records esr/far/pc in a per-CPU ring);
  * ena prints its Rx sizing before allocating.
  * unix `fce84838`, ena `1428b1fe`; everything else equals boot 1. boot_archive 8/8.
* **Image:**
  * the overlay uses `/usr/gnu/bin/cp -P`;
  * a new gate fails the assembly if any NEEDED library of svccfg / svc.startd / svc.configd / sshd /
    sshd-session / curl / ssh-keygen is missing (it honours RUNPATH: the first run false-flagged
    `libfmevent` under `/lib/fm`);
  * `manifest-import`'s `svccfg apply` stderr goes to `/dev/msglog`;
  * `network/ssh` is enabled in the site profile;
  * the generic and site profiles are applied into the seeded repository at build time
    (`SEED_APPLY_RC=0` x2; `network/ssh` and `site/aa64e-diag` both `general/enabled true`);
  * `site/aa64e-diag` prints, at start, +150 s and +450 s: ldd, `svccfg apply` with stderr, `svcs -xv`,
    `dladm`, `ipadm`, the ena kstats and the key log. At +450 s, if ena0 has no address, it plumbs
    DHCP: **STUB, not a fix**.
* Image raw `4b79cd10` (EBS readback equal), AMI `ami-0780f2ec50876bcab`.

c6g.metal `i-01a20bf9f76479791`, launched 04:46:28Z. 9 reads, 04:50Z-05:22:13Z (36 min), then terminated.
3 cycles:

* **c1** (md5 `3d150e4c`):
  * ena0 attached before root mount (1 rxq x 2048 descs = 24 MiB);
  * SMF up to `Hostname: solnix-aa64`, then:

    ```
    [AA64E-UNEXP] cpu20 vec 11 low64-serror esr 0xbe000411 (ec 0x2f iss 0x411) elr 0x7fffef1801c4 far 0x7fffef14d7e8 spsr 0x40000000 sp 0xffff80013baa8000 daif 0x3c0 isr 0x0 thread ffff8033881e6ba0 comm dhcpagent
    [AA64E-UNEXP] cpu20 trap-1 esr 0x8200000b far 0x7fffef14d7e8 pc 0x7fffef14d7e8
    [AA64E-UNEXP] cpu20 trap-2 esr 0x82000007 far 0x7fffef14d7e8 pc 0x7fffef14d7e8
    ...
    |D| panic[cpu20]/thread=ffff8033881e6ba0: unexpected exception type
    ```

* **c2** (md5 `d486bee7`): `WARNING: Reboot required` (boot archive), as in boot 1 c2.
* **c3** (md5 `dbd0dfaa`):
  * ena0 attaches after MP (32 rxqs x 16384 descs x 12288 B = 6 GiB, ~100 s);
  * **no `svccfg apply ... failed`**, `Hostname`, `site/aa64-ec2-key` runs;
  * `|W| solnix-aa64 console login:`; the diag's round 1 starts at 05:16:12 (ldd: no missing
    libraries), then:

    ```
    [AA64E-UNEXP] cpu31 vec 11 low64-serror esr 0xbe000411 (ec 0x2f iss 0x411) elr 0x7fffef1801c4 far 0x7fffef0bddf0 spsr 0x40000000 ... comm dhcpagent
    [AA64E-UNEXP] cpu31 trap-1 esr 0x9200000b far 0x7fffef0bddf0 pc 0x7fffef718520
    |D| panic[cpu31]/thread=ffff80338127c060: unexpected exception type
    ```

### Reading the SError

* ESR `0xbe000411`: EC 0x2F (SError), IL 1, ISS `0x411`: IDS 0, AET 0b000 (uncontainable), EA 0,
  DFSC 0b010001 (asynchronous SError interrupt).
* SPSR `0x40000000`: taken from EL0t with D/A/I/F clear, the Z flag set.
* The previous `trap()` entries on that CPU are EL0 instruction/data aborts (EC 0x20/0x24, L3 access
  flag / translation): ordinary demand paging of dhcpagent. They were taken and returned normally.
* Same ELR in both decoded panics. That points at the user instruction the CPU was returning to, not at
  the faulting access.

Why only secondaries and only from EL0: `mp_startup.c:587` clears only `PSTATE.I`. `PSTATE.A` stays
set from `locore`'s `eret` (`PSR_D|PSR_A|PSR_I|PSR_F`), so the SError waits until the `eret` to user
(SPSR A=0). The boot CPU's `enable_irq()` clears all four bits. Not measured: reading DAIF on a
secondary would confirm it.

## Next steps (not done here)

1. **Find the SError's origin.** Unmask SError on secondaries (`clear_daif(DAIF_SETCLEAR_SERROR)` next
   to the IRQ clear at `mp_startup.c:587`), so the SError arrives at EL1 on the existing
   `from_current_el_error_handler` close to the access that raised it. The trap ring already in
   boot 2 then names the kernel PC. Likely suspects are dhcpagent's DLPI/ioctl path into ena (the doorbell
   or unmask registers under `ena_hw_abs_write32`) and the ena LLQ BAR. **Untested.**
2. **Handle the lower-EL SError vector** (`from_lower_el_aarch64_error`): save the frame and call
   `trap()` (T_SERROR at user = SIGBUS today), instead of `UNEXPECTED()`. That would turn a kernel panic into a
   killed process. **It hides the cause**, so do it after (1).
3. **Real console fix** (deferred on purpose): after `consconfig`, the console has no output path.
   `wc`'s `cons_polledio_putchar` is NULL in CONS_FW mode, and `wcuwsrv` frees text when there is
   no tem (aarch64 lacks `_HAVE_TEM_FIRMWARE`). The fix is either a polled putchar for the boot UART
   (an `asy`/pl011 console tty bound to `serial@83e00000` whose handover does not kill output, see
   the 10-22 A/B), or giving `wc` a polled putchar backed by the boot UART when there is no tem. The
   aa64e observers are the workaround and must not ship.
4. **Boot archive:** build it with `bootadm update-archive -R` instead of `create_ramdisk` alone, so
   `boot-archive` finds it current and does not self-reboot the first boot.
5. **ena:** the MTU 9216 x 16384-descriptor x 32-queue Rx allocation (6 GiB, ~100 s) is the device
   maximum. Cap `rx_queue_num_descs` in `ena.conf`.
6. Fix `aa64-overlay.sh` in the repo (`/usr/gnu/bin/cp -P`) and keep the NEEDED-library gate.

## Artifacts

floki `~/solnix-bank/ami/aarch64-6cd2521c1e-postmount-20261023/`:

* both images (`aa64e-obs1-20261023.img.gz` gz `72ebb259`, raw `291961e4`; `aa64e-b2-20261023.img.gz`
  gz `d482112a`, raw `4b79cd10`);
* 21 consoles, the patchers, scripts and diffs;
* `SHA256SUMS` and `RAW.sha256`.

The reproduced cross build host is banked at `~/solnix-bank/toolchain/arm64-buildhost-aa64e-20261023/`
(`bpool-aarch64-aa64e.zfs.gz` `60871ba7`, `bpool-build-aa64e.zfs.gz` `6fbe571d`). The floki
sha256 matches the host's.

Repo (uncommitted): `src/aarch64-arm64-gate-patches/postmount-20261023/`.

Instances:

* build host `i-0ad7a0e08690f5111`;
* metal `i-0f2680bb9438f3600` and `i-01a20bf9f76479791`;
* image volumes `vol-0ad1ca72fa0697012` and `vol-08351c377834abf18`;
* AMIs `ami-0a2a1e69328fe721a` and `ami-0780f2ec50876bcab` with snapshots `snap-0e8703a01ca4db66d` and
  `snap-0623a64027d21bd10`, deregistered and deleted at the end (see the cleanup record).
