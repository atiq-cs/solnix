# cli/go-tools.nix -- the Go CLI tier on the from-source go 1.26 (../go.nix goPkg).
{ goPkg, chk, go_1_27 }:
let
  gh = repo: tag: sha256: { url = "https://codeload.github.com/${repo}/tar.gz/refs/tags/${tag}"; inherit sha256; };
  fake = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
in {
  shfmt = goPkg { pname = "shfmt"; version = "3.14.1"; src = gh "mvdan/sh" "v3.14.1" "ec4bdb88ab6c95686be3a4eeb4ad77d2b49d33d2ed7b0a65035cd52d2d87c443"; vendorHash = "sha256-iIjBCAs0EZInsbLXUpKCIdDU0XVA0QNeowg+WBiC8nE=";
    subPkgs = "./cmd/shfmt"; ldflags = "-X main.version=v3.14.1"; check = chk ''echo "if true;then echo x;fi" | "$out/bin/shfmt"'' "^if true; then"; };  # --version is "(devel)" from a tarball
  yq = goPkg { pname = "yq"; version = "4.54.1"; src = gh "mikefarah/yq" "v4.54.1" "0cec36e7035dd56c508bda56245cbd71e4495d2317bc2528165c4162bce79335"; vendorHash = "sha256-k0tb6Gks+APMDWlEwxbJP+cpCKeFvBkt4bg00j86KRs=";
    subPkgs = "."; ldflags = ""; check = chk ''"$out/bin/yq" --version'' "version v4\\.54\\.1"; };
  miller = goPkg { pname = "miller"; version = "6.22.0"; src = gh "johnkerl/miller" "v6.22.0" "a3cec3b8bf74f1e6eddb708d6ae768e6ec70f10e345980de42cbc24df15f0c70"; vendorHash = "sha256-BdbDQcIkmX39zYnt39WG1ymmhrKLCqmPZP8m2oNUW9E=";
    subPkgs = "./cmd/mlr"; ldflags = ""; check = chk ''"$out/bin/mlr" --version'' "^mlr 6\\.22\\.0"; };
  fzf = goPkg { pname = "fzf"; version = "0.74.5"; src = gh "junegunn/fzf" "v0.74.5" "5529d08897b85ae773695787c811ff9c9eeee32419c8a297fa1dbe586ed0a27e"; vendorHash = "sha256-R6bFG24wMMz7k1DrmpvgeorDh7LuRaI4+mL4bEBLT/k=";
    subPkgs = "."; ldflags = "-X main.version=0.74.5"; check = chk ''"$out/bin/fzf" --version'' "^0\\.74\\.5"; };
  glow = goPkg { pname = "glow"; version = "3.0.0"; src = gh "charmbracelet/glow" "v3.0.0" "18df6f3c09157021366b8c702b5badba405d37dbb42f132353eb50c1b0d3f464"; vendorHash = "sha256-G9Honu72MzRF91pvR6fcu1mZD45ET+QUBOLL52yj3lE=";
    subPkgs = "."; ldflags = "-X main.Version=3.0.0"; check = chk ''"$out/bin/glow" --version'' "glow version"; };
  gh = goPkg { goPkgs = go_1_27; pname = "gh"; version = "2.103.3"; src = gh "cli/cli" "v2.103.3" "bb148138a3a2fe023e57c78042fe3b42fc09171c0e8fff4cf983b227b7a2eade"; vendorHash = "sha256-0muz07kDGgDeSbqnskmTBpNhSeRb6EW9zteahz6p9QY=";
    subPkgs = "./cmd/gh"; ldflags = "-X github.com/cli/cli/v2/internal/build.Version=2.103.3"; prep = ''
      # vendored terminal code calls syscall.SYS_IOCTL, which GOOS=illumos lacks (gh: survey,
      # vt10x, creack/pty; measured): route those through x/sys/unix (../../go-ioctl-fixup.py).
      python3 ${../go-ioctl-fixup.py} vendor/github.com/AlecAivazis/survey/v2/terminal/runereader_posix.go terminal \
        'const ioctlReadTermios = unix.TCGETS; const ioctlWriteTermios = unix.TCSETS'
      python3 ${../go-ioctl-fixup.py} vendor/github.com/hinshun/vt10x/ioctl_posix.go vt10x
    ''; check = chk ''"$out/bin/gh" --version'' "^gh version 2\\.103\\.3"; };
  lazygit = goPkg { pname = "lazygit"; version = "0.66.2"; src = gh "jesseduffield/lazygit" "v0.66.2" "fcaad0909af765ef87bd873164a4de78435515ab4d8b04f58d6ad51e8ecd00e5"; vendorHash = null;  # ships vendor/
    subPkgs = "."; ldflags = "-X main.version=0.66.2"; prep = ''
      python3 ${../go-ioctl-fixup.py} pkg/gocui/gui_others.go gocui
      # syscall.Getpgrp is not in GOOS=illumos' syscall; x/sys/unix has it (this file imports unix).
      f=pkg/gui/controllers/helpers/signal_handling.go
      grep -q 'syscall.Getpgrp()' $f || { echo "FATAL: lazygit Getpgrp anchor" >&2; exit 1; }
      sed -i 's/pgid := syscall.Getpgrp()/pgid, _ := unix.Getpgrp()/' $f
      # jibber_jabber (locale from $LANG/$LC_*) is env-only on unix; its tag omits illumos/solaris.
      f=vendor/github.com/cloudfoundry/jibber_jabber/jibber_jabber_unix.go
      grep -q '^// +build darwin freebsd linux netbsd openbsd$' $f || { echo "FATAL: jibber_jabber anchor" >&2; exit 1; }
      sed -i 's|^// +build darwin freebsd linux netbsd openbsd$|// +build darwin freebsd linux netbsd openbsd solaris illumos|' $f
    ''; check = chk ''"$out/bin/lazygit" --version'' "version=0\\.66\\.2"; };
  direnv = goPkg { pname = "direnv"; version = "2.38.2"; src = gh "direnv/direnv" "v2.38.2" "02c5e873e9ebcf2798513f7dd3775e5b8aace99bfa1e0c1b93091b6d4cbcaffb"; vendorHash = "sha256-ZvNWL9QRKIYZQXQ05tq6w4NEEdWsH2oTZw0Gj54SOu0=";
    subPkgs = "."; ldflags = ""; check = chk ''"$out/bin/direnv" version'' "^2\\.38\\.2$"; };
  micro = goPkg { pname = "micro"; version = "2.0.14"; src = gh "zyedidia/micro" "v2.0.14" "40177579beb3846461036387b649c629395584a4bbe970f61ba7591bd9c0185a"; vendorHash = "sha256-2QAf6XbG0Fwa20ROqLt5z6oRUdzs3o0hK+38JMH8j/Q=";
    subPkgs = "./cmd/micro"; ldflags = "-X github.com/zyedidia/micro/v2/internal/util.Version=2.0.14"; prep = ''
      # zyedidia/terminal's posix ioctl uses syscall.SYS_IOCTL, which illumos (libc syscalls) lacks;
      # on illumos do TIOCSWINSZ through golang.org/x/sys/unix (vendored, solarish via libc).
      f=vendor/github.com/zyedidia/terminal/ioctl_posix.go
      grep -q 'syscall.SYS_IOCTL' $f || { echo "FATAL: micro ioctl anchor" >&2; exit 1; }
      # rewrite it on golang.org/x/sys/unix (vendored; solarish ioctl via libc), same API.
      printf '%s\n' 'package terminal' 'import ("os"; "unsafe"; "golang.org/x/sys/unix")' \
        'func ioctl(f *os.File, cmd, p uintptr) error { return unix.IoctlSetWinsize(int(f.Fd()), unix.TIOCSWINSZ, (*unix.Winsize)(unsafe.Pointer(p))) }' \
        'func (t *VT) ptyResize() error { if t.pty == nil { return nil }; var w struct{ row, col, xpix, ypix uint16 }' \
        'w.row = uint16(t.dest.rows); w.col = uint16(t.dest.cols); w.xpix = 16 * uint16(t.dest.cols); w.ypix = 16 * uint16(t.dest.rows)' \
        'return ioctl(t.pty, 0, uintptr(unsafe.Pointer(&w))) }' > $f
    ''; check = chk ''"$out/bin/micro" -version'' "^Version: 2\\.0\\.14"; };
  # BSD-3-Clause. illumos has no tailscale TUN (net/tstun/tstun_stub.go panics), so tailscaled defaults to
  # --tun=userspace-networking (netstack); modules/config/tailscale.nix fixes that. Upstream CI cross-builds illumos/amd64.
  tailscale = goPkg { pname = "tailscale"; version = "1.98.10"; src = gh "tailscale/tailscale" "v1.98.10" "1a3aac335f0e1b2154fbf948ae8cd7f3464af7e28a5a0a12fd55ab475212a282"; vendorHash = "sha256-MQ+SaaLXTZ707d1md/thZwqujtQVan2lzgw338KRrf8=";
    subPkgs = "./cmd/tailscale ./cmd/tailscaled"; ldflags = "-X tailscale.com/version.longStamp=1.98.10 -X tailscale.com/version.shortStamp=1.98.10";
    check = chk ''"$out/bin/tailscale" version'' "^1\\.98\\.10"; };
}
