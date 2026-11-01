# cli/go-c1.nix -- batch C1 of the maintainer's Go tools (nxq1 c-batches.tsv), on goPkg (../go.nix) as ./go-tools.nix.
# Versions are nixpkgs' at nix-config's lock; subPackages/ldflags follow nixpkgs' recipes. Statically linked (CGO=0),
# so the tz/services/mime data come from the system (/usr/share/lib/zoneinfo, /etc/services, /etc/mime.types).
{ goPkg, chk, go_1_27, python3 }:   # python3: the store one, for go-ioctl-fixup.py (a solnix host has no python3 on PATH)
let
  gh = repo: tag: sha256: { url = "https://codeload.github.com/${repo}/tar.gz/refs/tags/${tag}"; inherit sha256; };
  ioctl = f: "${python3}/bin/python3 ${../go-ioctl-fixup.py} ${f} terminal 'const ioctlReadTermios = unix.TCGETS; const ioctlWriteTermios = unix.TCSETS'";
  survey = ioctl "vendor/github.com/AlecAivazis/survey/v2/terminal/runereader_posix.go";
in {
  git-lfs = goPkg { pname = "git-lfs"; version = "3.7.1"; src = gh "git-lfs/git-lfs" "v3.7.1" "0e83566a9e2477e03627e7fd6bf81f01fadbf93dcaf6abd2686fca90f6bac7dd"; vendorHash = "sha256-95QUAZ6Bwicc8PUJYm8agdHhRfmBLfM+MlymaUvVCfM=";
    subPkgs = "."; ldflags = "-X github.com/git-lfs/git-lfs/v3/config.Vendor=3.7.1"; check = chk ''"$out/bin/git-lfs" version'' "^git-lfs/3\\.7\\.1"; };
  dasel = goPkg { pname = "dasel"; version = "3.8.1"; src = gh "TomWright/dasel" "v3.8.1" "92711ddecfad9a1e97a41011d12ea88e9bb3c37827e5d5a718c3a8e8eaa88eaa"; vendorHash = "sha256-b5fbsSWPY4z4a6MWlQHgTZdK2B5a+hLUar6G9YiuD1s=";
    subPkgs = "./cmd/dasel"; ldflags = "-X github.com/tomwright/dasel/v3/internal.Version=v3.8.1"; check = chk ''echo '{"a":{"b":7}}' | "$out/bin/dasel" -i json 'a.b' '' "^7$"; };
  # duf: no illumos backend upstream (mounts_*.go: linux/bsd/darwin/windows); ./go-fixups/duf-illumos.go reads mnttab(5) + statvfs(2).
  duf = goPkg { pname = "duf"; version = "0.9.1"; src = gh "muesli/duf" "v0.9.1" "1334d8c1a7957d0aceebe651e3af9e1c1e0c6f298f1feb39643dd0bd8ad1e955"; vendorHash = "sha256-oQlO58/LUff4E6spDdbL2fgD9lmkY1+lLyPwrav+EwU=";
    subPkgs = "."; ldflags = "-X=main.Version=0.9.1"; prep = "cp ${./go-fixups/duf-illumos.go} mounts_illumos.go";
    check = chk ''"$out/bin/duf" -json /'' "\"mount_point\": \"/\""; };
  timer = goPkg { pname = "timer"; version = "1.4.6"; src = gh "caarlos0/timer" "v1.4.6" "b8286a449fb2fcaa685f2c4bd0300494414ce168e0123ba33ef6e15de9bb3a3a"; vendorHash = "sha256-NmkII1zv/0zdvzYki0vD4NxCY8zw7+xUPfnFKRx2GD0=";
    subPkgs = "."; ldflags = "-X main.version=1.4.6"; check = chk ''"$out/bin/timer" --version'' "1\\.4\\.6"; };
  act = goPkg { pname = "act"; version = "0.2.88"; src = gh "nektos/act" "v0.2.88" "a70c187ee403b53ead14b53296671528787734980b99d6deba029191c69ab131"; vendorHash = "sha256-R7BHWiM53Zk2FejhxLH89LxSBjhoS8ErYUsbqBZbPrA=";
    subPkgs = "."; ldflags = "-X main.version=0.2.88"; prep = survey; check = chk ''"$out/bin/act" --version'' "^act version 0\\.2\\.88"; };
  cfssl = goPkg { pname = "cfssl"; version = "1.6.5"; src = gh "cloudflare/cfssl" "v1.6.5" "b682452402f403b6ee668bb042bd9b753fe48df84fa7a18a1c32606ffd4918af"; vendorHash = null;  # ships vendor/
    subPkgs = "./cmd/cfssl ./cmd/cfssljson ./cmd/cfssl-bundle ./cmd/cfssl-certinfo ./cmd/cfssl-newkey ./cmd/cfssl-scan ./cmd/multirootca ./cmd/mkbundle";
    ldflags = "-X github.com/cloudflare/cfssl/cli/version.version=v1.6.5"; check = chk ''"$out/bin/cfssl" version'' "^Version: v?1\\.6\\.5"; };
  # flyctl: wireguard-go's UAPI socket code is plain unix sockets but its tag omits illumos; survey as act.
  flyctl = goPkg { pname = "flyctl"; version = "0.4.52"; src = gh "superfly/flyctl" "v0.4.52" "13fd85c6ea7f0b44428c280f51c5b060a46a060c9039698f121fa5ad02ce1975"; vendorHash = "sha256-HpXpBSLjMB76U2PWfHrRC+jYwN9zQ3LYG0ymSISdWpI=";
    subPkgs = "."; ldflags = "-X github.com/superfly/flyctl/internal/buildinfo.buildDate=1970-01-01T00:00:00Z -X github.com/superfly/flyctl/internal/buildinfo.buildVersion=0.4.52"; prep = ''
      f=vendor/golang.zx2c4.com/wireguard/ipc/uapi_unix.go
      grep -qx '//go:build linux || darwin || freebsd || openbsd' $f || { echo "FATAL: wireguard ipc tag anchor" >&2; exit 1; }
      sed -i 's/^\(\/\/go:build linux || darwin || freebsd || openbsd\)$/\1 || illumos/' $f
      ${survey}
      export GOFLAGS="$GOFLAGS -tags=production"   # nixpkgs' tags = [ "production" ]: buildinfo/env_production.go reads the -X version
    ''; check = chk ''"$out/bin/flyctl" version'' "^flyctl v0\\.4\\.52 "; };
  gitleaks = goPkg { pname = "gitleaks"; version = "8.30.1"; src = gh "gitleaks/gitleaks" "v8.30.1" "e90fb266d75837e75894c778bf594ab8e2787f12dce5a62651f21b893eaf9abb"; vendorHash = "sha256-wAeKduwhzMIz7h/Uiafzvt+rq89Bd5Bxo+lPV+szDMs=";
    subPkgs = "."; ldflags = "-X=github.com/zricethezav/gitleaks/v8/version.Version=8.30.1"; check = chk ''"$out/bin/gitleaks" version'' "^8\\.30\\.1"; };
  kind = goPkg { pname = "kind"; version = "0.31.0"; src = gh "kubernetes-sigs/kind" "v0.31.0" "f4aaa1f572f9965eea3f7513d166f545f41b61ab5efeed953048bdcb13c51032"; vendorHash = "sha256-E3VA8s0JA94lOahoXkqSd72j1UFG592PlSwWJm1r4q8=";
    subPkgs = "."; check = chk ''"$out/bin/kind" version'' "^kind v0\\.31\\.0"; };
  kubernetes-helm = goPkg { pname = "kubernetes-helm"; version = "3.20.2"; src = gh "helm/helm" "v3.20.2" "5c4a5f105e63aae7d2a059eb43351549fd4f870ef6756204fac2beae3198f248"; vendorHash = "sha256-7C6uunkMAKtKwHiE74f5l+1a9l8gJOxKvdk2ltnCeok=";
    subPkgs = "./cmd/helm"; ldflags = "-X helm.sh/helm/v3/internal/version.version=v3.20.2 -X helm.sh/helm/v3/pkg/lint/rules.k8sVersionMajor=1 -X helm.sh/helm/v3/pkg/lint/rules.k8sVersionMinor=35 -X helm.sh/helm/v3/pkg/chartutil.k8sVersionMajor=1 -X helm.sh/helm/v3/pkg/chartutil.k8sVersionMinor=35";
    check = chk ''"$out/bin/helm" version --short'' "^v3\\.20\\.2"; };
  s5cmd = goPkg { pname = "s5cmd"; version = "2.3.0"; src = gh "peak/s5cmd" "v2.3.0" "6910763a7320010aa75fe9ef26f622e440c2bd6de41afdbfd64e78c158ca19d4"; vendorHash = null;  # ships vendor/
    subPkgs = "."; ldflags = "-X github.com/peak/s5cmd/v2/version.Version=v2.3.0"; check = chk ''"$out/bin/s5cmd" version'' "v2\\.3\\.0"; };
  terraform-ls = goPkg { pname = "terraform-ls"; version = "0.38.6"; src = gh "hashicorp/terraform-ls" "v0.38.6" "76df608818567cc02cfba57e23558a5ba561b3aa0a60c2f3abf1a1e2f8b282fc"; vendorHash = "sha256-oOus8qN5MOd0mCYBHaORjVIr/pYVGEfbMdJnuyVIzEc=";
    subPkgs = "."; check = chk ''"$out/bin/terraform-ls" version'' "0\\.38\\.6"; };
  # opentofu (MPL-2.0), not terraform (BUSL-1.1, nixpkgs: unfree). GOOS=illumos, but registries publish solaris_amd64
  # providers only: ./go-fixups/tofu-platform-illumos.go makes tofu ask for those (measured: init + apply hashicorp/random).
  opentofu = goPkg { pname = "opentofu"; version = "1.11.14"; src = gh "opentofu/opentofu" "v1.11.14" "891b3d6069f9e6788e839c2317ecd145d69a64d0618eccca1b2e90b54ece2afa"; vendorHash = "sha256-uihJM6MpG0icaTHdLNVXYf301FwymWl6uG/LK9Pbkwk=";
    subPkgs = "./cmd/tofu"; ldflags = "-X github.com/opentofu/opentofu/version.dev=no"; prep = "cp ${./go-fixups/tofu-platform-illumos.go} internal/getproviders/platform_illumos.go";
    check = chk ''"$out/bin/tofu" version | tr "\\n" " "'' "^OpenTofu v1\\.11\\.14 on solaris_amd64"; };
  # gh-dash: godbus/dbus tags its unix transport !solaris (no peer-credential arm); a local bus needs none.
  gh-dash = goPkg { pname = "gh-dash"; version = "4.25.0"; src = gh "dlvhdr/gh-dash" "v4.25.0" "cd36a9f004e3a40d6acdea5183429a50e07ebbefad03eb95915d09ac9d37db15"; vendorHash = "sha256-nYbFNClgWijahEnX8rMIhowP0yxysDymhKYr53oUUC4=";
    subPkgs = "."; ldflags = "-X github.com/dlvhdr/gh-dash/v4/cmd.Version=4.25.0"; prep = ''
      d=vendor/github.com/godbus/dbus/v5
      grep -qx '//go:build !windows && !solaris && !darwin' $d/conn_unix.go && grep -qx '//go:build !windows && !solaris' $d/transport_unix.go \
        || { echo "FATAL: godbus build-tag anchor" >&2; exit 1; }
      sed -i 's/^\/\/go:build !windows && !solaris && !darwin$/\/\/go:build !windows \&\& (!solaris || illumos) \&\& !darwin/' $d/conn_unix.go
      sed -i 's/^\/\/go:build !windows && !solaris$/\/\/go:build !windows \&\& (!solaris || illumos)/' $d/transport_unix.go
      cp ${./go-fixups/dbus-illumos.go} $d/transport_unixcred_illumos.go
    ''; check = chk ''"$out/bin/gh-dash" --version'' "4\\.25\\.0"; };
  kubectl = goPkg { pname = "kubectl"; version = "1.36.3"; src = gh "kubernetes/kubernetes" "v1.36.3" "950f7dd65b64b18ca065a08ae73dd5f61ff72b48c8778c5bfceacc84eaaf10ed"; vendorHash = null;  # ships vendor/
    subPkgs = "./cmd/kubectl"; ldflags = "-X k8s.io/component-base/version.gitVersion=v1.36.3 -X k8s.io/client-go/pkg/version.gitVersion=v1.36.3";
    check = chk ''"$out/bin/kubectl" version --client'' "Client Version: v1\\.36\\.3"; };
}
