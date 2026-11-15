# cli/go-nc1.nix -- Go tools the maintainer's nix-config uses that the x86 build queue has jobs for (lane nc1, 2026-11-15), as ./go-gl1.nix: nixpkgs f4a03c0
# attrs that miss only buildGoModule, on goPkg storeOnly. pname and version are the queue job's; ldflags and subPackages nixpkgs'.
# Sources pinned by sha256, vendor dirs by the NAR hash of our go mod vendor FOD (measured). Statically linked (CGO=0). `fix` routes
# vendored syscall.SYS_IOCTL calls (absent on GOOS=illumos) through golang.org/x/sys/unix, as gh/lazygit (../go-ioctl-fixup.py).
{ goPkg, go_1_27, chk, python3 }:   # python3: the store one, for go-ioctl-fixup.py (a solnix host has no python3 on PATH)
let
  gh = repo: ref: sha256: { url = "https://codeload.github.com/${repo}/tar.gz/${ref}"; inherit sha256; };
  gt = repo: ref: sha256: { url = "https://gitea.com/${repo}/archive/${ref}.tar.gz"; inherit sha256; };
  pkg = a: goPkg ({ storeOnly = true; } // a);
  fix = "${python3}/bin/python3 ${../go-ioctl-fixup.py}";
  termios = "'const ioctlReadTermios = unix.TCGETS; const ioctlWriteTermios = unix.TCSETS'";   # survey's terminal package needs these on illumos
in {
  # actionlint (MIT): static checker for GitHub Actions workflow files.
  actionlint = pkg { pname = "actionlint"; version = "1.7.12"; src = gh "rhysd/actionlint" "refs/tags/v1.7.12" "454800bd4f854592bcfe79b161f71d56e35940eb7016e48a26dd356adc9d400a";
    vendorHash = "sha256-O5YEmdTD5xhF+Y1jwYWVhlPo2EY0X36va1U/LDgMqJs="; subPkgs = "./cmd/actionlint"; ldflags = "-s -w -X github.com/rhysd/actionlint.version=1.7.12";
    check = chk ''"$out/bin/actionlint" --version'' "1\\.7\\.12"; };
  # aws-vault (MIT): vault for securely storing and accessing AWS credentials in development environments.
  aws-vault = pkg { pname = "aws-vault"; version = "7.16.2"; src = gh "ByteNess/aws-vault" "v7.16.2" "4d6b0f262294a6681c45dc743a628bc3854a5cc114160fcb19effccdf08eae99";
    vendorHash = "sha256-BheYq80bZQbKhbeS/JYCelocUMIuOdfH6yE5QJhmGYU="; subPkgs = "."; ldflags = "-X main.Version=v7.16.2";
    prep = ''
      for f in internal/tty/tty_unix.go vault/mfa_unix.go; do   # plain os/exec tty + MFA-command code; its tags omit illumos
        grep -qx '//go:build linux || darwin || freebsd || openbsd' $f || { echo "FATAL: tty tag anchor" >&2; exit 1; }
        sed -i -e 's#^//go:build linux || darwin || freebsd || openbsd$#& || illumos#' -e 's#^// +build linux darwin freebsd openbsd$#& illumos#' $f; done
      ${fix} vendor/github.com/AlecAivazis/survey/v2/terminal/runereader_posix.go terminal ${termios}
      export GOFLAGS="$GOFLAGS -tags=keyring_no1password"   # keyring's own opt-out (its freebsd build): the 1Password SDK has no CGO=0 illumos arm
      # --ec2-server's 169.254.169.254 alias has Linux (ip) and BSD (ifconfig) arms only: on illumos it reports unsupported
      [ ! -e server/ec2alias_illumos.go ] && [ -f server/ec2alias_linux.go ] || { echo "FATAL: ec2alias anchor" >&2; exit 1; }
      printf '%s\n' '//go:build illumos' 'package server' 'import "errors"' \
        'var errEc2AliasIllumos = errors.New("the EC2 metadata endpoint alias is not supported on illumos")' \
        'func installEc2EndpointNetworkAlias() ([]byte, error) { return nil, errEc2AliasIllumos }' \
        'func removeEc2EndpointNetworkAlias() ([]byte, error) { return nil, errEc2AliasIllumos }' > server/ec2alias_illumos.go
    '';
    check = chk ''"$out/bin/aws-vault" --version'' "7\\.16\\.2"; };
  # bazelisk (Apache-2.0): user-friendly launcher for Bazel.
  bazelisk = pkg { pname = "bazelisk"; version = "1.29.0"; src = gh "bazelbuild/bazelisk" "refs/tags/v1.29.0" "7e4c7b8ade016052e63c1553cb4fbe0c4fe921e1e66913d49eef074ed894e933";
    vendorHash = "sha256-vkbjvRacVD8VjSVGJr35Pme6fxpDS/hAjokz39V/vh8="; subPkgs = "."; ldflags = "-s -w -X github.com/bazelbuild/bazelisk/core.BazeliskVersion=v1.29.0";
    check = chk ''"$out/bin/bazelisk" --help'' "unsupported operating system .illumos."; };
  # curlie (MIT): frontend to curl that adds the ease of use of httpie, without compromising on features and performance.
  curlie = pkg { pname = "curlie"; version = "1.8.2"; src = gh "rs/curlie" "refs/tags/v1.8.2" "846ca3c5f2cca60c15eaef24949cf49607f09bdd68cbe9d81a2a026e434fa715";
    vendorHash = "sha256-Oa3fMOurGCqrD1qEpaqTfmAI+XkIJwTyzc1eX6aN6v4="; subPkgs = "."; ldflags = "-s -w -X main.version=1.8.2";
    check = chk ''"$out/bin/curlie" version'' "1\\.8\\.2"; };
  # docker-buildx (Apache-2.0): docker CLI plugin for extended build capabilities with BuildKit.
  docker-buildx = pkg { pname = "docker-buildx"; version = "0.38.1"; src = gh "docker/buildx" "refs/tags/v0.38.1" "bfd908c66d13c88cb6dccbc6d0fbb68aab17446901ba24203b5019ebf9d32f67";
    vendorHash = null; subPkgs = "./cmd/buildx"; ldflags = "-X github.com/docker/buildx/version.Version=v0.38.1";
    man = "mkdir -p $out/libexec/docker/cli-plugins; mv $out/bin/buildx $out/libexec/docker/cli-plugins/docker-buildx; ln -s ../libexec/docker/cli-plugins/docker-buildx $out/bin/docker-buildx";
    prep = ''
      d=vendor/github.com/moby/buildkit/util/disk   # illumos has statvfs, not statfs: GetDiskStat on unix.Statvfs (f_frsize units)
      grep -qx '//go:build !windows && !freebsd && !netbsd && !openbsd' $d/disk_unix.go || { echo "FATAL: buildkit disk tag anchor" >&2; exit 1; }
      sed -i 's#^//go:build !windows && !freebsd && !netbsd && !openbsd$#& \&\& !illumos#' $d/disk_unix.go
      printf '%s\n' '//go:build illumos' \
        'package disk' \
        'import (' \
        '	"github.com/pkg/errors"' \
        '	"golang.org/x/sys/unix"' \
        ')' \
        'func GetDiskStat(root string) (DiskStat, error) {' \
        '	var st unix.Statvfs_t' \
        '	if err := unix.Statvfs(root, &st); err != nil { return DiskStat{}, errors.Wrapf(err, "could not stat fs at %s", root) }' \
        '	return DiskStat{Total: int64(st.Frsize) * int64(st.Blocks), Free: int64(st.Frsize) * int64(st.Bfree), Available: int64(st.Frsize) * int64(st.Bavail)}, nil' \
        '}' > $d/disk_illumos.go
      c=vendor/github.com/tonistiigi/fsutil/copy/copy_otherbsd.go   # copyFile/mknod on io + unix.Mknod only: illumos takes the openbsd/netbsd arm
      grep -qx '//go:build openbsd || netbsd' $c || { echo "FATAL: fsutil copy tag anchor" >&2; exit 1; }
      sed -i 's#^//go:build openbsd || netbsd$#& || illumos#' $c
    '';
    check = chk ''"$out/libexec/docker/cli-plugins/docker-buildx" docker-cli-plugin-metadata'' "SchemaVersion" + chk ''"$out/bin/docker-buildx" version'' "0\\.38\\.1"; };
  # docker-compose (Apache-2.0): docker CLI plugin to define and run multi-container applications with Docker.
  docker-compose = pkg { pname = "docker-compose"; version = "5.6.0"; src = gh "docker/compose" "refs/tags/v5.6.0" "51ad60cc28d38a0850678053f0a259dfee931d150dd1d50ee9e6d758125b1d47";
    vendorHash = "sha256-iV2hcTqlEIF7735hQn5n1kveD9At0G6nobyg+GmdbO4="; subPkgs = "./cmd"; ldflags = "-X github.com/docker/compose/v5/internal.Version=5.6.0 -s";
    man = "mkdir -p $out/libexec/docker/cli-plugins; mv $out/bin/cmd $out/libexec/docker/cli-plugins/docker-compose; ln -s ../libexec/docker/cli-plugins/docker-compose $out/bin/docker-compose";
    prep = ''
      for f in internal/locker/runtime_unix.go pkg/remote/cache_unix.go; do   # XDG-path code whose tags omit illumos
        grep -qx '//go:build linux || openbsd || freebsd' $f || { echo "FATAL: compose tag anchor" >&2; exit 1; }
        sed -i 's#^//go:build linux || openbsd || freebsd$#& || illumos#' $f; done
      k=vendor/github.com/eiannone/keyboard   # illumos termios ioctls are TCGETS/TCSETS, as on Linux: use the linux file
      grep -qx '//go:build !windows && !linux' $k/syscalls.go || { echo "FATAL: keyboard tag anchor" >&2; exit 1; }
      sed -i -e 's#^//go:build !windows && !linux$#& \&\& !illumos#' -e 's#^// +build !windows,!linux$#&,!illumos#' $k/syscalls.go
      cp $k/syscalls_linux.go $k/syscalls_illumos.go
      # illumos has no O_ASYNC (SIGIO on tty input): keyboard reads the tty non-blocking and a once-started 20 ms poller
      # feeds its sigio channel, so the read-until-EAGAIN loop runs as on Linux. F_SETOWN (only for SIGIO) becomes F_GETFL.
      g=$k/keyboard.go
      grep -qF 'unix.FcntlInt(uintptr(in), unix.F_SETFL, unix.O_ASYNC|unix.O_NONBLOCK)' $g && grep -qF 'unix.FcntlInt(uintptr(in), unix.F_SETOWN, unix.Getpid())' $g \
        && grep -qx '	signal.Notify(sigio, unix.SIGIO)' $g || { echo "FATAL: keyboard async anchor" >&2; exit 1; }
      sed -i -e 's/unix.O_ASYNC|unix.O_NONBLOCK/unix.O_NONBLOCK/' -e 's/unix.F_SETOWN, unix.Getpid()/unix.F_GETFL, 0/' \
        -e 's/^	signal.Notify(sigio, unix.SIGIO)$/&\n	illumosSigioPoll(sigio)/' $g
      printf '%s\n' '//go:build illumos' \
        'package keyboard' \
        'import (' \
        '	"os"' \
        '	"sync"' \
        '	"time"' \
        '	"golang.org/x/sys/unix"' \
        ')' \
        'var illumosPollOnce sync.Once' \
        'func illumosSigioPoll(ch chan os.Signal) {' \
        '	illumosPollOnce.Do(func() { go func() { for { select { case ch <- unix.SIGIO: default: }; time.Sleep(20 * time.Millisecond) } }() })' \
        '}' > $k/keyboard_poll_illumos.go
    '';
    check = chk ''"$out/libexec/docker/cli-plugins/docker-compose" docker-cli-plugin-metadata'' "SchemaVersion" + chk ''"$out/bin/docker-compose" --version'' "5\\.6\\.0"; };
  # gh-markdown-preview (MIT): gh extension to preview Markdown looking like on GitHub.
  gh-markdown-preview = pkg { pname = "gh-markdown-preview"; version = "1.12.1"; src = gh "yusukebe/gh-markdown-preview" "v1.12.1" "3292a52a1b24e469f3439f78087b43b97baf2d071da9ce6852dacea9f6f2bce9";
    vendorHash = "sha256-Pgq+aoYmDW/uspVzDyOqa0uPJFQQotif1k96GI8zwD8="; subPkgs = "."; ldflags = "-s -w -X github.com/yusukebe/gh-markdown-preview/cmd.Version=1.12.1";
    check = chk ''"$out/bin/gh-markdown-preview" --version'' "1\\.12\\.1"; };
  # go-task (MIT): task runner / simpler Make alternative written in Go.
  go-task = pkg { pname = "go-task"; version = "3.53.1"; src = gh "go-task/task" "refs/tags/v3.53.1" "dd22395f4548ba58bc3adf83cb9ce33f1c5fad7e7c5f0a229bb2709af439fa9a";
    vendorHash = "sha256-w6b4HIs2luAvsmwPRfLsEEJbfiDlv3VD8oVDfq/gBZ8="; subPkgs = "./cmd/task"; ldflags = "-s -w -X=github.com/go-task/task/v3/internal/version.version=3.53.1";
    prep = ''
      u=vendor/github.com/u-root/u-root/pkg/ls   # illumos Stat_t has Linux's Atim/Ctim, not the BSDs' Atimespec
      grep -qx '//go:build !plan9 && !windows && !tamago && !linux && !openbsd' $u/fileinfo_unix.go || { echo "FATAL: u-root ls tag anchor" >&2; exit 1; }
      sed -i 's#^//go:build !plan9 && !windows && !tamago && !linux && !openbsd$#& \&\& !illumos#' $u/fileinfo_unix.go
      cp $u/fileinfo_linux.go $u/fileinfo_illumos.go
    '';
    check = chk ''"$out/bin/task" --version'' "3\\.53\\.1"; };
  # lazydocker (MIT): simple terminal UI for both docker and docker-compose.
  lazydocker = pkg { pname = "lazydocker"; version = "0.25.2"; src = gh "jesseduffield/lazydocker" "v0.25.2" "405071220e5be9aa061c65d290e0347143b73ae0a3cc01df164f0105de2b53c4";
    vendorHash = null; subPkgs = "."; ldflags = "-s -w -X main.version=0.25.2";
    prep = ''
      d=vendor/github.com   # xdg and jibber_jabber: env-var-only code whose tags omit illumos; gocui as gl3's awesome-gocui
      grep -qx '// +build freebsd openbsd netbsd' $d/OpenPeeDeeP/xdg/xdg_bsd.go || { echo "FATAL: xdg tag anchor" >&2; exit 1; }
      grep -qx '// +build darwin freebsd linux netbsd openbsd' $d/cloudfoundry/jibber_jabber/jibber_jabber_unix.go || { echo "FATAL: jibber_jabber tag anchor" >&2; exit 1; }
      sed -i 's#^// +build freebsd openbsd netbsd$#& illumos#' $d/OpenPeeDeeP/xdg/xdg_bsd.go
      sed -i 's#^// +build darwin freebsd linux netbsd openbsd$#& illumos#' $d/cloudfoundry/jibber_jabber/jibber_jabber_unix.go
      ${fix} $d/jesseduffield/gocui/gui_others.go gocui
    '';
    check = chk ''"$out/bin/lazydocker" --version'' "0\\.25\\.2"; };
  # tea (MIT): gitea official CLI client.
  tea = pkg { pname = "tea"; version = "0.16.0"; src = gt "gitea/tea" "refs/tags/v0.16.0" "3c8523e551f576290c69fe6375208e0cb27d4fc1e48b29b13e02ca6ada851c05";
    vendorHash = "sha256-lPE8cE4OfOjNMHQYcjdxlJSjHf+gvAZU5EfEGIQHsRk="; subPkgs = "."; ldflags = "-s -w -X gitea.dev/tea/modules/version.Version=0.16.0 -X gitea.dev/tea/modules/version.Tags=nixpkgs -X gitea.dev/tea/modules/version.SDK=1.2.0";
    check = chk ''"$out/bin/tea" --version'' "0\\.16\\.0"; };
  # yq-go (MIT): portable command-line YAML processor.
  yq-go = pkg { pname = "yq-go"; version = "4.54.1"; src = gh "mikefarah/yq" "refs/tags/v4.54.1" "0cec36e7035dd56c508bda56245cbd71e4495d2317bc2528165c4162bce79335";
    vendorHash = "sha256-k0tb6Gks+APMDWlEwxbJP+cpCKeFvBkt4bg00j86KRs="; subPkgs = ".";
    check = chk ''"$out/bin/yq" --version'' "4\\.54\\.1"; };
}
