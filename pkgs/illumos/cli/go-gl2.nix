# cli/go-gl2.nix -- more Go leaves the x86 build queue has jobs for (lane gl2, 2026-11-14), as ./go-gl1.nix: nixpkgs f4a03c0 by-name
# attrs that miss only buildGoModule, on goPkg storeOnly. pname and version are the queue job's; ldflags and subPackages nixpkgs'.
# Sources pinned by sha256, vendor dirs by the NAR hash of our go mod vendor FOD (measured). Statically linked (CGO=0). `fix` routes
# vendored syscall.SYS_IOCTL calls (absent on GOOS=illumos) through golang.org/x/sys/unix, as gh/lazygit (../go-ioctl-fixup.py).
{ goPkg, go_1_27, chk, python3 }:   # python3: the store one, for go-ioctl-fixup.py (a solnix host has no python3 on PATH)
let
  gh = repo: ref: sha256: { url = "https://codeload.github.com/${repo}/tar.gz/${ref}"; inherit sha256; };
  pkg = a: goPkg ({ storeOnly = true; } // a);
  fix = "${python3}/bin/python3 ${../go-ioctl-fixup.py}";
  termios = "'const ioctlReadTermios = unix.TCGETS; const ioctlWriteTermios = unix.TCSETS'";   # survey's terminal package needs these on illumos
in {
  # commitizen-go (MIT): command line utility to standardize git commit messages, golang version.
  commitizen-go = pkg { pname = "commitizen-go"; version = "1.0.3"; src = gh "lintingzhen/commitizen-go" "v1.0.3" "31dbcce99c7d73bfdb2d91571e640d05d98d66e10e9cc5e594decd9fd9d0d077";
    vendorHash = "sha256-uzLWaYbbx8ZB0ARF33BNGmGT8lv/bimHCt/WFE8w8g0="; subPkgs = "."; ldflags = "-X 'github.com/lintingzhen/commitizen-go/cmd.revision=unspecified (nix build)' -X 'github.com/lintingzhen/commitizen-go/cmd.version=1.0.3'";
    prep = ''
      ${fix} vendor/github.com/AlecAivazis/survey/v2/terminal/runereader_posix.go terminal ${termios}
      sed -i "s/int(fd), int(req)/int(fd), uint(req)/" vendor/github.com/AlecAivazis/survey/v2/terminal/zz_hlcli_ioctl_illumos.go   # this x/sys/unix takes req uint
    '';
    check = chk ''"$out/bin/commitizen-go" --help'' "[Uu]sage"; };
  # git-chglog (MIT): CHANGELOG generator implemented in Go (Golang).
  git-chglog = pkg { pname = "git-chglog"; version = "0.15.4"; src = gh "git-chglog/git-chglog" "v0.15.4" "2351cb4ca5fde61ddc844d210dc5481c7361cfb99f70f35140a57ef6cb5cb311";
    vendorHash = "sha256-3HNZLiq4KW0MD0ScC8cklRTKlOk7GM1qnVrLzoyBbaY="; subPkgs = "./cmd/git-chglog"; ldflags = "-s -w -X=main.Version=v0.15.4";
    prep = ''
      ${fix} vendor/github.com/AlecAivazis/survey/v2/terminal/runereader_posix.go terminal ${termios}
      sed -i "s/int(fd), int(req)/int(fd), uint(req)/" vendor/github.com/AlecAivazis/survey/v2/terminal/zz_hlcli_ioctl_illumos.go   # this x/sys/unix takes req uint
    '';
    check = chk ''"$out/bin/git-chglog" --help'' "[-]-tag-filter-pattern"; };
  # grpc-client-cli (MIT): generic gRPC command line client.
  grpc-client-cli = pkg { pname = "grpc-client-cli"; version = "1.24.8"; src = gh "vadimi/grpc-client-cli" "v1.24.8" "78a4aaa09fd55b012e4e630f501106b94329d3e8bb94f9e107b8f8adbae25a8b";
    vendorHash = "sha256-zfF5Ql98xR5buVei1+DK+3vUjWp1eMn620rbwHgwx8U="; subPkgs = "./cmd/grpc-client-cli";
    prep = ''
      ${fix} vendor/github.com/AlecAivazis/survey/v2/terminal/runereader_posix.go terminal ${termios}
    '';
    check = chk ''"$out/bin/grpc-client-cli" --version'' "1\\.24\\.8"; };
  # kicli (MIT): CLI interface to the Kimai time tracking project.
  kicli = pkg { pname = "kicli"; version = "1.0.0"; src = gh "anned20/kicli" "v1.0.0" "3c7399cf9735f2ef5ac97973912767ede86c9b6ded055deab1175df9bca6d00f";
    vendorHash = "sha256-f8e6SMvIzH0H8aaphdCwsbRteFdO5qN0b2x5ZhYn90o="; subPkgs = ".";
    prep = ''
      ${fix} vendor/github.com/AlecAivazis/survey/v2/terminal/runereader_posix.go terminal ${termios}
      sed -i "s/int(fd), int(req)/int(fd), uint(req)/" vendor/github.com/AlecAivazis/survey/v2/terminal/zz_hlcli_ioctl_illumos.go   # this x/sys/unix takes req uint
    '';
    check = chk ''"$out/bin/kicli" --help'' "[-]-log-level"; };
  # kool (MIT): from local development to the cloud: development workflow made easy.
  kool = pkg { pname = "kool"; version = "3.6.0"; src = gh "kool-dev/kool" "refs/tags/3.6.0" "6fec7ef41259b69da8700ed4bb53ea4cf71ecb46634a64f42dc25ec4439dc126";
    vendorHash = "sha256-TuSyHat6lOsYnXdg+7b/buDo+tBmRZCFqil1cLAuKS0="; subPkgs = "."; ldflags = "-s -X=kool-dev/kool/commands.version=3.6.0";
    prep = ''
      ${fix} vendor/github.com/AlecAivazis/survey/v2/terminal/runereader_posix.go terminal ${termios}
    '';
    check = chk ''"$out/bin/kool" --version'' "3\\.6\\.0"; };
  # lazycommit (MIT): simple cli for generating git commits.
  lazycommit = pkg { pname = "lazycommit"; version = "1.5.3"; src = gh "m7medvision/lazycommit" "refs/tags/v1.5.3" "fc2d892e81aaa2c01641ac0ef1bca139a77c5eb5f6a5560bf19b0207c37cdb19";
    vendorHash = "sha256-sRGZbE14eb+MyNICwZ4TwGwLaeM7aDYRAH1i7pb5B24="; subPkgs = "."; ldflags = "-X main.version=1.5.3 -X main.buildSource=nix";
    prep = ''
      ${fix} vendor/github.com/AlecAivazis/survey/v2/terminal/runereader_posix.go terminal ${termios}
    '';
    check = chk ''"$out/bin/lazycommit" --help'' "[Uu]sage"; };
  # godu (MIT): utility helping to discover large files/folders.
  godu = pkg { pname = "godu"; version = "1.5.2"; src = gh "viktomas/godu" "v1.5.2" "09869710652969b8a9d227dea4ac33893b1f538197b101affa6a8a9aa6a50474";
    vendorHash = "sha256-ZbrlCKWhvi2fnzJ8CaTeISvkRQL0cxIfFHxgKMDMCMo="; subPkgs = "."; ldflags = "-s -w";
    prep = ''
      ${fix} vendor/github.com/gosuri/uilive/terminal_size.go uilive
      sed -i "s/int(fd), int(req)/int(fd), uint(req)/" vendor/github.com/gosuri/uilive/zz_hlcli_ioctl_illumos.go   # this x/sys/unix takes req uint
    '';
    check = chk ''"$out/bin/godu" --help'' "[Uu]sage"; };
  # lazyjournal (MIT): TUI for journalctl, file system logs, as well as Docker and Podman containers.
  lazyjournal = pkg { pname = "lazyjournal"; version = "0.8.6"; src = gh "Lifailon/lazyjournal" "refs/tags/0.8.6" "5798b65c98ec00f32cf43e79b31568896084881adb3afc9e7cda3482baad3183";
    vendorHash = "sha256-PCwgXJavNm5r8vQsS9vQpl+9SUH+wFXcJYhEUdMlzQQ="; subPkgs = "."; ldflags = "-s -w";
    prep = ''
      ${fix} vendor/github.com/awesome-gocui/gocui/gui_others.go gocui
    '';
    check = chk ''"$out/bin/lazyjournal" --version'' "0\\.8\\.6"; };
  # lfk (Apache-2.0): lightning Fast Kubernetes navigator.
  lfk = pkg { pname = "lfk"; version = "0.14.19"; src = gh "janosmiko/lfk" "refs/tags/v0.14.19" "4f46a72402305e16ef2ed2bdb5c2be5cb836c4c8485fdcb525e9bbb9015e949b";
    vendorHash = "sha256-SnMPcE2EE7xXmNuoV2XQpEw0MVL5rU14u80nb+b7m5k="; subPkgs = ". ./cmd/themegen"; ldflags = "-s";
    prep = ''
      ${fix} vendor/github.com/hinshun/vt10x/ioctl_posix.go vt10x
    '';
    check = chk ''"$out/bin/lfk" --help'' "[-]-background-watch-interval"; };
  # openpomodoro-cli (MIT): command-line Pomodoro tracker which uses the Open Pomodoro Format.
  openpomodoro-cli = pkg { pname = "openpomodoro-cli"; version = "0.3.0"; src = gh "open-pomodoro/openpomodoro-cli" "refs/tags/v0.3.0" "8abd81d99c1a300bfac73c8f447b95e6367f8b27af0ad136fbe6f143ba658782";
    vendorHash = "sha256-+DBCDuMqrJcgIp3xahx2+VIZ/y28F50Q6o4gaXOP7Yc="; subPkgs = ". ./cmd/pomodoro"; ldflags = "-w -s -X=main.Version=0.3.0";
    check = chk ''"$out/bin/openpomodoro-cli" --version'' "0\\.3\\.0"; };
  # wego (ISC): weather app for the terminal.
  wego = pkg { pname = "wego"; version = "2.4"; src = gh "schachmat/wego" "2.4" "5ae1c76a322ff2e295034a801755c42b0cb6bdef5ab205af42cf95dbf7c570f4";
    vendorHash = "sha256-N8b0gpYE5eWJE3ligrHW/HZTOoJ9XMVYg45nbMNiBFY="; subPkgs = ".";
    check = chk ''WEGORC="$W/wegorc" "$out/bin/wego" --help'' "[-]aat-monochrome"; };
}
