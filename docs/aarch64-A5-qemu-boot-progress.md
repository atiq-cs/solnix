# aarch64 campaign A5 (QEMU boot): progress + the exact current blocker

## Where A5 stands (driven directly after the A5 agent truncated at 2 tool-uses)
Prereqs all MET on the build node (/aarch64/arm64-gate):
- A4 kernel present + verified (unix = AArch64 EXEC, genunix AArch64 kmod).
- proto/root_aarch64 built (platform/QEMU,virt present -- the qemu-virt platform is built).
- The nightly redist repo IS published: publisher on-nightly, 495 packages, online.
- qemu-system-aarch64 installed. The port ships qemu-setup/run.sh (-machine virt, cortex-a53, TCG) +
  run-gicv3.sh + testsuite.exp.
- Makefile DELIBERATELY breaks GNU make ("prevents GNU make from parsing") -> use /usr/bin/make (illumos),
  NOT gmake. `make qemu-disk` re-runs the full illumos build (dep chain) -> run tools/build_image.sh DIRECTLY
  instead (bypasses the rebuild). It uses `sudo` -> provide a passthrough shim as root.
  ⚠️ CAUTION: `make qemu-disk` started a `dmake clobber` (full rebuild) -- was stopped in time; the A4
  kernel + proto + the 495-pkg repo survived. Do NOT invoke the make disk TARGET; call build_image.sh.

## THE CURRENT BLOCKER (build_image.sh, the disk-image step)
build_image.sh builds a ZFS image via `pkg image-create` from the nightly redist repo + the OmniOS `braich`
(aarch64) publishers (pkg.omnios.org/bloody/braich). It FAILS (set -e abort) at `pkg install`: the live
OmniOS bloody/braich repo has DRIFTED from the arm64-gate's expected snapshot -- e.g. editor/vim,
developer/dtc require SUNWcs@0.5.11-151059 / ksh93 / bash@5.3.3 / ncurses@6.6 / system/library versions that
the available set can't satisfy ("No version matching 'require' dependency ..."). A version-skew between the
port's nightly + the current OmniOS braich.

## The fix (next -- A5 completion)
Options: (a) PIN the OmniOS publisher to a braich snapshot compatible with the arm64-gate's nightly (the
port likely documents a known-good OmniOS commit/date; check README/env), OR (b) drop the failing OPTIONAL
packages (vim, dtc are extras -- the entire + on-nightly core is what boots) from build_image.sh's pkglist /
add --reject for them, OR (c) fetch the matching OmniOS braich archives into archives/omnios (build_image.sh
references a local file:///archives/omnios). Then build_image.sh completes -> a bootable disk.img ->
qemu-setup/run.sh -> capture the boot console (the A5 gate: kernel banner -> init -> shell).

## Status: A5 IN PROGRESS. Prereqs done; blocked on the OmniOS braich pkg version-skew in build_image.sh.
## Not fatal to the campaign -- a packaging pin/reject, then the qemu boot.
