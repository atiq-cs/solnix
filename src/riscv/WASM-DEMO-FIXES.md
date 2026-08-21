# WASM demo fixes: the noisy ld.so.1 output + the broken /etc

Two user-reported bugs in the "try solnix in your browser" WASM demo (TinyEMU running the riscv64 solnix
disk image).

## BUG 2 (FIXED in source): ld.so.1 too verbose
The runtime linker printed its full trace banner on every exec ("[ld.so.1] riscv64 runtime linker",
"DT_NEEDED", "LAZY PLT armed", "symbol lookup", "RELRO: mprotect", "app + libs relocated; entering the app",
plus per-symbol "bound X -> Y"). This spammed the demo shell.
FIX (src/riscv/rp31/ldso/rtld_riscv.c): added a `ld_debug` flag initialized once from `getenv("LD_DEBUG")`
in rtld_main (scanning envp before the auxv walk), plus gated `iputs_`/`iputhex_` info-print helpers. All
INFO-level banners now use iputs_/iputhex_ (silent unless LD_DEBUG is set, the glibc convention); all FATAL
diagnostics still use puts_ (always printed). Default is silent -- `ls` now prints only its output.

## BUG 1 (ROOT-CAUSED; fix designed, needs a rebuild): /etc is not a real directory
Symptom: `ls /` shows "bin etc lib sbin usr" but `cd /etc` -> "no such directory".
ROOT CAUSE: the on-disk blockfs (snfs, src/riscv/uts/blkfs.c) is FLAT -- it has NO subdirectory support. Its
`snfs_dirent` is only {d_name, d_len, d_dblk} (no type field, no directory inodes), with 8 fixed file slots
in a single directory sector (SNFS_DIR_SEC). The RAM rootfs (src/riscv/uts/rootfs.c) IS VDIR-aware
({VDIR,"etc",...}), but R-P55's vfs_rootfs_pivot pivots / onto the FLAT snfs disk. On that disk "etc" is a
flat name (via vfs_blockfs_mkdir), not a traversable VDIR, and nothing is ever written into it (the populate
copy-list cp[] only writes /bin/* and /sbin/*). So `ls` sees the flat name but `cd`'s lookup+VDIR-check
fails.
FIX (design): add real subdirectory support to snfs -- a type field on snfs_dirent (VREG vs VDIR), directory
inodes (a dir is a dirent whose d_dblk points at a sub-directory sector of dirents), nested path lookup in
snfs_lookup, and vfs_blockfs_mkdir allocating a real dir sector with . and .. Then the populate must create
/etc as a real VDIR and write /etc/release into it (the content already exists -- R-P40 had `cat
/etc/release` working from the RAM fs). Verify: after the fix, `cd /etc` works, `ls /etc` shows release,
`cat /etc/release` prints. This requires rebuilding the riscv kernel + libc + the disk image + repackaging
the WASM demo disk (the split blk*.bin), which needs the riscv cross-toolchain (was on the build node).
