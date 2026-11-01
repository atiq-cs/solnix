# env.sh -- tryit1 EC2 build env: every tool from nixpkgs 08d3a975 (the rev with emscripten 5.0.6), out-links in ~/w/p.
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
N=github:NixOS/nixpkgs/08d3a97586f6b6343b3b5e799980773629432610
PKGS="gcc gnumake binutils file bzip2 ncurses emscripten qemu chromium nodejs diffutils which
  pkgsCross.riscv64-embedded.buildPackages.gcc14 pkgsCross.riscv64-embedded.buildPackages.binutils pkgsCross.riscv64.opensbi"
mkdir -p ~/w/p
P=
for a in $PKGS; do
	l=~/w/p/$(echo $a | tr . _)
	[ -e $l ] || nix build -o $l $N#$a
	P="$P:$l/bin"
done
export PATH=~/w/p/pkgsCross_riscv64-embedded_buildPackages_gcc14/bin:~/w/p/pkgsCross_riscv64-embedded_buildPackages_binutils/bin${P}:$PATH TMPDIR=/tmp
export TC=riscv64-none-elf SOLNIX_GCC=riscv64-none-elf-gcc SOLNIX_BUILD=x86_64-linux-gnu
export SOLNIX_SYSROOT=~/w/sysroot OUT=~/w/out
NL=$(riscv64-none-elf-gcc -print-file-name=libc.a); export NEWLIB=${NL%/riscv64-none-elf/lib/libc.a}
