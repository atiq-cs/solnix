# cli/go-gl3.nix -- more Go leaves the x86 build queue has jobs for (lane gl3, 2026-11-15), as ./go-gl1.nix: nixpkgs f4a03c0 by-name
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
  # autorestic (Apache-2.0): high level CLI utility for restic.
  autorestic = pkg { pname = "autorestic"; version = "1.8.3"; src = gh "cupcakearmy/autorestic" "v1.8.3" "2f9ccdb83621530ebda4d22373554af45eeb550d32924a82249dbc66cb867726";
    vendorHash = "sha256-+n2zZ8+wLkSKmVbudJMx+3/R8lVIVeLjOD1c6WiOEck="; subPkgs = ". ./build";
    check = chk ''"$out/bin/autorestic" --version'' "1\\.8\\.3"; };
  # badrobot (Apache-2.0): operator Security Audit Tool.
  badrobot = pkg { pname = "badrobot"; version = "0.1.4"; src = gh "controlplaneio/badrobot" "refs/tags/v0.1.4" "ea2667c56565525381ee40a6da68a5c70fac420e7085a2c2482b88bd87ffe067";
    vendorHash = "sha256-B9xqvtw5XEKYrBZk+TUCKEPe/Lv0iSPl7c06TvJxZp4="; subPkgs = "."; ldflags = "-s -w -X github.com/controlplaneio/badrobot/cmd.version=v0.1.4";
    check = chk ''"$out/bin/badrobot" version'' "0\\.1\\.4"; };
  # cert-viewer (Apache-2.0): admin tool to view and inspect multiple x509 Certificates.
  cert-viewer = pkg { pname = "cert-viewer"; version = "0.9.1"; src = gh "mgit-at/cert-viewer" "refs/tags/v0.9.1" "f352d5857449a7b6dd3d4b3886abab7572fbf3e717ceabec339168653256bab9";
    vendorHash = "sha256-JHELshiIkF39ygWke1LZGOobMrcjQATTFcZfWWNUuZg="; subPkgs = ".";
    check = chk ''"$out/bin/cert-viewer" --help'' "[-]-help-long"; };
  # cidrgrep (MIT): like grep but for IPv4 CIDRs.
  cidrgrep = pkg { pname = "cidrgrep"; version = "0-unstable-2020-11-17"; src = gh "tomdoherty/cidrgrep" "8ad5af533e8dc33ea18ff19b7c6a41550748fe0e" "c3cb61b4c59f4fec9fdf19559605c4f359e8652628ad6d54c69f0502f5a4d249";
    vendorHash = null; subPkgs = "./cmd";
    check = chk ''"$out/bin/cmd" --help'' "invalid CIDR address: --help"; };
  # dnstap (Apache-2.0): structured DNS server events decoding utility.
  dnstap = pkg { pname = "dnstap"; version = "0.4.0"; src = gh "dnstap/golang-dnstap" "refs/tags/v0.4.0" "bf59ae30d81dd022b81d946254e2818b397011aec1e0a5bea0c0df9abe1f1f83";
    vendorHash = "sha256-K+ikCuNGcT5jG883zuzu8KlZabtFftY9QKGAAGfMrvE="; subPkgs = "./dnstap";
    check = chk ''"$out/bin/dnstap" --help'' "[Uu]sage"; };
  # dockerfmt (MIT): dockerfile formatter: a modern dockfmt.
  dockerfmt = pkg { pname = "dockerfmt"; version = "0.5.4"; src = gh "reteps/dockerfmt" "refs/tags/v0.5.4" "feceb63f17513d8310efbe81c660bf48f6a3bd8040ab00a45dc4c9fbf591033f";
    vendorHash = "sha256-4aKEFfqOMuDB0hGb8JMqGe5eWUbKsDtGOf4p35IwcNQ="; subPkgs = "."; ldflags = "-s -w -X github.com/reteps/dockerfmt/cmd.Version=0.5.4";
    check = chk ''"$out/bin/dockerfmt" version'' "0\\.5\\.4"; };
  # dstask (MIT): command line todo list with super-reliable git sync.
  dstask = pkg { pname = "dstask"; version = "1.0.1"; src = gh "naggie/dstask" "v1.0.1" "afca526d049874e2609d91c0e5f186d614c684ec13b2fe517e00ec4eeb4f70da";
    vendorHash = "sha256-SJ3VrBjEa3df0pcxV3YoTZpOcNNslXBBv/04zz4/fl8="; subPkgs = "./cmd/dstask ./cmd/dstask-import"; ldflags = "-w -s -X github.com/naggie/dstask.VERSION=1.0.1 -X github.com/naggie/dstask.GIT_COMMIT=v1.0.1";
    check = chk ''"$out/bin/dstask" version'' "1\\.0\\.1"; };
  # feed2imap-go (GPL-2.0): uploads rss feeds as e-mails onto an IMAP server.
  feed2imap-go = pkg { pname = "feed2imap-go"; version = "1.8.0"; src = gh "Necoro/feed2imap-go" "v1.8.0" "191efb28eace2e7a55c52e8494cff84c42b2c0a2bd3c5362862013fc4a627445";
    vendorHash = "sha256-zQCmYmzVoecAf4u37RUzg8uaneWqyjU7D72/aVkFO/Q="; subPkgs = ". ./tools/print-cache"; ldflags = "-s -w -X github.com/Necoro/feed2imap-go/pkg/version.version=1.8.0 -X github.com/Necoro/feed2imap-go/pkg/version.commit=nixpkgs";
    check = chk ''"$out/bin/feed2imap-go" --version'' "1\\.8\\.0"; };
  # gh-pr-review (MIT): gitHub CLI extension that adds full inline PR review comment support.
  gh-pr-review = pkg { pname = "gh-pr-review"; version = "1.6.2"; src = gh "agynio/gh-pr-review" "refs/tags/v1.6.2" "1765485d6cbfb132f2126055413c5e5cf2733b86f00b33cf29366d355145df3e";
    vendorHash = "sha256-bbAlPFCUUbdX83BkVoqUZUu4IFXZVB4XJbr8kf42eiU="; subPkgs = ".";
    check = chk ''"$out/bin/gh-pr-review" --help'' "[Uu]sage"; };
  # ghorg (Apache-2.0): quickly clone an entire org/users repositories into one directory.
  ghorg = pkg { pname = "ghorg"; version = "1.11.16"; src = gh "gabrie30/ghorg" "refs/tags/v1.11.16" "a8f172c428ee341b49025dc4b08057b3910714e78ab7941f8e93bd091710ecca";
    vendorHash = null; subPkgs = "."; ldflags = "-s -w -X main.version=1.11.16";
    check = chk ''"$out/bin/ghorg" version'' "1\\.11\\.16"; };
  # gmailctl (MIT): declarative configuration for Gmail filters.
  gmailctl = pkg { pname = "gmailctl"; version = "0.13.0"; src = gh "mbrt/gmailctl" "v0.13.0" "49df3a2fe7929114ec406096d577004a27ad75bbb4c836ca603dff88c1a830bd";
    vendorHash = "sha256-0H/pAfNHzgk84Wv8FkCIDk9Y6tZOV+1JVfr1IRILCmc="; subPkgs = "./cmd/gmailctl ./cmd/gmailctl-config-migrate";
    check = chk ''"$out/bin/gmailctl" --help'' "[Uu]sage"; };
  # go-crx3 (Apache-2.0): chrome browser extension tools.
  go-crx3 = pkg { pname = "go-crx3"; version = "1.7.0"; src = gh "mmadfox/go-crx3" "refs/tags/v1.7.0" "79839320476fb307ca396d58494ac06098891d65eeb3d19910c9cdcd255e7c7c";
    vendorHash = "sha256-TkiSjG391DzGODiAyuHGJEOZZxoYD//J8uKDEXAZADc="; subPkgs = "./crx3"; ldflags = "-s -w";
    check = chk ''"$out/bin/crx3" version'' "1\\.7\\.0"; };
  # gops (BSD-3-Clause): tool to list and diagnose Go processes currently running on your system.
  gops = pkg { pname = "gops"; version = "0.3.29"; src = gh "google/gops" "v0.3.29" "c4637684ac8efbcc0bc55faf64e3920a7764a9ae8f4580945084c1a5b8b2d051";
    vendorHash = "sha256-M9vv4Q9eF0AFExXflTgru8+mU2gkY40aavgpN7Xalxs="; subPkgs = ".";
    check = chk ''"$out/bin/gops" --help'' "[Uu]sage"; };
  # gotlsaflare (MIT): update TLSA DANE records on cloudflare from x509 certificates.
  gotlsaflare = pkg { pname = "gotlsaflare"; version = "2.9.0"; src = gh "Stenstromen/gotlsaflare" "refs/tags/v2.9.0" "d9616f329fe057042f2ea5b913bb0bc55c1eade8298074a07b51a3ef796dbc14";
    vendorHash = "sha256-mRe8gr30X9wascBoHCue8+jSzPH1W/6VaPPIFmRv6/4="; subPkgs = ".";
    check = chk ''"$out/bin/gotlsaflare" --help'' "[Uu]sage"; };
  # goverview (MIT): tool to get an overview of the list of URLs.
  goverview = pkg { pname = "goverview"; version = "1.0.1"; src = gh "j3ssie/goverview" "refs/tags/v1.0.1" "bb4043df57b459392e1d9b15464c0ed3e21aff28a70f5bc24c56d66c1926acb8";
    vendorHash = "sha256-NxU62gEU2yXomfrFg/aXsTsppIO3F2gNAAWMVU0AbhY="; subPkgs = "."; ldflags = "-w -s";
    check = chk ''"$out/bin/goverview" --version'' "1\\.0\\.1"; };
  # gtrash (MIT): trash CLI manager written in Go.
  gtrash = pkg { pname = "gtrash"; version = "0.0.6"; src = gh "umlx5h/gtrash" "v0.0.6" "66003276073d9da03cbb4347a4b161f89c81f3706012b77c3e91a154c91f3586";
    vendorHash = "sha256-9RqSak8e41+VAXX2kR34BKSecWNrTIxVEDJl6o1dIGE="; subPkgs = "."; ldflags = "-s -w -X main.version=0.0.6 -X main.builtBy=nixpkgs";
    check = chk ''"$out/bin/gtrash" --version'' "0\\.0\\.6"; };
  # hostctl (MIT): CLI tool to manage the /etc/hosts file.
  hostctl = pkg { pname = "hostctl"; version = "1.1.4"; src = gh "guumaster/hostctl" "v1.1.4" "c3df61772bb0f521def04e3fff2bda652725ee2dfb4c58e10456d84e94f67003";
    vendorHash = "sha256-kjHKeMHhoVRXkcxpjyAAgyiemOaue/kWbsF331qnLR4="; subPkgs = "./cmd/hostctl"; ldflags = "-s -w -X github.com/guumaster/hostctl/cmd/hostctl/actions.version=1.1.4";
    check = chk ''"$out/bin/hostctl" --version'' "1\\.1\\.4"; };
  # jprq (BSD-3-Clause): free and open tool for exposing local servers to public network.
  jprq = pkg { pname = "jprq"; version = "2.4"; src = gh "azimjohn/jprq" "refs/tags/2.4" "a3fc5a804851129c79a02deb3e5b7f5b84c0f351d688ca0088b571407399ff30";
    vendorHash = "sha256-f2yVTkStuCrFIgGZvCq7hL6wk4Bab5ib13NDWeFh3Zw="; subPkgs = "./cli";
    check = chk ''"$out/bin/cli" --version'' "2\\.4"; };
  # kaf (Apache-2.0): modern CLI for Apache Kafka, written in Go.
  kaf = pkg { pname = "kaf"; version = "0.2.14"; src = gh "birdayz/kaf" "v0.2.14" "83e78c19e5bce2d1922910809c19bacf489f6d16bbabefa6dcdd3e4b5c292b13";
    vendorHash = "sha256-5x99XrwOL9fnbhujXewEiStuuvMMbT267juwz0gxqBk="; subPkgs = "./cmd/kaf";
    check = chk ''"$out/bin/kaf" --help'' "[-]-schema-registry"; };
  # kitops (Apache-2.0): open source DevOps tool for packaging and versioning AI/ML models, datasets, code, and configuration into an OCI Artifact.
  kitops = pkg { pname = "kitops"; version = "1.16.0"; src = gh "kitops-ml/kitops" "refs/tags/v1.16.0" "380e8586c376327591cca9fd510eacdd9bbd7050144c491cb302c369224b9283";
    vendorHash = "sha256-XCZGSkgITPbV9MgpZGwirVt+51Xsng9bRbWJk7M11ts="; subPkgs = "."; ldflags = "-s -X github.com/kitops-ml/kitops/pkg/lib/constants.Version=v1.16.0";
    check = chk ''"$out/bin/kitops" --help'' "[Uu]sage"; };
}
