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
  # ---- recipes3 batch 6 ---------------------------------------------------------------------------------------------------------
  # age (BSD-3-Clause): simple file encryption (and age-keygen). age-keygen's usage text embeds age's documented example identity
  # (README, man page): not a key anyone uses, but secret-shaped, and the publish gate's B18 refuses it.
  # The example is shortened in the usage text, as the orchestrator chose (2026-11-09), so no gate allowlist is needed.
  age = pkg { pname = "age"; version = "1.3.2"; src = gh "FiloSottile/age" "v1.3.2" "b07c28c6c4bdafa272073a310b75bc22c49da8904585a89c30e5ca4233e63843";
    vendorHash = "sha256-3j9m3GT8e/ZeF5b2OwaxNiuUYc6mRWe914QyjQmxkyg="; subPkgs = "./cmd/age ./cmd/age-keygen"; ldflags = "-s -w -X main.Version=v1.3.2";
    prep = ''
      # by shape (the Bech32 body), so the recipe never spells the example out (gitleaks, rightly, would not let it in)
      k='AGE-SECRET-KEY-1[02-9ACDEFGHJKLMNPQRSTUVWXYZ]\{58\}'   # upper-case Bech32 body
      [ "$(grep -c "$k" cmd/age-keygen/keygen.go)" = 1 ] || { echo "FATAL: age-keygen example anchor" >&2; exit 1; }
      sed -i "s/$k/AGE-SECRET-KEY-1.../" cmd/age-keygen/keygen.go
      ! grep -q "$k" cmd/age-keygen/keygen.go || { echo "FATAL: age-keygen example still there" >&2; exit 1; }
    '';
    check = chk ''"$out/bin/age-keygen" -o "$W/k" 2>/dev/null; R=$(grep -o "age1[a-z0-9]*" "$W/k"); echo solnix | "$out/bin/age" -r "$R" | "$out/bin/age" -d -i "$W/k"'' "^solnix$"; };
  # typer (MIT): a typing test in the terminal.
  typer = pkg { pname = "typer"; version = "0-unstable-2024-05-25";
    src = { url = "https://codeload.github.com/maaslalani/typer/tar.gz/0e674b236154b05f89fb4f5bee20c7269fd71477"; sha256 = "d538e9ed5750b0e4e64a689339c4aeafb09edf6251822e3ed1d082ae31b238f4"; };
    vendorHash = "sha256-CanMnbTXRl3Nq9jJDziyt1tsah0/xUyCF+OzrG5IdUU="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/typer" --help 2>&1'' "[Uu]sage"; };
  # safe (MIT): a Vault CLI.
  safe = pkg { pname = "safe"; version = "1.8.0"; src = gh "egen/safe" "v1.8.0" "296d67e4964751de04bb49716b8ae6c21b83f4096c1cd23f5434fd3f6ead0302";
    vendorHash = "sha256-4hUnfQQ6xrvWOOJR1Kd7JgrtT+Ej0uX0QmuDqHg+K/g="; subPkgs = "."; ldflags = "-X main.Version=1.8.0";
    check = chk ''"$out/bin/safe" version 2>&1'' "1\\.8\\.0"; };
  # mmark (BSD-2-Clause): a markdown processor for IETF RFCs.
  mmark = pkg { pname = "mmark"; version = "2.2.32";
    src = { url = "https://codeload.github.com/mmarkdown/mmark/tar.gz/158e9cca0280c58e205cb69b02bf33d7d826915e"; sha256 = "0a0c5c9cd1a5988d1c5c143f8ae0ae045ec9bf183479562c19b01d9cfe140cb8"; };
    vendorHash = "sha256-BxKwQ3kRjMp84HXu8Ysv0EvX0ukFby54saFEX7YUTto="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''printf '# Hello\n\nsolnix text\n' > "$W/a.md"; "$out/bin/mmark" -html "$W/a.md"'' "solnix text"; };
  # protoc-gen-go (BSD-3-Clause): the Go protocol buffers generator.
  protoc-gen-go = pkg { pname = "protoc-gen-go"; version = "1.36.12"; src = gh "protocolbuffers/protobuf-go" "v1.36.12" "23a247d69c52872ecbfd6bcbee3216793b2672fa5a7b99497777bf9c3563756f";
    vendorHash = "sha256-Fk9mcWlX5Kjrx0ecLrb5OB8Hr1UL+TBCYoX22lb0ICs="; subPkgs = "./cmd/protoc-gen-go";
    check = chk ''"$out/bin/protoc-gen-go" --version'' "v1\\.36\\.12"; };
  # oras (Apache-2.0): OCI registry as storage, the CLI.
  oras = pkg { pname = "oras"; version = "1.3.5"; src = gh "oras-project/oras" "v1.3.5" "692a594bd59353221c4a387e3744d084b44cd73cf52e811c4672c7f9eda3527d";
    vendorHash = "sha256-pvW1blNBvsecarHXfDVHL6nnbQgWA3e36Zdl6LVuFmI="; subPkgs = "./cmd/oras";
    ldflags = "-s -w -X oras.land/oras/internal/version.Version=1.3.5 -X oras.land/oras/internal/version.BuildMetadata= -X oras.land/oras/internal/version.GitTreeState=clean";
    check = chk ''"$out/bin/oras" version'' "Version: +1\\.3\\.5"; };
  # swag (MIT): generates Swagger 2.0 docs from Go annotations.
  go-swag = pkg { pname = "go-swag"; version = "1.16.6"; src = gh "swaggo/swag" "v1.16.6" "d0193f08b829e1088753ff6d66d1205e22a6e7fd07ac28df5ecb001d9eb2c43d";
    vendorHash = "sha256-Nllh90O1vcEgm7pZcZJrNIC6F9tyw6mUK6hacF3LW1M="; subPkgs = "./cmd/swag";
    # the v1.16.6 tag's version constant still says v1.16.4 (upstream): the check generates docs for a one-route package instead
    check = chk ''mkdir -p "$W/sw" && printf 'package main\n// @title solnix\n// @version 1.0\nfunc main() {}\n' > "$W/sw/main.go" && cd "$W/sw" && "$out/bin/swag" init -q -g main.go -o docs && grep -o '"title": "solnix"' docs/swagger.json'' "solnix"; };
  # pebble (MPL-2.0): Let's Encrypt's small ACME test server.
  pebble = pkg { pname = "pebble"; version = "2.6.0"; src = gh "letsencrypt/pebble" "v2.6.0" "25e43dde8a9421b07b8830ea4ae4f0fde2968ce092f14588d9405279b1f2dac4";
    vendorHash = null; subPkgs = "./cmd/pebble"; ldflags = "-s -w -X main.version=2.6.0";
    check = chk ''"$out/bin/pebble" -version 2>&1'' "2\\.6\\.0"; };
  # semver (MIT): bump and compare semantic versions on the command line (catouc/semver-go).
  semver = pkg { pname = "semver"; version = "1.0.0"; src = gh "catouc/semver-go" "v1.0.0" "d48101249fd7a3fe86d7d9cfeebfab0eb6bf775070421cced6455c3fae485b69";
    vendorHash = null; subPkgs = "./cmd/semver";
    check = chk ''"$out/bin/semver" -h 2>&1'' "[Uu]sage|semver"; };
}
