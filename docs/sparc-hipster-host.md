# SPARCv9 build host: `sun` (OI Hipster SPARC reference)

## Host facts (investigated 2026-07-29)
- SSH: `gburd@sun` (BatchMode key auth works). **Much slower than EC2/QEMU** (2× UltraSPARC-IIIi @ 1600 MHz, 16 GB RAM) — use for validation + gap-fill, not bulk.
- OS: **OpenIndiana Hipster 2026.04**, illumos-31d3d510d0, sun4u SPARC (SUNW,A70), 64-bit sparcv9.
- Native toolchain: **gcc 13.4.0** targeting `sparcv9-sun-solaris2.11`; `/usr/bin/{gmake,make}`; `/opt/onbld` (bin/closed/env) + `/usr/src` gate checkout present → can run illumos `nightly` if ever needed.
- Disk: `/export` 852 GB free, `~gburd` 790 GB free. Plenty for builds.
- illumos ld: 5.11-1.1790 (matches our sparcv9 world-slice ABI).

## Day-1 parity target
- **OI SPARC publisher: `https://pkg.openindiana.aurora-opencloud.org/oi-sparc/`** (the LIVE OI Hipster SPARC IPS depot — aurora-opencloud mirror; the pkg.openindiana.org/sparc path is dead).
- **OI SPARC publishes 9,673 packages** (`pkg list -a`) = the SPARC day-1 parity target (comparable scale to x86_64's ~10k universe). solnix SPARC currently: 6 (kernel-qualified) → toolchain now unblocked.

## Toolchain unblock (SOLVED — no nightly needed)
The `sun` host already has, installed by OI, everything the cross-toolchain agent said was blocking:
- crt/values: `/usr/lib/sparcv9/{crt1,crti,crtn,values-Xc,values-xpg6,values-Xa,values-Xs,values-Xt,values-xpg4}.o`
- full header tree: `/usr/include` (6,785 headers, 236 MB) — vs the 321-header runtime ramdisk
- libgcc + gcc-crt: `/usr/gcc/13/lib/gcc/sparcv9-sun-solaris2.11/13.4.0/{libgcc.a,crtbegin.o,...}`
- link libs: `/usr/lib/sparcv9/{libc,libm,libsocket,libnsl}.so`
Harvested → `artifacts/sparc-toolchain/sparc-sysroot-hipster.tar.zst` (28 MB, Hipster-exact).

## Build strategy (two lanes)
1. **Native on `sun`** (slow, faithful): real OI Hipster gcc-13.4.0. Best for validation + packages the cross can't handle. `SYSTEM=sparcv9-solaris` publish.
2. **Cross on x86 fleet** (fast, volume): build a `sparcv9-sun-solaris2.11` cross-gcc against the harvested Hipster sysroot (like aarch64's arm64-gate cross) → bulk userland front. This is the volume path to close the 9,673 gap.

## Next
- Wire the Hipster sysroot into a cross-gcc → launch the SPARC userland cross-build front on the x86 fleet (analog of aa-xbuild).
- Use `sun` for a native smoke-build (prove a real package compiles+links native) + day-1 validation.
