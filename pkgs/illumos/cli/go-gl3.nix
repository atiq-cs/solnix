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
  # kube-bench (Apache-2.0): checks whether Kubernetes is deployed according to security best practices as defined in the CIS Kubernetes Benchmark.
  kube-bench = pkg { pname = "kube-bench"; version = "0.16.0"; src = gh "aquasecurity/kube-bench" "refs/tags/v0.16.0" "41fb9a5db1030439270a6a969da49cccb5149bd760fa478c0ca8757d0ef7bcce";
    vendorHash = "sha256-h5FpO9vm71O6y18fG0EYO21Q0kebe1zGNRnJIxb2px8="; subPkgs = "."; ldflags = "-s -w -X github.com/aquasecurity/kube-bench/cmd.KubeBenchVersion=v0.16.0";
    check = chk ''"$out/bin/kube-bench" version'' "0\\.16\\.0"; };
  # kubectl-images (MIT): show container images used in the cluster.
  kubectl-images = pkg { pname = "kubectl-images"; version = "0.6.5"; src = gh "chenjiandongx/kubectl-images" "v0.6.5" "dbf58fd3c793e2570b2853fee584cedd5df9915855803465a4d0d84311924aef";
    vendorHash = "sha256-1zJ2aeFe8ePEpPLpnZejX9xJAuN2T+3i+Z1OreOwflw="; subPkgs = "./cmd";
    check = chk ''"$out/bin/cmd" --version'' "0\\.6\\.5"; };
  # librespeed-cli (LGPL-3.0-only): command line client for LibreSpeed.
  librespeed-cli = pkg { pname = "librespeed-cli"; version = "1.0.14"; src = gh "librespeed/speedtest-cli" "refs/tags/v1.0.14" "3031e0f7babd7f9c51a1c49b95026d12532668455e8cc459049160f1bd525bf3";
    vendorHash = "sha256-wa3HEFkEK0nPFRohFYwMIH8hscrAhrlXGEYP3nP4XFs="; subPkgs = ".";
    check = chk ''"$out/bin/speedtest-cli" --help'' "[-]-no-download"; };
  # lokalise2-cli (BSD-3-Clause): translation platform for developers. Upload language files, translate, integrate via API.
  lokalise2-cli = pkg { pname = "lokalise2-cli"; version = "3.1.7"; src = gh "lokalise/lokalise-cli-2-go" "v3.1.7" "459cec0348a3308bc84e2d56e57086325b144fae8458aaf483aa4956ae36f135";
    vendorHash = "sha256-hLt5iEWk7kwJUUnZ4S01vRGQ8f2YvqAmTEjHoIrTICE="; subPkgs = ".";
    check = chk ''"$out/bin/lokalise-cli-2-go" --version'' "3\\.1\\.7"; };
  # nix-auth (MIT): nix access-token management tool.
  nix-auth = pkg { pname = "nix-auth"; version = "0.1.0"; src = gh "numtide/nix-auth" "refs/tags/v0.1.0" "a90daf3503a7f9be7e911ed201aa49c2f2c8b5b11fad981545d9f794c7a8ae0a";
    vendorHash = "sha256-YuCxkbyxUeT5hCvve4kHR9w5rQOCD4IhKICCJvp4i4I="; subPkgs = "."; ldflags = "-s -w -X=github.com/numtide/nix-auth/internal/version.Version=0.1.0";
    check = chk ''"$out/bin/nix-auth" version'' "0\\.1\\.0"; };
  # oink (MIT): dynamic DNS client for Porkbun.
  oink = pkg { pname = "oink"; version = "1.4.0"; src = gh "rlado/oink" "v1.4.0" "2158b705ce7467a9fc7484a1048d1e57b437197ab0165a1330270b3e67b24d31";
    vendorHash = null; subPkgs = "./src";
    check = chk ''"$out/bin/src" --help'' "[Uu]sage"; };
  # passphrase2pgp (Unlicense): predictable, passphrase-based PGP key generator.
  passphrase2pgp = pkg { pname = "passphrase2pgp"; version = "1.3.0"; src = gh "skeeto/passphrase2pgp" "v1.3.0" "92525ba6833001bc9bc5799fd034ee18f77ca0bd1e32ee6e1125c57c3178a5fd";
    vendorHash = "sha256-tjN3pCj3ARSrhiBfGOVZM7tGKGPpRZl7v0UjwjLeo2I="; subPkgs = ".";
    check = chk ''"$out/bin/passphrase2pgp" --version'' "1\\.3\\.0"; };
  # pingtunnel (MIT): tool that send TCP/UDP traffic over ICMP.
  pingtunnel = pkg { pname = "pingtunnel"; version = "3.0"; src = gh "esrrhs/pingtunnel" "3.0" "383701e1e4364923244b51f4606f5fa3669ca9a973f024f788f8df8237763d31";
    vendorHash = "sha256-H+sgDjQv0WhQewuFPPtC/Ezv87vU7SGRAZMKhq/JXmM="; subPkgs = "./cmd"; ldflags = "-s";
    check = chk ''"$out/bin/cmd" --version'' "3\\.0"; };
  # protolock (BSD-3-Clause): protocol Buffer companion tool. Track your .proto files and prevent changes to messages and services which impact API compatibility. https://protolock.dev.
  protolock = pkg { pname = "protolock"; version = "0.17.0"; src = gh "nilslice/protolock" "v0.17.0" "81bec7a85a866f1c4c2f361bba718bc2d6ba7dc7e6d662787a44c4e89c0d4b3d";
    vendorHash = "sha256-qfphAW2IIFd/+HnxjsyAjdAQtPYERvP8qS/1Cq8ECh0="; subPkgs = "./cmd/protolock ./plugin-samples/plugin-sample ./plugin-samples/plugin-sample-error";
    check = chk ''"$out/bin/protolock" --help'' "[Uu]sage"; };
  # s-search (MIT): web search from the terminal.
  s-search = pkg { pname = "s-search"; version = "0.8.1"; src = gh "zquestz/s" "refs/tags/v0.8.1" "9dd80e19b2287abf2689b8f9fd424fdfad9abdc51b69e3a550579db69d6c8f6f";
    vendorHash = "sha256-0H+ObnRN/sNx3TiOZE2688OggvYgQW2RenBp8vn30GU="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/s" --version'' "0\\.8\\.1"; };
  # scc (MIT): very fast accurate code counter with complexity calculations and COCOMO estimates written in pure Go.
  scc = pkg { pname = "scc"; version = "4.1.0"; src = gh "boyter/scc" "v4.1.0" "4f3cf36010c542b10d5582afb91c668b26889160b184deee21b4319347030a7c";
    vendorHash = null; subPkgs = ". ./cmd/badges";
    check = chk ''"$out/bin/scc" --version'' "4\\.1\\.0"; };
  # skywalking-eyes (Apache-2.0): check and fix license headers and resolve dependencies' licenses.
  skywalking-eyes = pkg { pname = "skywalking-eyes"; version = "0.9.0"; src = gh "apache/skywalking-eyes" "refs/tags/v0.9.0" "09659bf028cef97bcd2d877c67ccde2df92c3dbaeb65d975cac5920a5db7fff6";
    vendorHash = "sha256-xb82tafDxC51T2dBcjo1tW2USM9GDSrRvDm16OnjXJo="; subPkgs = "./cmd/license-eye"; ldflags = "-s -w -X github.com/apache/skywalking-eyes/commands.version=0.9.0";
    check = chk ''"$out/bin/license-eye" --version'' "0\\.9\\.0"; };
  # sonoscli (MIT): control Sonos speakers from your terminal over LAN (UPnP/SOAP).
  sonoscli = pkg { pname = "sonoscli"; version = "0.3.5"; src = gh "steipete/sonoscli" "refs/tags/v0.3.5" "16d02e258984784533249130407384178e3ce06bdf26bca1f4679e30bb39e2af";
    vendorHash = "sha256-4BF5qp5xUskuDRWNFnQu0lT67B/GPM5RaW1ZOEETsaM="; subPkgs = "./cmd/sonos";
    check = chk ''"$out/bin/sonos" --version'' "0\\.3\\.5"; };
  # spotifycli (MIT): CLI to manage Spotify playlists.
  spotifycli = pkg { pname = "spotifycli"; version = "2.1.0"; src = gh "doronbehar/spotifycli" "refs/tags/v2.1.0" "517a2e1a40ed479f71a2b6799db7b545c71f53ee0605b45e260d2732872e0d91";
    vendorHash = "sha256-jz4QSZ85VesvS3zLmX82o4yAirOT86KylBWnRpAK03Q="; subPkgs = ".";
    check = chk ''"$out/bin/spotifycli" --help'' "[Uu]sage"; };
  # summon (MIT): CLI that provides on-demand secrets access for common DevOps tools.
  summon = pkg { pname = "summon"; version = "0.11.0"; src = gh "cyberark/summon" "v0.11.0" "eab6ec15d85a82b1c849029f0ff7c2df64346cbe6dfe849dc0fa8db5f7f2265e";
    vendorHash = "sha256-eCbg2vQXx4JDduHGuuBwFeKu+bWgZayRNOMyD05ueLA="; subPkgs = "./cmd";
    check = chk ''"$out/bin/cmd" --help'' "[-]-all-provider-versions"; };
  # tasktimer (MIT): task Timer (tt) is a dead simple TUI task timer.
  tasktimer = pkg { pname = "tasktimer"; version = "1.12.0"; src = gh "caarlos0/tasktimer" "v1.12.0" "73cca9d35b2a25ea4407baebab1ee0a446fe1bc8492832db1ca781f9e22757b3";
    vendorHash = "sha256-8LxLiVzy+tMY+mDQB1ofp+rwTSXMNRc3wV0O9APT7vs="; subPkgs = ".";
    check = chk ''"$out/bin/tasktimer" --help'' "[Uu]sage"; };
  # thrift-ls (Apache-2.0): thrift Language Server.
  thrift-ls = pkg { pname = "thrift-ls"; version = "0.2.12"; src = gh "joyme123/thrift-ls" "v0.2.12" "e32d0c8b8bae241e8a829d88da156124ee5dad12aacfb55a462e868eec07bec0";
    vendorHash = "sha256-GWsRx1UoVwdCrHsIxbv/yZmCrzNZlOgNRzfyhbWUtjQ="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/thrift-ls" --help'' "[Uu]sage"; };
  # tscli (MIT): CLI tool to interact with the Tailscale API.
  tscli = pkg { pname = "tscli"; version = "0.3.0"; src = gh "jaxxstorm/tscli" "refs/tags/v0.3.0" "d8457518715d38df5ecead064e85a1ec10630d2dc440a65919172d05d803cc1d";
    vendorHash = "sha256-sjSuhtVWEzW8c8bbis80+fozRUHqGFv94Kl3BuH2yHA="; subPkgs = "./cmd/tscli ./coverage/coveragegaps ./coverage/docsgen ./coverage/openapirefresh"; ldflags = "-X=github.com/jaxxstorm/tscli/pkg/version.Version=0.3.0";
    check = chk ''"$out/bin/tscli" --version'' "0\\.3\\.0"; };
  # tyson (Apache-2.0): typeScript as a configuration language.
  tyson = pkg { pname = "tyson"; version = "0.1.1-unstable-2024-04-10"; src = gh "jetify-com/tyson" "d6b38819db9b260928b29f4d39bf4c72841c6a01" "4277596b2a3e893d06876075c407cfa40b0b46bc88460b3630859b3b9b065693";
    vendorHash = "sha256-FtGkXMoyGtVp6Oxc8cmLO+dEnchuZtfjaalT45v6oSs="; subPkgs = "./cmd/tyson"; ldflags = "-s -w";
    check = chk ''"$out/bin/tyson" --help'' "[Uu]sage"; };
  # woke (MIT): detect non-inclusive language in your source code.
  woke = pkg { pname = "woke"; version = "0.19.0"; src = gh "get-woke/woke" "refs/tags/v0.19.0" "d17c7e4e846a409af14e65a001d2ddb1657fd82f562704e0c10ced4dadcfd31c";
    vendorHash = "sha256-IBexo0Sqondd3zXXHnyYrmGw8Jy44O8/urBLwaFM9lA="; subPkgs = ". ./cmd/docs"; ldflags = "-s -w -X=github.com/get-woke/woke/cmd.Version=0.19.0 -X=github.com/get-woke/woke/cmd.Commit=v0.19.0 -X=github.com/get-woke/woke/cmd.Date=1970-01-01T00:00:00Z";
    check = chk ''"$out/bin/woke" --version'' "0\\.19\\.0"; };
  # astartectl (Apache-2.0): astarte command line client utility.
  astartectl = pkg { pname = "astartectl"; version = "26.5.0"; src = gh "astarte-platform/astartectl" "v26.5.0" "f87ef2c89234883e763fe75ed35d457b45d80dc23b0d96414a72c2759d5316c5";
    vendorHash = "sha256-QdPBo4SL8g8V/KYgY5vdJwIKKeND+wSK8gIC53W6YGg="; subPkgs = ".";
    check = chk ''"$out/bin/astartectl" version'' "26\\.5\\.0"; };
  # aws-nuke (MIT): remove all the resources from an AWS account.
  aws-nuke = pkg { pname = "aws-nuke"; version = "3.68.3"; src = gh "ekristen/aws-nuke" "refs/tags/v3.68.3" "2f06b307aa1addccf9231f0fd1f394c63507a8c7438e8113a91386066be0d6aa";
    vendorHash = "sha256-ORMAUHwkVkI7kdhZ675wN/RpHkOP+RJMb3PpQcOx0X8="; subPkgs = "."; ldflags = "-s -w -X=github.com/ekristen/aws-nuke/v3/pkg/common.SUMMARY=3.68.3";
    check = chk ''"$out/bin/aws-nuke" --version'' "3\\.68\\.3"; };
  # baidupcs-go (Apache-2.0): baidu Netdisk commandline client, mimicking Linux shell file handling commands.
  baidupcs-go = pkg { pname = "baidupcs-go"; version = "4.0.2"; src = gh "qjfoidnh/BaiduPCS-Go" "v4.0.2" "12904ec8daee445b357f59d604103108a324f5b1c60cb0d8324f5df216683553";
    vendorHash = "sha256-6Q+p9d4RoXyXbtxfk5eq7X0+YK38qlxN7sZiTSDBcbQ="; subPkgs = ". ./cmd/AndroidNDKBuild"; ldflags = "-X main.Version=4.0.2";
    check = chk ''"$out/bin/BaiduPCS-Go" --version'' "4\\.0\\.2"; };
  # chain-bench (Apache-2.0): open-source tool for auditing your software supply chain stack for security compliance based on a new CIS Software Supply Chain benchmark.
  chain-bench = pkg { pname = "chain-bench"; version = "0.1.10"; src = gh "aquasecurity/chain-bench" "v0.1.10" "5bfeaacd9cf7d272e88597135bff7f329d455a810aaf2b6a763ac55e18d383c1";
    vendorHash = "sha256-p3PM7GsIotPggsdBAxilAoN8dYhQYUi7vVxPVhqI5WQ="; subPkgs = "./cmd/chain-bench"; ldflags = "-s -w -X main.version=v0.1.10";
    check = chk ''"$out/bin/chain-bench" --version'' "0\\.1\\.10"; };
  # coze (BSD-3-Clause): CLI client for Coze, a cryptographic JSON messaging specification.
  coze = pkg { pname = "coze"; version = "0.0.3"; src = gh "Cyphrme/CozeCLI" "v0.0.3" "ce692d1cdf75d3c0e9aa9774a6dc2aec2db2362393a1fe1d7daaac998df2fcda";
    vendorHash = "sha256-xTT9mNWwHjLma1XtYeMYbQyMbXPIwgiboLvShFknZfE="; subPkgs = ".";
    check = chk ''"$out/bin/coze_cli" --help'' "[Uu]sage"; };
  # docker-color-output (MIT): add color to the Docker CLI.
  docker-color-output = pkg { pname = "docker-color-output"; version = "3.0.1"; src = gh "devemio/docker-color-output" "refs/tags/v3.0.1" "12bfdbfcccf493e8e8f89ddfe89a4de99c97c9283c1fd3172c423295efdf1d0c";
    vendorHash = "sha256-iilIeSduL8b74CSvskMxYCBSYKsv+xDcS8GNyyWyAGM="; subPkgs = "./cmd/cli";
    check = chk ''"$out/bin/cli" --version'' "3\\.0\\.1"; };
  # doggo (GPL-3.0-only): command-line DNS Client for Humans. Written in Golang.
  doggo = pkg { pname = "doggo"; version = "1.4.0"; src = gh "mr-karan/doggo" "v1.4.0" "e0d043aa34fb8daa44df07558fd32fe2686eba6644d5f6834edbc8a789d42e1d";
    vendorHash = "sha256-8At1Py4VW81UNBtXy1r01AR6TKVUXLWf9J7LrvGeF8o="; subPkgs = "./cmd/doggo"; ldflags = "-s -X main.buildVersion=v1.4.0";
    check = chk ''"$out/bin/doggo" --version'' "1\\.4\\.0"; };
  # exercism (MIT): go based command line tool for exercism.io.
  exercism = pkg { pname = "exercism"; version = "3.5.9"; src = gh "exercism/cli" "refs/tags/v3.5.9" "8595fc3e8b0ff3fcff7cc56a67bee58156665e71eee1ff9eace593568ec8debf";
    vendorHash = "sha256-bmTiunVU3nADr8/PWw7/wnuq2+lXcwP7jb43EjqWuFU="; subPkgs = "./exercism";
    check = chk ''"$out/bin/exercism" version'' "3\\.5\\.9"; };
  # geek-life (MIT): todo List / Task Manager for Geeks in command line.
  geek-life = pkg { pname = "geek-life"; version = "0.1.3"; src = gh "ajaxray/geek-life" "v0.1.3" "e9299c71539b5b67be107ad8d3a574ad16a6251c9294b61e97f2b9b59c0b9322";
    vendorHash = "sha256-Ok+86tOfq68lKbxupISzB9/GThotCMynqJsfTT95xrM="; subPkgs = "./app";
    check = chk ''"$out/bin/app" --help'' "[-]-db-file"; };
  # ghatm (MIT): set timeout-minutes to all GitHub Actions jobs.
  ghatm = pkg { pname = "ghatm"; version = "1.0.0"; src = gh "suzuki-shunsuke/ghatm" "refs/tags/v1.0.0" "efa1ba94caa5e138a59408ad505252e62603e89738fb1e0ba8072be9db5992da";
    vendorHash = "sha256-rg6MR7zl6mN75HPySdeeUVnTMjW2/5mI1UFKc8q5WpY="; subPkgs = "./cmd/ghatm"; ldflags = "-s -w -X main.version=1.0.0 -X main.commit=v1.0.0";
    check = chk ''"$out/bin/ghatm" --version'' "1\\.0\\.0"; };
  # globalping-cli (MPL-2.0): simple CLI tool to run networking commands remotely from hundreds of globally distributed servers.
  globalping-cli = pkg { pname = "globalping-cli"; version = "1.6.1"; src = gh "jsdelivr/globalping-cli" "v1.6.1" "137c51116f8975ee17813ce68667aed89c05a13d1121fae31a11683cb4838b01";
    vendorHash = "sha256-MNHg0fPJf21vl3M+0XKM8Al+05FhhGzy0F3BLXEEimg="; subPkgs = "."; ldflags = "-s -w -X main.version=1.6.1";
    check = chk ''"$out/bin/globalping-cli" version'' "1\\.6\\.1"; };
  # go-autoconfig (MIT): IMAP/SMTP autodiscover feature for Thunderbird, Apple Mail and Microsoft Outlook.
  go-autoconfig = pkg { pname = "go-autoconfig"; version = "0.0.1-unstable-2022-08-03"; src = gh "savely-krasovsky/go-autoconfig" "b1b182202da82cc881dccd715564853395d4f76a" "ac244d1c7965908d613a241eeeae0f57ede857581d457891d8a17da80cf5d0f0";
    vendorHash = "sha256-KJ4iUuB7c2mfWS5MMEcbZKlSf5lSiQp50yQarlloBYM="; subPkgs = ".";
    check = chk ''"$out/bin/go-autoconfig" --help'' "[Uu]sage"; };
  # goodhosts (MIT): CLI tool for managing hostfiles.
  goodhosts = pkg { pname = "goodhosts"; version = "1.1.3"; src = gh "goodhosts/cli" "v1.1.3" "66dc0e43522006feba1c9f73b4a9c9620ac615996c13a28c9a26bf8e8618a4ab";
    vendorHash = "sha256-JqB8fewJ7jnMPZMhCXH2fGnS4TewDveOe7xAp2MgmLw="; subPkgs = "."; ldflags = "-s -w -X main.version=1.1.3";
    check = chk ''"$out/bin/cli" version'' "1\\.1\\.3"; };
  # gotify-cli (MIT): command line interface for pushing messages to gotify/server.
  gotify-cli = pkg { pname = "gotify-cli"; version = "2.4.0"; src = gh "gotify/cli" "v2.4.0" "d33622db87549355b8ccc3d4a4e342cfc769fa96c45213e682b53a0971c8c41d";
    vendorHash = "sha256-Uso3YiauncEXaGl+iB9y2yQ3+kMq3SaX+5dO+hBEnm8="; subPkgs = "."; ldflags = "-X main.Version=2.4.0 -X main.Commit=2.4.0 -X main.BuildDate=1970-01-01";
    check = chk ''"$out/bin/cli" --version'' "2\\.4\\.0"; };
  # gotmplfmt (GPL-3.0-or-later): fmt Go HTML templates.
  gotmplfmt = pkg { pname = "gotmplfmt"; version = "1.0.25"; src = gh "miekg/gotmplfmt" "refs/tags/v1.0.25" "87b80b40607d0eb1ef828b8443e38776feec1c139b4b0ab879b464d898fe2e3f";
    vendorHash = "sha256-H5oVRehDUNcXQmBanothJ2fxgR5/VLodrcnJxdcbPrM="; subPkgs = ".";
    check = chk ''"$out/bin/gotmplfmt" --help'' "[Uu]sage"; };
  # grafanactl (Apache-2.0): tool designed to simplify interaction with Grafana instances.
  grafanactl = pkg { pname = "grafanactl"; version = "0.1.10"; src = gh "grafana/grafanactl" "refs/tags/v0.1.10" "c3a3fef02f073aa92fb7b62c6f60a26e80fe794cf158f86830fe38ff053035fd";
    vendorHash = "sha256-FVvmkwAaX1WTptUyfaTF6VRgm4NohZpOXo58UoZUaSo="; subPkgs = "./cmd/grafanactl ./scripts/cmd-reference ./scripts/config-reference ./scripts/env-vars-reference"; ldflags = "-X main.version=v0.1.10 -X main.commit=unknown -X main.date=unknown";
    check = chk ''"$out/bin/grafanactl" --version'' "0\\.1\\.10"; };
  # gum (MIT): tasty Bubble Gum for your shell.
  gum = pkg { pname = "gum"; version = "2.0.2"; src = gh "charmbracelet/gum" "v2.0.2" "06403707671e9b2af386640d8b9f6079efc0aadf77e8f6b091bd191fe16c1264";
    vendorHash = "sha256-VyQpJ2lW9XiYsFtCSRtVM9pEewGSfv6uknvYLMcCaZQ="; subPkgs = "."; ldflags = "-s -w -X=main.Version=2.0.2";
    check = chk ''"$out/bin/gum" --version'' "2\\.0\\.2"; };
  # hyprkeys (GPL-3.0-only): simple, scriptable keybind retrieval utility for Hyprland.
  hyprkeys = pkg { pname = "hyprkeys"; version = "1.0.3"; src = gh "hyprland-community/Hyprkeys" "v1.0.3" "90692f3531e51a9fe97ab01e5a6d3c0ba5f991d81c0106bfbea67c52f0eddb57";
    vendorHash = "sha256-CNg5YCX8qPujV2KcpHg5/nDnh8zozZUhfRKe/vMX7gU="; subPkgs = "."; ldflags = "-s -w -X main.version=v1.0.3";
    check = chk ''"$out/bin/hyprkeys" version'' "1\\.0\\.3"; };
  # jump (MIT): navigate directories faster by learning your habits.
  jump = pkg { pname = "jump"; version = "0.69.0"; src = gh "gsamokovarov/jump" "v0.69.0" "17567f7acd305e2e8093f49e591aa03d74bc5c94204b0461550b0bd8055490af";
    vendorHash = "sha256-FZATKw7/mOHmB1s8tyuWDRaShzeTNnIduSH5g5W728A="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/jump" --version'' "0\\.69\\.0"; };
  # kconf (MIT): opinionated command line tool for managing multiple kubeconfigs.
  kconf = pkg { pname = "kconf"; version = "2.0.0"; src = gh "particledecay/kconf" "v2.0.0" "e7fe6750c719caf227890a31e2fd5446972ec3e1e5492180d0a387fe1c3394c0";
    vendorHash = "sha256-6ZLEfm1BnheevU+ZwYmIpUNnpcckYlVJgn6Fu6UPoEU="; subPkgs = "."; ldflags = "-s -w -X github.com/particledecay/kconf/build.Version=2.0.0";
    check = chk ''"$out/bin/kconf" version'' "2\\.0\\.0"; };
  # krelay (MIT): drop-in replacement for `kubectl port-forward` with some enhanced features.
  krelay = pkg { pname = "krelay"; version = "0.2.0"; src = gh "knight42/krelay" "v0.2.0" "7c01e033a3891dae9c476b1bcb0fe1d96a712ff19fce6df4989cf10024d56608";
    vendorHash = "sha256-qaSf6j0RAX9MPVBLlvv9mSnxDAMXhWBVLEEe6yH/Pik="; subPkgs = "./cmd/client"; ldflags = "-s -w -X github.com/knight42/krelay/pkg/constants.ClientVersion=0.2.0";
    check = chk ''"$out/bin/client" --help'' "[Uu]sage"; };
  # kubeaudit (MIT): audit tool for Kubernetes.
  kubeaudit = pkg { pname = "kubeaudit"; version = "0.22.2"; src = gh "Shopify/kubeaudit" "refs/tags/v0.22.2" "90752d42c4d502ab6776af3358ae87a02d2893fc2bb7a0364d6c1fdcd8ff0570";
    vendorHash = "sha256-OsVqIg/Mn08xR+RkImyHlojv+RANOXvsXXwDBPs81RA="; subPkgs = "./cmd";
    check = chk ''"$out/bin/cmd" version'' "0\\.22\\.2"; };
  # kubectl-ktop (Apache-2.0): top-like tool for your Kubernetes clusters.
  kubectl-ktop = pkg { pname = "kubectl-ktop"; version = "0.5.3"; src = gh "vladimirvivien/ktop" "refs/tags/v0.5.3" "f255733a56ce292cdf6ca543cf5ef85969814de8ccf60431d70b85dfe38f720f";
    vendorHash = "sha256-kfuVZx6uG4PwEUBX9a2GuvAwD7ExOplqMgXn02otQl8="; subPkgs = "."; ldflags = "-s -w -X github.com/vladimirvivien/ktop/buildinfo.Version=v0.5.3 -X github.com/vladimirvivien/ktop/buildinfo.GitSHA=v0.5.3";
    check = chk ''"$out/bin/ktop" --help'' "[-]-all-namespaces"; };
  # kubectx (Apache-2.0): fast way to switch between clusters and namespaces in kubectl.
  kubectx = pkg { pname = "kubectx"; version = "0.11.0"; src = gh "ahmetb/kubectx" "v0.11.0" "1c8eb6b30c0067f89e5b2f9480865b0e3229a221fadddb644ce192d663c63907";
    vendorHash = "sha256-L99uY4ZwoBxfwLo0MsK66yksrMbHnQIv7qkBvDJX3nE="; subPkgs = "./cmd/kubectx ./cmd/kubens"; ldflags = "-s -w -X main.version=0.11.0";
    check = chk ''"$out/bin/kubectx" --version'' "0\\.11\\.0"; };
  # lazyssh (Apache-2.0): terminal-based SSH manager.
  lazyssh = pkg { pname = "lazyssh"; version = "0.3.0"; src = gh "Adembc/lazyssh" "refs/tags/v0.3.0" "36cd630b3cd9447e88904171cbb64944aeacbbd62c15db66d8a0e4a4486ffe88";
    vendorHash = "sha256-fUXfmcnd7uH8Pe6JS25CRkb/VHjKFUR3/vOHi4b6REo="; subPkgs = "./cmd"; ldflags = "-X=main.version=0.3.0 -X=main.gitCommit=v0.3.0";
    check = chk ''"$out/bin/cmd" --help'' "[Uu]sage"; };
  # logdy (Apache-2.0): web based real-time log viewer.
  logdy = pkg { pname = "logdy"; version = "0.17.1"; src = gh "logdyhq/logdy-core" "refs/tags/v0.17.1" "bd5db124e736e42d3671697787a26b354e0be6e787a95e69c054ad873058fcec";
    vendorHash = "sha256-8Aw0H4ofHcAhm5rOmOeelmpI0v79aVEWk8YN6smP8rY="; subPkgs = ". ./example-app"; ldflags = "-s -w";
    check = chk ''"$out/bin/logdy-core" --help'' "[-]-append-to-file-raw"; };
  # microplane (Apache-2.0): CLI tool to make git changes across many repos.
  microplane = pkg { pname = "microplane"; version = "0.0.37"; src = gh "Clever/microplane" "v0.0.37" "437f65748272de89b8a6990f0f9fca57addf6ff6f8e4de077869976d2ce36154";
    vendorHash = "sha256-GyhlrdJjLfOVYGGUMlRqZ0t95ipmU2FCmCz6hMUU+T0="; subPkgs = ". ./demo"; ldflags = "-s -w -X main.version=0.0.37";
    check = chk ''"$out/bin/microplane" version'' "0\\.0\\.37"; };
  # nvs (MIT): lightweight Neovim Version & Config Manager CLI tool to install, switch, list, uninstall, and reset Neovim versions.
  nvs = pkg { pname = "nvs"; version = "1.15.0"; src = gh "y3owk1n/nvs" "refs/tags/v1.15.0" "1035ef21a2bf87bd736f66c8057c9491e57dfea99323083e4d8b0efddc8672c2";
    vendorHash = "sha256-+scCySFs0+pxDEtP8Uw3MowULXW5UeDPvlJU3zIJac8="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/nvs" --help'' "[Uu]sage"; };
  # open-in-mpv (GPL-3.0-only): simple web extension to open videos in mpv.
  open-in-mpv = pkg { pname = "open-in-mpv"; version = "2.4.3"; src = gh "Baldomo/open-in-mpv" "v2.4.3" "d15dc21fb2875598500f4ab222bde20773674d3084216028532558b9d83499c1";
    vendorHash = "sha256-sm8FXAM7YroIKlsSgu+FzOsSvn7oYXBK9TMpKMP0CGQ="; subPkgs = "./cmd/open-in-mpv"; ldflags = "-s -w";
    check = chk ''"$out/bin/open-in-mpv" --help'' "[Uu]sage"; };
  # phrase-cli (MIT): phraseApp API v2 Command Line Client.
  phrase-cli = pkg { pname = "phrase-cli"; version = "2.68.0"; src = gh "phrase/phrase-cli" "2.68.0" "82abb47e48d45fd3fc2e667754502faf612f35db039c35c63a963c49376e200a";
    vendorHash = "sha256-q3Y19zgMKvR19pF/bfIKCxNS7hBkg5KlnZreHeQZB74="; subPkgs = "."; ldflags = "-X=github.com/phrase/phrase-cli/cmd.PHRASE_CLIENT_VERSION=2.68.0";
    check = chk ''"$out/bin/phrase-cli" version'' "2\\.68\\.0"; };
  # pop (MIT): send emails from your terminal.
  pop = pkg { pname = "pop"; version = "0.5.0"; src = gh "charmbracelet/pop" "v0.5.0" "c577d4f3edf403e34832013b79ddc159c1eec938e0bd452b2623c853f752a75c";
    vendorHash = "sha256-5qNR4zdEhXzzw/nlacf5+KB6SqxcpbCjaBKrOltllrk="; subPkgs = "."; ldflags = "-s -w -X=main.Version=0.5.0";
    check = chk ''"$out/bin/pop" --version'' "0\\.5\\.0"; };
  # reader (GPL-3.0-or-later): lightweight tool offering better readability of web pages on the CLI.
  reader = pkg { pname = "reader"; version = "0.6.1"; src = gh "mrusme/reader" "refs/tags/v0.6.1" "06a17a10f837e92c6a22b30bc3660520e93e70d03740f2ff03e57ba45d00d53d";
    vendorHash = "sha256-vfyHViGlsxSvo/scftUA2+USqqLv5FKiqlAkRD1Xc2M="; subPkgs = ".";
    check = chk ''"$out/bin/reader" --help'' "[-]-markdown-output"; };
  # sbom-utility (Apache-2.0): utility that provides an API platform for validating, querying and managing BOM data.
  sbom-utility = pkg { pname = "sbom-utility"; version = "0.19.2"; src = gh "CycloneDX/sbom-utility" "refs/tags/v0.19.2" "e1f49f1c69d231f19a16085a56ad187700cf712287412182442d6f1b000fd77e";
    vendorHash = "sha256-5mJII+bEnPhQqUFS5S+A8z+GQcqJ6t6ss/TwPHJIPVE="; subPkgs = "."; ldflags = "-X main.Version=0.19.2";
    check = chk ''"$out/bin/sbom-utility" --version'' "0\\.19\\.2"; };
  # sift (GPL-3.0): fast and powerful alternative to grep.
  sift = pkg { pname = "sift"; version = "0.9.2"; src = gh "svent/sift" "v0.9.2" "d6d8274e475f3f1235eb0118a89f981e0f7741b9f27243d679d3ecd76f68fe03";
    vendorHash = "sha256-S3WONPc7Rkvgw+Fk84/XcTd7YtafA9C/lLkGJEKMDfQ="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/sift" --help'' "[-]-err-show-line-length"; };
  # smug (MIT): tmux session manager.
  smug = pkg { pname = "smug"; version = "0.3.19"; src = gh "ivaaaan/smug" "refs/tags/v0.3.19" "d1c43d84b5293cff1982437937367813f34cc1508d44da723b28649999147e3e";
    vendorHash = "sha256-P3/sYdvXiUAI5ikdngrPl28rI82dlbbxZQsjnLSsjm4="; subPkgs = "."; ldflags = "-s -w -X=main.version=0.3.19";
    check = chk ''"$out/bin/smug" --help'' "[-]-inside-current-session"; };
  # splash-cli (MIT): add color to your logs.
  splash-cli = pkg { pname = "splash-cli"; version = "0.9.5"; src = gh "joshi4/splash" "refs/tags/v0.9.5" "0b0e30ad4985e9a8079bd3a6f14b810cbeaa878e4c8d425f45b8a4c27e472b94";
    vendorHash = "sha256-EvgApcRjpn51rKSuXxbmj/P0/X6g8TwZSJNxI01kWcM="; subPkgs = "."; ldflags = "-s -X=github.com/joshi4/splash/cmd.version=0.9.5 -X=github.com/joshi4/splash/cmd.externalUpdate=nix";
    check = chk ''"$out/bin/splash" version'' "0\\.9\\.5"; };
  # sttr (MIT): cross-platform cli tool to perform various operations on string.
  sttr = pkg { pname = "sttr"; version = "0.2.30"; src = gh "abhimanyu003/sttr" "v0.2.30" "64c4ddd6f84c99f197053e96c489dea48c0bd83a33dfdd69ab209653bc38b9c8";
    vendorHash = "sha256-tQz/YIjzlfo9bhucoGAz4EWmayA/J8zY8Gp4HjmyNrI="; subPkgs = "."; ldflags = "-s -w -X=main.version=0.2.30";
    check = chk ''"$out/bin/sttr" version'' "0\\.2\\.30"; };
  # swego (GPL-2.0-only): simple Webserver.
  swego = pkg { pname = "swego"; version = "1.14"; src = gh "nodauf/Swego" "refs/tags/v1.14" "5aced7c116f6f84c8d643127db6b3b067ae1ad8c638c7e9efb30b8ebd07e04a6";
    vendorHash = "sha256-fEHvMWsjwJe5VTxf7uawGO6cm3xzTO5k+gM5u/m7xR8="; subPkgs = "./src"; ldflags = "-w -s";
    check = chk ''"$out/bin/src" --help'' "[Uu]sage"; };
  # terraform-docs (MIT): utility to generate documentation from Terraform modules in various output formats.
  terraform-docs = pkg { pname = "terraform-docs"; version = "0.24.0"; src = gh "terraform-docs/terraform-docs" "refs/tags/v0.24.0" "e3c971a1f2a02732d964e19e65c901b4e02cca62c4b748c05d22e9690d055540";
    vendorHash = "sha256-Z/rP9MvSO8YxMEVGyOKHymdvwVT0CW4+RFrk+tu2eR8="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/terraform-docs" --version'' "0\\.24\\.0"; };
  # topfew (GPL-3.0-only): finds the fields (or combinations of fields) which appear most often in a stream of records.
  topfew = pkg { pname = "topfew"; version = "2.0.0"; src = gh "timbray/topfew" "refs/tags/v2.0.0" "89b9abe7304eb6bb50cc5b3152783e50600439955f73b6175c6db8aec75c0ac9";
    vendorHash = null; subPkgs = "."; ldflags = "-s";
    check = chk ''"$out/bin/topfew" --help'' "[Uu]sage"; };
  # tt (MIT): typing test in the terminal written in Go.
  tt = pkg { pname = "tt"; version = "0.4.2"; src = gh "lemnos/tt" "v0.4.2" "3f22aad820e64f41f6635cfec66efce4d4c45e903465434a222c44e134eb4397";
    vendorHash = "sha256-lK/Yf+m0AaXcRfmWlYNdrV/ltBfvj/eBGRJRGZYGrE0="; subPkgs = "./src";
    check = chk ''"$out/bin/src" --help'' "[Uu]sage"; };
  # vultr-cli (Apache-2.0): official command line tool for Vultr services.
  vultr-cli = pkg { pname = "vultr-cli"; version = "3.11.0"; src = gh "vultr/vultr-cli" "v3.11.0" "e29be650393530c424ea301b6d39092d2daceaa8059a4096bcfa3bbd54828fe2";
    vendorHash = "sha256-ZIetgymqzqoOhpnvQgOdpXn354ncHQ27kYr9Ed6rd5s="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/vultr-cli" version'' "3\\.11\\.0"; };
  # wormhole-william (MIT): end-to-end encrypted file transfers.
  wormhole-william = pkg { pname = "wormhole-william"; version = "1.0.8"; src = gh "psanford/wormhole-william" "v1.0.8" "42490f3c7e383d7d410e68a83fc18de1a5e9373934a9d71064e10948197759d1";
    vendorHash = "sha256-9xfvK8cEd516cHYqd/yjBvJtATzFSQ0ITqAbvrr87fs="; subPkgs = ".";
    check = chk ''"$out/bin/wormhole-william" --version'' "1\\.0\\.8"; };
  # ytt (Apache-2.0): YAML templating tool that allows configuration of complex software via reusable templates with user-provided values.
  ytt = pkg { pname = "ytt"; version = "0.55.4"; src = gh "carvel-dev/ytt" "refs/tags/v0.55.4" "4a970198c479330c49019be4ccb56513a58623e1e10300d1d188f30e14935a61";
    vendorHash = null; subPkgs = "./cmd/ytt ./cmd/ytt-lambda-website"; ldflags = "-s -w -X carvel.dev/ytt/pkg/version.Version=0.55.4";
    check = chk ''"$out/bin/ytt" --version'' "0\\.55\\.4"; };
  # envsubst (MIT): environment variables substitution for Go.
  envsubst = pkg { pname = "envsubst"; version = "1.4.3"; src = gh "a8m/envsubst" "v1.4.3" "01ca48a2beaeeda5b9fbca9c46bb9e9acc0e55354761d90e4beba5ca1c97aa8b";
    vendorHash = null; subPkgs = "./cmd/envsubst";
    check = chk ''"$out/bin/envsubst" --help'' "[-]fail-fast"; };
  # brev-cli (MIT): connect your laptop to cloud computers.
  brev-cli = pkg { pname = "brev-cli"; version = "0.6.316"; src = gh "brevdev/brev-cli" "v0.6.316" "095452684cb08ffc3b94d1415c17ba9ef25f1355d4d3105645bdc6ad498e2278";
    vendorHash = "sha256-JK9ktJLJDtGU2r1YhHXqG7nlwnosJJjZxSxefM7kP0Q="; subPkgs = "."; ldflags = "-s -w -X github.com/brevdev/brev-cli/pkg/cmd/version.Version=v0.6.316";
    check = chk ''"$out/bin/brev-cli" --version'' "0\\.6\\.316"; };
  # butane (Apache-2.0): translates human-readable Butane configs into machine-readable Ignition configs.
  butane = pkg { pname = "butane"; version = "2.28.0"; src = gh "coreos/ignition" "v2.28.0" "a2ff1a2aafc1a54fedd535487c4b0cf2afad5945a788edfb85140420a1f772de";
    vendorHash = null; subPkgs = "./butane/internal"; ldflags = "-X github.com/coreos/ignition/v2/butane/internal/version.Raw=v2.28.0";
    check = chk ''"$out/bin/internal" --version'' "2\\.28\\.0"; };
  # cirrus-cli (MIT): CLI for executing Cirrus tasks locally and in any CI.
  cirrus-cli = pkg { pname = "cirrus-cli"; version = "1.0.0"; src = gh "cirruslabs/cirrus-cli" "v1.0.0" "24d9464daf591d45b6ca9ce987d669da3db2e81341893204d557c2242e1e75bc";
    vendorHash = "sha256-nlVUMNEjAzIdXDDxpxuF3V2atXfkjGL51o9LUeCyB8k="; subPkgs = "./cmd/cirrus"; ldflags = "-X github.com/cirruslabs/cirrus-cli/internal/version.Version=v1.0.0 -X github.com/cirruslabs/cirrus-cli/internal/version.Commit=v1.0.0";
    check = chk ''"$out/bin/cirrus" --version'' "1\\.0\\.0"; };
  # ctlptl (Apache-2.0): CLI for declaratively setting up local Kubernetes clusters.
  ctlptl = pkg { pname = "ctlptl"; version = "0.9.6"; src = gh "tilt-dev/ctlptl" "v0.9.6" "51af2008cf435a808cb297c9564fe94a4207da541871739bde5062a2a8ede933";
    vendorHash = "sha256-LzQ42NOGAe8xpyk37DS0yf3Qehx1krkU6AXexm3iDKI="; subPkgs = "./cmd/ctlptl"; ldflags = "-s -w -X main.version=0.9.6";
    check = chk ''"$out/bin/ctlptl" version'' "0\\.9\\.6"; };
  # driftctl (Apache-2.0): detect, track and alert on infrastructure drift.
  driftctl = pkg { pname = "driftctl"; version = "0.40.0"; src = gh "snyk/driftctl" "v0.40.0" "30781d35092dd1dd1b34f22e63e3130a062cf4a3f511f61be013a0ff2a0c7767";
    vendorHash = "sha256-8SBsEHW74N3jR6wcJSGPJY8gdUHTu1ZrSfJgju01B8g="; subPkgs = "."; ldflags = "-s -w -X github.com/snyk/driftctl/pkg/version.version=v0.40.0 -X github.com/snyk/driftctl/build.env=release -X github.com/snyk/driftctl/build.enableUsageReporting=false";
    check = chk ''"$out/bin/driftctl" version'' "0\\.40\\.0"; };
  # fission (Apache-2.0): cli used by end user to interact Fission.
  fission = pkg { pname = "fission"; version = "1.27.0"; src = gh "fission/fission" "v1.27.0" "3e9be3fdbf7b8db8fbcf629e12260b30005a0c022f33a0d19b660ea59fc7f6bf";
    vendorHash = "sha256-hoLf8Kpx4jr9W5D+KvLrH8uKHoW39bNQzYqCEA+hXio="; subPkgs = "./cmd/fission-cli"; ldflags = "-s -w -X info.Version=1.27.0";
    check = chk ''"$out/bin/fission-cli" --help'' "Fission: Fast and Simple Serverless Func"; };
  # fluxcd-operator (AGPL-3.0-only): kubernetes controller for managing the lifecycle of Flux CD.
  fluxcd-operator = pkg { pname = "fluxcd-operator"; version = "0.58.1"; src = gh "controlplaneio-fluxcd/flux-operator" "refs/tags/v0.58.1" "8ecbaf050e63c26dc38702955425d03d3725d2b45f08e5506e8d24202be9c459";
    vendorHash = "sha256-3X4QMUIgvsTUq3HWlZjdAtqYx/lNYpk7Pb9ISP8HQes="; subPkgs = "./cmd/cli"; ldflags = "-s -w -X main.VERSION=0.58.1";
    check = chk ''"$out/bin/cli" --version'' "0\\.58\\.1"; };
  # fluxcd-operator-mcp (AGPL-3.0-only): kubernetes controller for managing the lifecycle of Flux CD.
  fluxcd-operator-mcp = pkg { pname = "fluxcd-operator-mcp"; version = "0.58.1"; src = gh "controlplaneio-fluxcd/flux-operator" "refs/tags/v0.58.1" "8ecbaf050e63c26dc38702955425d03d3725d2b45f08e5506e8d24202be9c459";
    vendorHash = "sha256-3X4QMUIgvsTUq3HWlZjdAtqYx/lNYpk7Pb9ISP8HQes="; subPkgs = "./cmd/mcp"; ldflags = "-s -w -X main.VERSION=0.58.1";
    check = chk ''"$out/bin/mcp" --version'' "0\\.58\\.1"; };
  # gatekeeper (Apache-2.0): policy Controller for Kubernetes.
  gatekeeper = pkg { pname = "gatekeeper"; version = "3.23.1"; src = gh "open-policy-agent/gatekeeper" "refs/tags/v3.23.1" "8d49585365c26e809754850b4119b0f97eaba608071b1c99bc3e68b41038272e";
    vendorHash = "sha256-/cxQGuLC4LRpcg1EtbmTZdTe8rtvYL2D0QXQ3iM9blo="; subPkgs = "./cmd/gator"; ldflags = "-X github.com/open-policy-agent/gatekeeper/v3/pkg/version.Version=3.23.1";
    check = chk ''"$out/bin/gator" --version'' "3\\.23\\.1"; };
  # gcx (Apache-2.0): grafana Cloud CLI.
  gcx = pkg { goPkgs = go_1_27; pname = "gcx"; version = "1.7.1"; src = gh "grafana/gcx" "refs/tags/v1.7.1" "9b5ec00327d457f0acba20c301e94d2e1085448da60b500d58dd9a8d415a18c8";
    vendorHash = "sha256-8cOW2+d5LCy5cZi3a3pW8VMOBJNglbmqmVdXRozZ2vc="; subPkgs = "./cmd/gcx"; ldflags = "-w -X=main.version=1.7.1 -X=main.commit=refs/tags/v1.7.1 -X=main.date=1970-01-01T00:00:00Z";
    check = chk ''"$out/bin/gcx" --version'' "1\\.7\\.1"; };
  # grafana-dashboard-linter (Apache-2.0): linter for Grafana dashboards.
  grafana-dashboard-linter = pkg { pname = "grafana-dashboard-linter"; version = "0.3.0"; src = gh "grafana/dashboard-linter" "refs/tags/v0.3.0" "50a2bb09217c55233581de9cf8bf1d5e29114e4e4b2bcb2a6425f5248e844d61";
    vendorHash = "sha256-m1bQwtOi/Ur9MVS9a8bR9iJ0gZ+76Jy5OEf+lpn1ydQ="; subPkgs = "."; ldflags = "-s";
    check = chk ''"$out/bin/dashboard-linter" --help'' "[Uu]sage"; };
  # harbor-cli (Apache-2.0): command-line tool facilitates seamless interaction with the Harbor container registry.
  harbor-cli = pkg { pname = "harbor-cli"; version = "0.0.27"; src = gh "goharbor/harbor-cli" "refs/tags/v0.0.27" "b8661164e532471e1cfcd74d5447c69648924a501a628a8b8322c4facaefb17b";
    vendorHash = "sha256-wawC5/qHFcoPRNF+jNzZx1oPqdAN0pd9FQkNCisuTjE="; subPkgs = "./cmd/harbor"; ldflags = "-s -X github.com/goharbor/harbor-cli/cmd/harbor/internal/version.Version=0.0.27";
    check = chk ''"$out/bin/harbor" --help'' "[Uu]sage"; };
  # hcloud (MIT): command-line interface for Hetzner Cloud, a provider for cloud virtual private servers.
  hcloud = pkg { pname = "hcloud"; version = "1.70.0"; src = gh "hetznercloud/cli" "refs/tags/v1.70.0" "022a610f22da8bb0f1206a23cbc5f62e1f1553fb52747388ad5624dc9ec37333";
    vendorHash = "sha256-lm5aJ1lfTJeVxv9zMX/e9RdBlpN8xO5voc/Y/wNUl7w="; subPkgs = "./cmd/hcloud"; ldflags = "-s -w -X=github.com/hetznercloud/cli/internal/version.Version=1.70.0";
    check = chk ''"$out/bin/hcloud" version'' "1\\.70\\.0"; };
  # istioctl (Apache-2.0): istio configuration command line utility for service operators to debug and diagnose their Istio mesh.
  istioctl = pkg { pname = "istioctl"; version = "1.31.3"; src = gh "istio/istio" "1.31.3" "aa1380bf3d59061c85c7704f1fb6c11cb922ea41131b6def42f9b6a9a7670eea";
    vendorHash = "sha256-SNcI2+rM8PJlo/bpYFmgO69/cRoQk1PjfXEGVHmvV1s="; subPkgs = "./istioctl/cmd/istioctl"; ldflags = "-s -w -X istio.io/istio/pkg/version.buildVersion=1.31.3 -X istio.io/istio/pkg/version.buildStatus=Nix -X istio.io/istio/pkg/version.buildTag=1.31.3 -X istio.io/istio/pkg/version.buildHub=docker.io/istio";
    check = chk ''"$out/bin/istioctl" --help'' "[Uu]sage"; };
  # konstraint (MIT): policy management tool for interacting with Gatekeeper.
  konstraint = pkg { pname = "konstraint"; version = "0.43.0"; src = gh "plexsystems/konstraint" "v0.43.0" "4e936f6fb84b32a5f95a76fcc368a113e8077275cee8f41adbbcb14a722187b2";
    vendorHash = "sha256-ZTiVrtn1UH2Awm7dtxqfTOIXBOT4Wv2g2J4LwJnHMug="; subPkgs = "."; ldflags = "-s -w -X github.com/plexsystems/konstraint/internal/commands.version=0.43.0";
    check = chk ''"$out/bin/konstraint" --version'' "0\\.43\\.0"; };
  # kubecfg (Apache-2.0): tool for managing Kubernetes resources as code.
  kubecfg = pkg { pname = "kubecfg"; version = "0.38.0"; src = gh "kubecfg/kubecfg" "v0.38.0" "367e06009a58a32e8c1be81f4b8433ad104d3fab23b835fe61e80ac3b1d99455";
    vendorHash = "sha256-BpVZ+MnfOald8DsewmBTkn4PU4t0XYDlcouKRwZ+s74="; subPkgs = "."; ldflags = "-s -w -X main.version=v0.38.0";
    check = chk ''"$out/bin/kubecfg" version'' "0\\.38\\.0"; };
  # kubectl-ai (Apache-2.0): AI powered Kubernetes Assistant.
  kubectl-ai = pkg { pname = "kubectl-ai"; version = "0.0.26"; src = gh "GoogleCloudPlatform/kubectl-ai" "refs/tags/v0.0.26" "fc1a31aca351f3f29859580f8167701e613ced5047ee2072b2d0e04b65be6027";
    vendorHash = "sha256-iIgkZPBB/EhdDjIug/ZMq9E2f8jKcR1AqXECy9pOzrE="; subPkgs = "./cmd"; ldflags = "-s -w -X main.version=0.0.26";
    check = chk ''"$out/bin/cmd" version'' "0\\.0\\.26"; };
  # kubectl-rook-ceph (Apache-2.0): krew plugin to run kubectl commands with rook-ceph.
  kubectl-rook-ceph = pkg { pname = "kubectl-rook-ceph"; version = "0.9.6"; src = gh "rook/kubectl-rook-ceph" "refs/tags/v0.9.6" "5e580a42f1fda40a0ec4db0af24bc09f2ec0fcb02393ffb6ba2d7b08ea5c99e2";
    vendorHash = "sha256-jBAZrDg8J/z0m+rYmXg+hkl+xQxvgGqqqxNwofPUEw4="; subPkgs = "./cmd";
    check = chk ''"$out/bin/cmd" --help'' "[Uu]sage"; };
  # kyverno-chainsaw (Apache-2.0): declarative approach to test Kubernetes operators and controllers.
  kyverno-chainsaw = pkg { pname = "kyverno-chainsaw"; version = "0.2.15"; src = gh "kyverno/chainsaw" "refs/tags/v0.2.15" "04f3fc7dd8e958e4fc7d73383bc22b05827240dd2fe7a8e32ee99d8c0332da2a";
    vendorHash = "sha256-tEl09UfxkfBkKGaVPJlnqb1UsgBFj8luP7JGM6rGVXk="; subPkgs = "."; ldflags = "-s -w -X github.com/kyverno/chainsaw/pkg/version.BuildVersion=v0.2.15";
    check = chk ''"$out/bin/chainsaw" version'' "0\\.2\\.15"; };
  # onmetal-image (Apache-2.0): onmetal OCI Image Specification, Library and Tooling.
  onmetal-image = pkg { pname = "onmetal-image"; version = "0.1.1"; src = gh "onmetal/onmetal-image" "v0.1.1" "51ec2bbf747c016177ad7d8f3c2c9fbe62833754278e4763f510c763974f0911";
    vendorHash = "sha256-naXpuKjSXAIu/qykk/HuMa1NjeAu6IFsgSZT0smogQg="; subPkgs = "./cmd";
    check = chk ''"$out/bin/cmd" --help'' "[-]-docker-config-path"; };
  # openfga-cli (Apache-2.0): cross-platform CLI to interact with an OpenFGA server.
  openfga-cli = pkg { pname = "openfga-cli"; version = "0.8.2"; src = gh "openfga/cli" "v0.8.2" "03927ed2b878e98f3239603ec0bc0b1c1bcc50a6372dcf2f5c471d135dbacf05";
    vendorHash = "sha256-pnaPy4yv4SEPe2/aqWA33xHIF6NQMIIEcHadrpHG/u8="; subPkgs = "./cmd/fga"; ldflags = "-s -w -X github.com/openfga/cli/internal/build.Version=0.8.2 -X github.com/openfga/cli/internal/build.Commit=0.8.2 -X github.com/openfga/cli/internal/build.Date=19700101";
    check = chk ''"$out/bin/fga" --version'' "0\\.8\\.2"; };
  # popeye (Apache-2.0): kubernetes cluster resource sanitizer.
  popeye = pkg { pname = "popeye"; version = "0.22.1"; src = gh "derailed/popeye" "v0.22.1" "f8eef3d6b9cda24f4d9bdc24620c1368cd6a749f1321a499e88b339258e01d92";
    vendorHash = "sha256-u5UwJmWtiYuyZavrWCugl26chAwRmq5m5Cxn6D3nbiQ="; subPkgs = "."; ldflags = "-s -w -X github.com/derailed/popeye/cmd.version=0.22.1 -X github.com/derailed/popeye/cmd.commit=0.22.1";
    check = chk ''"$out/bin/popeye" version'' "0\\.22\\.1"; };
  # promql-cli (Apache-2.0): command-line tool to query a Prometheus server with PromQL and visualize the output.
  promql-cli = pkg { pname = "promql-cli"; version = "0.3.0"; src = gh "nalbury/promql-cli" "v0.3.0" "0c25f86dfba38ffb932959b57b2b88fbd3f0a111116d2cf18288b5b1c4a7d151";
    vendorHash = "sha256-9rPIGhokd1jEIzkldaAf/w7U9UYicDqrvV8pGIhitzA="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/promql-cli" --help'' "[-]-auth-credentials-file"; };
  # proxyt (MIT): simple proxy for the Tailscale control plane.
  proxyt = pkg { pname = "proxyt"; version = "0.0.7"; src = gh "jaxxstorm/proxyt" "refs/tags/v0.0.7" "8803d01e5731c2c2bc7c95c32f7e89ed2a07b9ace2cddd8db2d87d24d05d42ee";
    vendorHash = "sha256-jzQOSXhx3apLPASExTnj6jT9z3aXkqI7CfLHV1dM4PQ="; subPkgs = "."; ldflags = "-s -w -X=github.com/jaxxstorm/proxyt/cmd.Version=0.0.7";
    check = chk ''"$out/bin/proxyt" --version'' "0\\.0\\.7"; };
  # pv-migrate (AFL-2.0): CLI tool to easily migrate Kubernetes persistent volumes.
  pv-migrate = pkg { pname = "pv-migrate"; version = "3.6.1"; src = gh "utkuozdemir/pv-migrate" "refs/tags/v3.6.1" "23c6811740ccb3135151e3083bd5500f336161d0a70e76c68d8b9f87d85d071a";
    vendorHash = "sha256-bYcNX3cYvOVDt2nh6S/GVgowabZPISY7Fk2996DlZTg="; subPkgs = "./cmd/pv-migrate"; ldflags = "-s -w -X main.version=3.6.1 -X main.commit=3.6.1 -X main.date=1970-01-01-00:00:01";
    check = chk ''"$out/bin/pv-migrate" --version'' "3\\.6\\.1"; };
  # rancher (Apache-2.0): CLI tool for interacting with your Rancher Server.
  rancher = pkg { pname = "rancher"; version = "2.15.3"; src = gh "rancher/cli" "refs/tags/v2.15.3" "c9ea33994de4c4600a403fd6c90545d3481b60fe4e5e96318dbc28c40faa7c68";
    vendorHash = "sha256-ruWlBe10Rn7PX/SW/1QStGxoGeEO5MlcYWzgalb6Cdk="; subPkgs = "."; ldflags = "-w -s -X main.VERSION=2.15.3 -extldflags -static";
    check = chk ''"$out/bin/cli" --version'' "2\\.15\\.3"; };
  # readium (BSD-3-Clause): CLI utility with support for a wide range of commands for ebooks, comics and audiobooks.
  readium = pkg { pname = "readium"; version = "0.10.1"; src = gh "readium/cli" "refs/tags/v0.10.1" "6ef3d7bbfe533b5b2a69da9babf0bef11f4fc26f17798941481737166bb822c9";
    vendorHash = "sha256-oumpZvlR/RM3S/AbYWzPkEx6hQtuXDoRG+htkoKxRNU="; subPkgs = "./cmd"; ldflags = "-X=github.com/readium/cli/internal/version.Version=v0.10.1";
    check = chk ''"$out/bin/cmd" --version'' "0\\.10\\.1"; };
  # spicedb (Apache-2.0): open source permission database.
  spicedb = pkg { goPkgs = go_1_27; pname = "spicedb"; version = "1.57.0"; src = gh "authzed/spicedb" "refs/tags/v1.57.0" "d9ef895cd0544ac43af5773d68d08c8e7c6bc02ac4fd21357e037715824759df";
    vendorHash = "sha256-JL+qlRpCE0tTs6c1TRcrc7LL2eXlvo52Ow7K3TcRnec="; subPkgs = "./cmd/spicedb"; ldflags = "-X 'github.com/jzelinskie/cobrautil/v2.Version=v1.57.0'";
    check = chk ''"$out/bin/spicedb" version'' "1\\.57\\.0"; };
  # totp-cli (MIT): authy/Google Authenticator like TOTP CLI tool written in Go.
  totp-cli = pkg { pname = "totp-cli"; version = "1.9.2"; src = gh "yitsushi/totp-cli" "refs/tags/v1.9.2" "c8b87c7854f373423dba2f8c6167c2836b6ae1f66b29b1becb505c277a00c54f";
    vendorHash = "sha256-B2Qn6ZAGlJ1dG4KiAPC+G+AzrwfugnISVbdjwhjiBr8="; subPkgs = ".";
    check = chk ''"$out/bin/totp-cli" --help'' "totp-cli - Authy/Google Authenticator li"; };
  # uplosi (Apache-2.0): upload OS images to cloud provider.
  uplosi = pkg { pname = "uplosi"; version = "0.4.0"; src = gh "edgelesssys/uplosi" "refs/tags/v0.4.0" "c3edfb08f1198e110c1ed08d19fc02b8abb9849088b503d486d7a557a5ba6af5";
    vendorHash = "sha256-Ne2qgWQaV9ED0IWX9TNVzsVDhK8iyJ5uklkzQKbX5q0="; subPkgs = "."; ldflags = "-s -X main.version=0.4.0";
    check = chk ''"$out/bin/uplosi" --version'' "0\\.4\\.0"; };
  # usque (MIT): open-source reimplementation of the Cloudflare WARP client's MASQUE protocol.
  usque = pkg { pname = "usque"; version = "4.2.1"; src = gh "Diniboy1123/usque" "refs/tags/v4.2.1" "cd0e9c89353915cb74a0877ab6fc68ee158adf8724ef9aab878a4d90edcb1d72";
    vendorHash = "sha256-Ti4hhkaiHiHmyZfgT0fitVndcoT/0IjNBr/S4U7QQDE="; subPkgs = "."; ldflags = "-s -w -X github.com/Diniboy1123/usque/cmd.version=4.2.1";
    check = chk ''"$out/bin/usque" version'' "4\\.2\\.1"; };
  # witness (Apache-2.0): pluggable framework for software supply chain security. Witness prevents tampering of build materials and verifies the integrity of the build process from source to target.
  witness = pkg { pname = "witness"; version = "0.12.0"; src = gh "in-toto/witness" "refs/tags/v0.12.0" "76c571202fda4a586da857322ec2a0ac8a96659ace455902bbd75e4b62c785ea";
    vendorHash = "sha256-ouREYN908QAffm0aFNL+yyVjxspbbcnYNDS6J41fRoE="; subPkgs = "."; ldflags = "-s -w -X github.com/in-toto/witness/cmd.Version=v0.12.0";
    check = chk ''"$out/bin/witness" version'' "0\\.12\\.0"; };
  # changelogger (MIT): tool to manage your changelog file in Markdown.
  changelogger = pkg { pname = "changelogger"; version = "0.7.0"; src = gh "MarkusFreitag/changelogger" "refs/tags/v0.7.0" "b2464c84ee3431666a98ecf0003423ceb8279727d0c66c446997d077a2aa5f35";
    vendorHash = "sha256-pYYRTcufYQsGqRD3dEDWtSnEaQSbLdE9vz+LReUOtJ8="; subPkgs = "."; ldflags = "-s -w -X github.com/MarkusFreitag/changelogger/cmd.BuildVersion=0.7.0 -X github.com/MarkusFreitag/changelogger/cmd.BuildDate=1970-01-01T00:00:00";
    prep = ''
      ${fix} vendor/gopkg.in/AlecAivazis/survey.v1/terminal/runereader_posix.go terminal ${termios}
    '';
    check = chk ''"$out/bin/changelogger" version'' "0\\.7\\.0"; };
  # dive (MIT): tool for exploring each layer in a docker image.
  dive = pkg { pname = "dive"; version = "0.13.1"; src = gh "wagoodman/dive" "v0.13.1" "2a9666e9c3fddd5e2e5bad81dccda520b8102e7cea34e2888f264b4eb0506852";
    vendorHash = "sha256-N++2yWc7wrdqKprve2cRw/8pfdYX04x8y576dM+J0lY="; subPkgs = "."; ldflags = "-s -w -X main.version=0.13.1";
    prep = ''
      ${fix} vendor/github.com/awesome-gocui/gocui/gui_others.go gocui
    '';
    check = chk ''"$out/bin/dive" --version'' "0\\.13\\.1"; };
  # arkade (MIT): open Source Kubernetes Marketplace.
  arkade = pkg { pname = "arkade"; version = "0.11.116"; src = gh "alexellis/arkade" "refs/tags/0.11.116" "39ec737fe61f008e85ec34268116bfb68fa3f5018afad55be499081fd6fe54f3";
    vendorHash = null; subPkgs = "."; ldflags = "-s -w -X github.com/alexellis/arkade/pkg.GitCommit=ref/tags/0.11.116 -X github.com/alexellis/arkade/pkg.Version=0.11.116";
    check = chk ''"$out/bin/arkade" version'' "0\\.11\\.116"; };
  # wrtag (GPL-3.0-only): fast automated music tagging and organization based on MusicBrainz.
  wrtag = pkg { pname = "wrtag"; version = "0.33.0"; src = gh "sentriz/wrtag" "refs/tags/v0.33.0" "ac795072fd83dc609e2bd438d1cee175dbdfe89f7a699e214de3d3355e26140e";
    vendorHash = "sha256-1VKwj5Gr0BoVp6faCHQh3IDVSDbs2kMxc5LPG2COi9M="; subPkgs = "./cmd/metadata ./cmd/wrtag ./cmd/wrtagweb";
    check = chk ''"$out/bin/wrtag" --version'' "0\\.33\\.0"; };
  # gocode-gomod (MIT): autocompletion daemon for the Go programming language.
  gocode-gomod = pkg { pname = "gocode-gomod"; version = "1.0.0"; src = gh "stamblerre/gocode" "v1.0.0" "cf9d9c1e76b3e4d970e7bb848a508e1642506db4e9829dc1f04d6081717a418e";
    vendorHash = null; subPkgs = ".";
    check = chk ''"$out/bin/gocode" --help'' "[-]fallback-to-source"; };
  # algolia-cli (MIT): algolia’s official CLI devtool.
  algolia-cli = pkg { pname = "algolia-cli"; version = "1.18.0"; src = gh "algolia/cli" "refs/tags/v1.18.0" "aaf4870c8b64e4c3a3fbbd3a6650424924e5dac2b3a9900ce7b96f89905a751b";
    vendorHash = "sha256-k5+QU+cclzk3b9ts942OsWVglL3HkfPYCAnfwLSKuDM="; subPkgs = "./cmd/algolia"; ldflags = "-s -w -X github.com/algolia/cli/pkg/version.Version=1.18.0";
    prep = ''
      ${fix} vendor/github.com/AlecAivazis/survey/v2/terminal/runereader_posix.go terminal ${termios}
    '';
    check = chk ''"$out/bin/algolia" --version'' "1\\.18\\.0"; };
  # jcli (MIT): jenkins CLI allows you to manage your Jenkins in an easy way.
  jcli = pkg { pname = "jcli"; version = "0.0.47"; src = gh "jenkins-zh/jenkins-cli" "refs/tags/v0.0.47" "4e78600e214c357c08a0a83fe9cc59214b0d050de07dbb469d9f226c8c37eabc";
    vendorHash = "sha256-4zTUjklupc+kKSdsIejE/i0gbgCoXR+wRlFniNwVuxs="; subPkgs = "."; ldflags = "-s -w -X github.com/linuxsuren/cobra-extension/version.version=0.0.47";
    prep = ''
      ${fix} vendor/github.com/AlecAivazis/survey/v2/terminal/runereader_posix.go terminal ${termios}
    '';
    check = chk ''"$out/bin/jenkins-cli" version'' "0\\.0\\.47"; };
  # leetgo (MIT): command-line tool for LeetCode.
  leetgo = pkg { pname = "leetgo"; version = "1.4.19"; src = gh "j178/leetgo" "v1.4.19" "39537b3d2e221c5cec3826c845711903223fb878e93f81a1b452d814c806c819";
    vendorHash = "sha256-eLxNbeXG8uAafrUuyZa46qw7g9dM+96SQe7+ZzWBIUQ="; subPkgs = "."; ldflags = "-s -w -X=github.com/j178/leetgo/constants.Version=1.4.19";
    prep = ''
      ${fix} vendor/github.com/AlecAivazis/survey/v2/terminal/runereader_posix.go terminal ${termios}
    '';
    check = chk ''"$out/bin/leetgo" --version'' "1\\.4\\.19"; };
  # mongodb-cli (Apache-2.0): manage your MongoDB via ops manager and cloud manager.
  mongodb-cli = pkg { pname = "mongodb-cli"; version = "2.0.9"; src = gh "mongodb/mongodb-cli" "refs/tags/mongocli/v2.0.9" "87ec0735839eba17d68d8690d3749144f9ad1eab2614a5861c41befe79f03cde";
    vendorHash = "sha256-ug9p+17bMnDaNkJWsMjAp20J5XAET6QhPxrp/Fp+G64="; subPkgs = "./cmd/mongocli";
    prep = ''
      ${fix} vendor/github.com/AlecAivazis/survey/v2/terminal/runereader_posix.go terminal ${termios}
    '';
    check = chk ''"$out/bin/mongocli" --help'' "[Uu]sage"; };
  # tektoncd-cli-pac (Apache-2.0): CLI for interacting with Tekton Pipelines as Code.
  tektoncd-cli-pac = pkg { pname = "tektoncd-cli-pac"; version = "0.41.1"; src = gh "tektoncd/pipelines-as-code" "refs/tags/v0.41.1" "22d88cbc59272bd1dca26dc14ba7e30570dffe9cfa69393386985a1ee6724d49";
    vendorHash = null; subPkgs = "./cmd/tkn-pac"; ldflags = "-s -w -X github.com/openshift-pipelines/pipelines-as-code/pkg/params/version.Version=0.41.1";
    prep = ''
      ${fix} vendor/github.com/AlecAivazis/survey/v2/terminal/runereader_posix.go terminal ${termios}
    '';
    check = chk ''"$out/bin/tkn-pac" version'' "0\\.41\\.1"; };
  # glooctl (Apache-2.0): unified CLI for Gloo, the feature-rich, Kubernetes-native, next-generation API gateway built on Envoy.
  glooctl = pkg { pname = "glooctl"; version = "1.22.0"; src = gh "solo-io/gloo" "v1.22.0" "22249bc9b0caa7316f899eb8ced5723b38c2028cdf833d5152348641100c7581";
    vendorHash = "sha256-XWmFT0jFllGBk4EqUA8bODY3JNdhPV7w3uCs5HyUqLA="; subPkgs = "./projects/gloo/cli/cmd"; ldflags = "-s -X github.com/solo-io/gloo/pkg/version.Version=1.22.0";
    prep = ''
      ${fix} vendor/gopkg.in/AlecAivazis/survey.v1/terminal/runereader_posix.go terminal ${termios}
    '';
    check = chk ''"$out/bin/cmd" version'' "1\\.22\\.0"; };
  # transifex-cli (Apache-2.0): transifex command-line client.
  transifex-cli = pkg { pname = "transifex-cli"; version = "1.6.17"; src = gh "transifex/cli" "v1.6.17" "759320acd621991046533089bb77320202853cc97b860ab7783040d0e4d5e34f";
    vendorHash = "sha256-BCXs9MZNcfDVE//7RQlIpIfM2aZpv4qZdgx3sv9w6f8="; subPkgs = "."; ldflags = "-s -w -X 'github.com/transifex/cli/internal/txlib.Version=1.6.17'";
    prep = ''
      ${fix} vendor/github.com/gosuri/uilive/terminal_size.go uilive
      sed -i "s/int(fd), int(req)/int(fd), uint(req)/" vendor/github.com/gosuri/uilive/zz_hlcli_ioctl_illumos.go   # this x/sys/unix takes req uint
    '';
    check = chk ''"$out/bin/cli" --version'' "1\\.6\\.17"; };
  # lf (MIT): terminal file manager written in Go and heavily inspired by ranger.
  lf = pkg { pname = "lf"; version = "42"; src = gh "gokcehan/lf" "refs/tags/r42" "7a8f7c2c86419270b713b6235dced7b9d0e68732e74a1e0f375f774fff4023ca";
    vendorHash = "sha256-K7jtAJgvd5p5FWbF9aAjP6PFweUzCQ3Sn4ZhS2Ze130="; subPkgs = "."; ldflags = "-s -w -X main.gVersion=r42";
    check = chk ''"$out/bin/lf" --version'' "42"; };
}
