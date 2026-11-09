# cli/go-recipes3.nix -- Go tools the x86 build queue has jobs for (recipes3, 2026-11-08), on goPkg storeOnly (../go-pkg-build2.sh:
# store tools + the world on PATH, path-gated), as go-recipes2.nix. Versions are the queue's targets, ldflags nixpkgs'. Each source
# is pinned by sha256 and its vendor dir by its NAR hash (the vendor fixed-output build, measured on woof). Statically linked (CGO=0).
{ goPkg, chk }:
let
  gh = repo: tag: sha256: { url = "https://codeload.github.com/${repo}/tar.gz/refs/tags/${tag}"; inherit sha256; };
  pkg = a: goPkg ({ storeOnly = true; } // a);
in {
  # go-md2man (MIT): markdown to man pages (docker, cobra CLIs' docs).
  go-md2man = pkg { pname = "go-md2man"; version = "2.0.7"; src = gh "cpuguy83/go-md2man" "v2.0.7" "ca3a5b57e2c01759f5a00ad2a578d034c5370fae9aa7a6c3af5648b2fc802a92";
    vendorHash = "sha256-g4wAsx2UPlsFN+IZXJnrZi7ee80bDoFlsIG3ZN+TneY="; subPkgs = ".";
    check = chk ''printf '%% t(1)\n# NAME\nt - a test\n' | "$out/bin/go-md2man"'' "^\\.TH t\\(1\\)"; };
  # jp (Apache-2.0): JMESPath on the command line (go-jmespath's cmd).
  jmespath = pkg { pname = "jmespath"; version = "0.4.0"; src = gh "jmespath/go-jmespath" "v0.4.0" "aa86d00b6836345eee196c13df2df084a18e0b1159935de9289f2ef6a7fe375d";
    vendorHash = "sha256-NwkfexrFGQANOwaKNGOnOcKgVW3p1mU3Hjji2YLt7BI="; subPkgs = "./cmd/jpgo"; ldflags = "-s -w";
    check = chk ''echo '{"a":{"b":[1,2,42]}}' | "$out/bin/jpgo" a.b[2]'' "^42$"; };
  # go-bindata (CC0-1.0): embed files into Go source.
  go-bindata = pkg { pname = "go-bindata"; version = "4.0.2"; src = gh "kevinburke/go-bindata" "v4.0.2" "ac343c4b316b234b8ea354d86eb3c7ded2da4fe8f40d45f60391d289c66cd950";
    vendorHash = null; subPkgs = "./go-bindata"; ldflags = "-s -w";
    check = chk ''"$out/bin/go-bindata" -version'' "go-bindata 4\\.0\\.2"; };
  # minica (MIT): a small CA that issues local test certificates.
  minica = pkg { pname = "minica"; version = "1.1.0"; src = gh "jsha/minica" "v1.1.0" "4f56ea73d2a943656f8a5b533e554b435bc10f56c12d0b53836e84a96b513bf7";
    vendorHash = null; subPkgs = "."; ldflags = "-s -w";
    check = chk ''cd "$W" && "$out/bin/minica" -domains solnix.test && ls solnix.test/cert.pem minica.pem'' "minica\\.pem"; };
  # go-toml (MIT): tomll / tomljson / jsontoml, the go-toml v2 CLIs.
  go-toml = pkg { pname = "go-toml"; version = "2.3.1"; src = gh "pelletier/go-toml" "v2.3.1" "5445285babfa0348be3cf2981968e0dee31768d16f3300d477d4c710437a0df3";
    vendorHash = null; subPkgs = "./cmd/tomll ./cmd/tomljson ./cmd/jsontoml"; ldflags = "-s -w -X main.version=2.3.1";
    check = chk ''printf 'a = 42\n' | "$out/bin/tomljson"'' "\"a\": 42"; };
  # mockgen (Apache-2.0): Go mock generator (uber-go/mock).
  mockgen = pkg { pname = "mockgen"; version = "0.6.0"; src = gh "uber-go/mock" "v0.6.0" "e315da02f11069f4e9688054cf8dba86535318ea28ab7a2fe144c5e6a859e329";
    vendorHash = "sha256-vPlTKxOJc5tFwoomUhGzOjZWMc6Iw+KEJeEDxn8Ijy0="; subPkgs = "./mockgen";
    ldflags = "-X=main.version=0.6.0 -X=main.date=1970-01-01T00:00:00Z -X=main.commit=refs/tags/v0.6.0";
    check = chk ''"$out/bin/mockgen" -version'' "^v?0\\.6\\.0"; };
}
