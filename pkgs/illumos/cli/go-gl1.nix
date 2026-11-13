# cli/go-gl1.nix -- Go leaves the x86 build queue has jobs for (lane gl1, 2026-11-13): nixpkgs f4a03c0 by-name attrs that miss only
# buildGoModule, on goPkg storeOnly (../go-pkg-build.sh: store tools + the world on PATH, path-gated), as go-recipes3.nix. pname and
# version are the queue job's; ldflags and subPackages nixpkgs'. Each source is pinned by sha256 and its vendor dir by its NAR hash
# (our go mod vendor fixed-output build, measured on the gl1 host; nixpkgs' vendorHash is for its own fetcher). Statically linked (CGO=0).
{ goPkg, go_1_27, chk }:
let
  gh = repo: ref: sha256: { url = "https://codeload.github.com/${repo}/tar.gz/${ref}"; inherit sha256; };
  pkg = a: goPkg ({ storeOnly = true; } // a);
in {
  # entropy (MIT): tool to scan your codebase for high entropy lines, which are often secrets.
  entropy = pkg { pname = "entropy"; version = "1.0.7"; src = gh "EwenQuim/entropy" "v1.0.7" "2df45521ee65c6fe826490c43352a1a8721453cee46d201e7acafacddcc3a2b3";
    vendorHash = "sha256-4RQwopKbcp8BH1X8MSGzmwblek6+u253n5MFKGIZL2A="; subPkgs = ".";
    check = chk ''"$out/bin/entropy" --help'' "[-]ignore-ext-no-defaults"; };
  # act3 (MIT): glance at the last 3 runs of your GitHub Actions workflows.
  act3 = pkg { pname = "act3"; version = "2.0.0"; src = gh "dhth/act3" "refs/tags/v2.0.0" "5ba04d59ba44e659a0a23eee674923acd92c4bfd622e12bcf8bd993468699fe9";
    vendorHash = "sha256-uxIOysXMAb7psJpRBve1Cr9X0a2hG0TpCrLc/lk9/70="; subPkgs = ".";
    check = chk ''"$out/bin/act3" --help'' "[-]-workflow-name-filter"; };
  # addchain (BSD-3-Clause): addchain generates short addition chains for exponents of cryptographic interest with results rivaling the best hand-optimized chains.
  addchain = pkg { pname = "addchain"; version = "0.4.0"; src = gh "mmcloughlin/addchain" "refs/tags/v0.4.0" "f4dc377a3a11abfd8529f705855a5d9094985eda9c944bf0503aa17fa258c7f3";
    vendorHash = "sha256-hVu7Xw9k94sxEInSHgHNxr13PoOrmTa5EOjpf+eGZBQ="; subPkgs = "./cmd/addchain"; ldflags = "-s -w -X github.com/mmcloughlin/addchain/meta.buildversion=0.4.0";
    check = chk ''"$out/bin/addchain" version'' "0\\.4\\.0"; };
  # age-plugin-sss (MIT): age plugin to split keys and wrap them with different recipients using Shamir's Secret Sharing.
  age-plugin-sss = pkg { pname = "age-plugin-sss"; version = "0.4.0"; src = gh "olastor/age-plugin-sss" "refs/tags/v0.4.0" "8340b9d2e1c9d31c6d37e266beb2a231a37e75557419b9b41dc48231bbb2b09e";
    vendorHash = "sha256-/Hi27UVcVqgcDt5eo6zYjlJD3IzlzYmv/b0V61k17s0="; subPkgs = "./cmd/age-plugin-sss"; ldflags = "-s -w -X main.version=v0.4.0";
    check = chk ''"$out/bin/age-plugin-sss" --help'' "[-]-generate-recipient"; };
  # agebox (Apache-2.0): age based repository file encryption gitops tool.
  agebox = pkg { pname = "agebox"; version = "0.8.0"; src = gh "slok/agebox" "refs/tags/v0.8.0" "35284710da7874452f4107ca0dd7c8b0dd1ae337f63ddc0677fb7ce84777f5a9";
    vendorHash = "sha256-yrRSCSMYFgO481g4H/K/FkvlEwUWLMuYDLRqvnUwsic="; subPkgs = "./cmd/agebox"; ldflags = "-s -X main.Version=0.8.0";
    check = chk ''"$out/bin/agebox" --version'' "0\\.8\\.0"; };
  # ahoy (MIT): create self-documenting cli programs from YAML files.
  ahoy = pkg { pname = "ahoy"; version = "3.0.2"; src = gh "ahoy-cli/ahoy" "refs/tags/v3.0.2" "28a4a005126c797411b269fd873cb9c8c3a15eb47cdc63608be0d904fb9c4f23";
    vendorHash = null; subPkgs = "."; ldflags = "-X main.version=3.0.2";
    check = chk ''"$out/bin/ahoy" --version'' "3\\.0\\.2"; };
  # ain (MIT): HTTP API client for the terminal.
  ain = pkg { pname = "ain"; version = "1.6.0"; src = gh "jonaslu/ain" "refs/tags/v1.6.0" "a60ce846edc6f8e5429c3cf14faf57f170b757c6ab13d8f36d64235a1959e6c8";
    vendorHash = "sha256-LtA0yZP0Y5/zbQ6iFgNKfgRqavhDmVsk58WCKIZwFsk="; subPkgs = "./cmd/ain"; ldflags = "-s -w -X=main.gitSha=v1.6.0";
    check = chk ''"$out/bin/ain" -h'' "[Uu]sage"; };
  # albedo (Apache-2.0): HTTP reflector and black hole.
  albedo = pkg { pname = "albedo"; version = "0.3.0"; src = gh "coreruleset/albedo" "refs/tags/v0.3.0" "c4825b79b93cf898322b728667753465d5e44c01c6aedc5dd08861d8d826d626";
    vendorHash = "sha256-wFOh7jDN5OGyjrGJdW3X82vVP6Vatqet0NjRKL3XT4A="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/albedo" --help'' "[Uu]sage"; };
  # alertmanager-irc-relay (Apache-2.0): alertmanager IRC Relay is a bot relaying Prometheus alerts to IRC.
  alertmanager-irc-relay = pkg { pname = "alertmanager-irc-relay"; version = "0.5.1"; src = gh "google/alertmanager-irc-relay" "refs/tags/v0.5.1" "0cad8aa841d67950d91a381efceec471766b1ea24ef8819ab34902ede9c31ff4";
    vendorHash = "sha256-VbZcGMJdW25CX8H6OX1q95D0jFjac7W3VYpofoI3OBw="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/alertmanager-irc-relay" --help'' "[Uu]sage"; };
  # archimede (Apache-2.0): unobtrusive directory information fetcher.
  archimede = pkg { pname = "archimede"; version = "0.0.2"; src = gh "gennaro-tedesco/archimede" "refs/tags/v0.0.2" "1282620123398538b67d3fc5fc6b34a45e0a9722ecc4af089c086bb161218167";
    vendorHash = "sha256-Z7vsV1OIIlLVm7+4K2vfU26gHVB7+Q96/o4Ohe0AhG8="; subPkgs = ".";
    check = chk ''"$out/bin/archimede" version'' "0\\.0\\.2"; };
  # assign-lb-ip (Apache-2.0): assigns loadBalancerIP address to a Kubernetes service for testing purposes.
  assign-lb-ip = pkg { pname = "assign-lb-ip"; version = "2.3.1"; src = gh "Nordix/assign-lb-ip" "refs/tags/v2.3.1" "1892b31d1c5165a490917520a99e57fdf01b615ad99bab022a33c68e35240624";
    vendorHash = "sha256-qxoevvGKGqKveltY+sVoWGbYWOZo0EGgyYpPqW2SO0E="; subPkgs = "./cmd/assign-lb-ip";
    check = chk ''"$out/bin/assign-lb-ip" --help'' "[Uu]sage"; };
  # authz0 (MIT): automated authorization test tool.
  authz0 = pkg { pname = "authz0"; version = "1.1.2"; src = gh "hahwul/authz0" "v1.1.2" "b62d61846f3c1559dbffb6707f943ad6c4a5d4d519119b3c21954b8cd2a11a16";
    vendorHash = "sha256-gohOzkryCQPqUtUGG2rJclbBBBM8XYcPE2DxfzPGGtw="; subPkgs = ".";
    check = chk ''"$out/bin/authz0" version'' "1\\.1\\.2"; };
  # babelfish (MIT): translate bash scripts to fish.
  babelfish = pkg { pname = "babelfish"; version = "1.2.1"; src = gh "bouk/babelfish" "refs/tags/v1.2.1" "967a9020e905f01b0d3150a37f35d21e8d051c634eebf479bc1503d95f81a1d9";
    vendorHash = "sha256-vBS2Wr9xszCTyeZcaBa0zp7Vbh/aGQBuy0TC3mp91YU="; subPkgs = ".";
    check = chk ''"$out/bin/babelfish" --help'' "[Uu]sage"; };
  # badger (Apache-2.0): fast key-value DB in Go.
  badger = pkg { pname = "badger"; version = "4.9.6"; src = gh "dgraph-io/badger" "refs/tags/v4.9.6" "fbe88bfe023bc1e1a3c5bebe18103f9b381010d5e66f206272c8ab7f498e112c";
    vendorHash = "sha256-pVMJT4BuahuqghM/U19OzDmTdVSdEcQAC//59UR2P2U="; subPkgs = "./badger";
    check = chk ''"$out/bin/badger" --help'' "[-]-vlog-dir"; };
  # bazel-kazel (Apache-2.0): BUILD file generator for go and bazel.
  bazel-kazel = pkg { pname = "bazel-kazel"; version = "0.2.6"; src = gh "kubernetes/repo-infra" "v0.2.6" "8449f6d831cc192d6d486adbbf37f0f508e8f4e0cb9c58995d3141e6d122fa17";
    vendorHash = "sha256-GL9bBCbT2+W4vYLbUs0HTp0RC6GbIghM0pMx7DTx1AY="; subPkgs = "./cmd/kazel";
    check = chk ''"$out/bin/kazel" --help'' "[-]print-diff"; };
  # bbrew (MIT): TUI for managing Homebrew, Flatpak, and Mac App Store packages.
  bbrew = pkg { pname = "bbrew"; version = "2.3.2"; src = gh "Valkyrie00/bold-brew" "refs/tags/v2.3.2" "2e22f351e9726128746a3f2f8591e9d1a2f525cbe1aca6b0af6a20f6f909faec";
    vendorHash = "sha256-rqJ2wzdfMGRXT3bWDn2BFW0S7QEiPg1jqXjj7vRhcY4="; subPkgs = "./cmd/bbrew"; ldflags = "-s -w -X bbrew/internal/services.AppVersion=2.3.2";
    check = chk ''"$out/bin/bbrew" --version'' "2\\.3\\.2"; };
  # air (GPL-3.0-only): live reload for Go apps.
  air = pkg { pname = "air"; version = "1.67.4"; src = gh "air-verse/air" "refs/tags/v1.67.4" "d74de50458f4f2cd744bb08a1acf84dbbcc99138ea0682176568f9a381a81887";
    vendorHash = "sha256-PcNN7LLNIm7Yjt+A4V/55fo3MN1OpTCV0Xa4FweIvss="; subPkgs = "."; ldflags = "-s -w -X=main.airVersion=1.67.4";
    check = chk ''"$out/bin/air" --help'' "[Uu]sage"; };
  # aiac (Apache-2.0): artificial Intelligence Infrastructure-as-Code Generator.
  aiac = pkg { pname = "aiac"; version = "5.3.0"; src = gh "gofireflyio/aiac" "refs/tags/v5.3.0" "45e48cd8958d835b402e0e68d7aa8b9642deb535464dad5d6b83fb8f8ed3d79e";
    vendorHash = "sha256-10ErVCIaXRxz5V52/ZFi7+SXd3/pWY9YxFRdmdrLA6A="; subPkgs = "."; ldflags = "-s -w -X github.com/gofireflyio/aiac/v4/libaiac.Version=v5.3.0";
    check = chk ''"$out/bin/aiac" --help'' "[-]-list-models"; };
  # bit-logo (MIT): terminal ANSI Logo Designer & Font Library.
  bit-logo = pkg { pname = "bit-logo"; version = "0.4.0"; src = gh "paulilaaso/bit" "refs/tags/v0.4.0" "2aa41585332d53685a3bd644d8d086f3ae999750b9e2f19ee8832ba9cec9737c";
    vendorHash = "sha256-lQJQo8bE51l/rMLjeBXQD/6Jcfgh6pT0b6lrAEGdf0I="; subPkgs = "./cmd/ansifonts ./cmd/bit"; ldflags = "-s -w";
    check = chk ''"$out/bin/bit" --version'' "0\\.4\\.0"; };
  # bitcrook (Apache-2.0): tool to do OSINT.
  bitcrook = pkg { pname = "bitcrook"; version = "2.3.2"; src = gh "ax-i-om/bitcrook" "refs/tags/v2.3.2" "67f0b89a8e6475b65f236e36ddba15d473e405464d1a5368c8f97fbd4b473eba";
    vendorHash = "sha256-4qge30AHWZSGBZOS9mGxXxk+WP+SrEAT73svzNNb8U0="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/bitcrook" --version'' "2\\.3\\.2"; };
}
