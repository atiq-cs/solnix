# aarch64 campaign A4: the arm64-gate illumos KERNEL BUILDS (gate PASSED)

## Result: the aarch64 illumos kernel is BUILT + verified (EM_AARCH64), on our infrastructure.
The missing artifact the readiness assessment identified (the cross toolchain built, but `make illumos`
never completed) is now produced. Ground-truth-verified on the build node (solnix x86 host):

- unix   (kernel executable): /aarch64/arm64-gate/illumos-gate/usr/src/uts/armv8/unix/debug64/unix
    file: ELF 64-bit LSB executable, AArch64, EXEC, dynamically linked
    readelf: Machine AArch64, Class ELF64
- genunix (kernel module):    .../usr/src/uts/aarch64/genunix/debug64/genunix  -> AArch64 REL
- mdb unix/genunix kmods also AArch64.
- proto/ tree present (built userland/kernel).
- u-boot.bin present (build/u-boot-rpi4/) -- the RPi4 bootloader the port targets.

Build platform: an x86_64 solnix (illumos) host -- arm64-gate cross-builds FROM an amd64-illumos host
(the correct method). The arm64-gate checkout is at /aarch64/arm64-gate/illumos-gate; the build env was
bootstrapped (the Python-3.13 sgs requirement + the arm64-gate nightly env that broke the prior attempt
were satisfied here). Full nightly (packaging phase) was still completing at gate-verification; the KERNEL
+ proto (what A5 needs) are done.

## Gate: PASSED -- an aarch64 illumos kernel binary exists + nm/readelf-verifies as EM_AARCH64.

## Next: A5 -- boot solnix-aarch64 in QEMU-virt
Assemble the boot artifacts (u-boot + an illumos-disk.img/boot_archive with this kernel + the A3
cross-built userland) and boot under qemu-system-aarch64 -M virt,gic-version=2 -cpu cortex-a72. The port's
real target is QEMU-virt (GICv2/devicetree) -- NOTE the built u-boot is the RPi4 variant; A5 may need the
qemu-virt u-boot (or direct -kernel) instead. First BOOTABLE aarch64 solnix is the A5 gate.

## Recipe capture (for reproducibility -- the aarch64 analog of oi-gate-build.sh)
The build node holds the full recipe; capture oi-gate-build-aarch64.sh from it before terminating (the
arm64-gate clone + the build-env bootstrap + the nightly invocation). The proto + kernel must survive for A5
(keep the node or snapshot the /aarch64 tree to a volume).
