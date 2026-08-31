# aarch64 image rebuild recipe (pack the fixed unix -> bootable metal AMI)

The A6-mem arena fix is compiled into a fresh `unix` (aarch64 ELF, 1.82MB). This is
the reproducible path to get that unix into a bootable image and onto real Graviton.
The source rebuild is solved (docs/aarch64-a6-mem-arena-diagnosis.md); this is the
image-assembly layer.

## The pipeline (arm64-gate/tools/, captured in image-tools/)
```
proto/root_aarch64/  --(nightly pkgsend publish)-->  packages/aarch64/nightly/repo.redist
     |                                                        |
 fresh unix here                                     build_image.sh: pkg image-create +
 (staged: 03:52)                                     pkg install entire + on-nightly/*
                                                              |
                                                      bpool/braich_image dataset
                                                              |
                                                      zfs send > out/illumos.zfs
                                                              |
                                                      build_qemu.sh: lofi disk.img +
                                                      zfs receive < out/illumos.zfs +
                                                      installboot loader64.efi -> illumos-disk.img
                                                              |
                                                      Linux-helper transfer (~80MB/s) ->
                                                      snapshot -> register arm64 UEFI AMI ->
                                                      c6g.metal -> get-console-output
```

## Steps
1. **Stage the fixed unix** (done): `cp usr/src/uts/armv8/unix/debug64/unix
   proto/root_aarch64/platform/armv8/kernel/aarch64/unix`.
2. **Republish into the nightly repo**: the on-nightly kernel package must carry the new
   unix. On a node with a POPULATED nightly repo, `pkgsend publish` (or re-run the kernel
   leg of `nightly`) the system/kernel package. NOTE: a freshly-provisioned build node has
   an EMPTY `packages/aarch64/nightly/repo.redist/publisher/` -- the packaged outputs lived
   on prior nodes. A full `nightly` build (hours) or a preserved repo snapshot repopulates
   it. This is the LAST reproducibility layer for aarch64 (analogous to the RISC-V
   toolchain gap): capture a nightly-repo snapshot to skip the rebuild.
3. **build_image.sh** (`illumos-gate/`): `pkg image-create` + install `entire` +
   `on-nightly/*` into `bpool/braich_image` -> `zfs send > out/illumos.zfs`. Uses the
   node's own bpool (works even when the DISK-IMAGE pool import wedges).
4. **build_qemu.sh**: lofi `illumos-disk.img`, `zfs receive < out/illumos.zfs`, install
   loader64.efi. ⚠️ If this variant pipes `pv | zfs receive` under `set -e` and pv is
   absent -> silent unbootable image; DROP pv. (The captured copy is pv-free.)
5. **Transfer + boot** (PROVEN this session, hang-proof):
   - Fresh 10G volume -> Linux arm64 helper (t4g.medium); stage the SSH key.
   - `ssh build-node 'gzip -c illumos-disk.img' | ssh helper 'gunzip | dd of=/dev/nvme1n1'`
     (~80 MB/s; illumos raw-dd is ~1 MB/s and the disk-probe path WEDGES).
   - `create-snapshot` -> `register-image --architecture arm64 --boot-mode uefi`.
   - Launch ONE c6g.metal; read `get-console-output --latest` (a plain API call, CANNOT
     hang). Expect: boot proceeds PAST `bmemlist_alloc` (the arena is now
     `MMU_PAGESIZE*128` = ~13k nodes vs the old ~819) -> the SunOS banner -> device probe
     -> root-mount -> multi-user on real Graviton. Terminate the metal promptly.

## Node-ops discipline (why 3 agents wedged here and the direct drive did not)
- `timeout -s KILL <n> setsid ssh ...` with ONE short non-interactive command.
- Background long ops on-node (`nohup ... > logfile 2>&1 &`), POLL the logfile with
  separate short reads. NEVER an interactive/looped disk probe (`format`, chained
  `prtvtoc`/`diskinfo`, `zpool import`) over SSH -- those block and wedge the caller.
- `get-console-output` for ALL metal console reads (never the serial-console SSH, which
  hangs without a timeout).
- Identify disks by EBS volume serial (`iostat -En`), never by c-node ordering (it lies).
