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
  # ---- recipes4 batch 7 (R7) ----------------------------------------------------------------------------------------------------
  # esbuild (MIT): the JavaScript/TypeScript bundler and minifier.
  esbuild = pkg { pname = "esbuild"; version = "0.27.2"; src = gh "evanw/esbuild" "v0.27.2" "d16527a0b29c747d80afaa1cd362d7eee5814c0569af6cc2080e7343482b28d2";
    vendorHash = "sha256-3cW6F1zamLtHDs+nIijVT2laudd0y0bFZNkIdc0ZZKY="; subPkgs = "./cmd/esbuild"; ldflags = "-s -w";
    check = chk ''echo 'let x: number = 1+2; console.log(x)' | "$out/bin/esbuild" --loader=ts'' "let x = 1 \\+ 2;"; };
  # protoc-go-inject-tag (BSD-2-Clause): injects custom struct tags into protoc-generated Go.
  protoc-go-inject-tag = pkg { pname = "protoc-go-inject-tag"; version = "1.4.0"; src = gh "favadi/protoc-go-inject-tag" "v1.4.0" "0ec154e2b8159b1e449a7d182accf925bdad3b084ba75b8a497bcc816e49f47d";
    vendorHash = "sha256-KzBcnFv5OCRXVqpEkVtec9uj5DfIS05Jf/TNYlcEdvQ="; subPkgs = ".";
    check = chk ''cd "$W" && printf 'package p\n\ntype T struct {\n\t// @gotags: yaml:"a"\n\tA string `json:"a"`\n}\n' > t.pb.go && "$out/bin/protoc-go-inject-tag" -input=t.pb.go && cat t.pb.go'' "json:\"a\" yaml:\"a\""; };
  # tailer (MIT): prints a marker line whenever a command's output pauses.
  tailer = pkg { pname = "tailer"; version = "0.1.1"; src = gh "hionay/tailer" "v0.1.1" "0b38cdc0dfb73eb2ec37670670acbe0969e613f1bf53d1d20cd03d89f9e64503";
    vendorHash = "sha256-nQwPZGyV+KUGfwR7uSNVZ5lkLuJ3HcnEbD1B0ZL4u3Y="; subPkgs = "./cmd/tailer"; ldflags = "-s -X=main.version=0.1.1";
    check = chk ''"$out/bin/tailer" --version'' "0\\.1\\.1"; };
  # go-rice (BSD-2-Clause): the rice tool, embeds resources into Go binaries.
  go-rice = pkg { pname = "go-rice"; version = "1.0.3"; src = gh "GeertJohan/go.rice" "v1.0.3" "dda8be9c9c594e164e664479001e7113d0f6571b3fc93253ef132096540f0673";
    vendorHash = "sha256-L3Ld0VMKfjbl6LQ+R9nkalXlaCnWP1KJyyN2fpOHWbY="; subPkgs = "./rice";
    check = chk ''"$out/bin/rice" --help 2>&1'' "embed-go"; };
  # starlark (BSD-3-Clause): the Starlark interpreter in Go (and star2proto), as nixpkgs' snapshot.
  starlark = pkg { pname = "starlark"; version = "0-unstable-2026-10-21";
    src = { url = "https://codeload.github.com/google/starlark-go/tar.gz/4f4267fb140d1e8b91c9bce55cee2f809e8840dd"; sha256 = "a5f0f496f14f2c30ec25737cd9da1e369327450003b6ae49cd1ddb3f6eee327f"; };
    vendorHash = "sha256-uj117BY+vYD35Py1jWwUmPCGFI7T2O+SIiyxlXagD+M="; subPkgs = "./cmd/starlark ./lib/proto/cmd/star2proto"; ldflags = "-s -w";
    check = chk ''"$out/bin/starlark" -c 'print(6*7)' '' "^42$"; };
  # stuffbin (MIT): stuffs static files into a Go binary (the CLI; the mock demo is not installed).
  stuffbin = pkg { pname = "stuffbin"; version = "1.3.0"; src = gh "knadh/stuffbin" "v1.3.0" "10de8bdec2997299beaff857cd5a4c74b3951c9e4dab97b68f7b97af8d564ac3";
    vendorHash = null; subPkgs = "./stuffbin"; ldflags = "-s -w -X main.version=1.3.0";
    check = chk ''cd "$W" && echo solnix > f.txt && "$out/bin/stuffbin" -a stuff -in "$out/bin/stuffbin" -out s.bin f.txt:/f.txt && "$out/bin/stuffbin" -a id -in s.bin'' "1 files totalling"; };
  # templ (MIT): the templ HTML templating compiler for Go.
  templ = pkg { pname = "templ"; version = "0.3.1020"; src = gh "a-h/templ" "v0.3.1020" "4f21ea4f1b60d65e506fa146a33a9d83d055c6f1e2e7687421f08ada6614d83c";
    vendorHash = "sha256-tkWHLxDre8Z7gJhuNEIKtSZuk8TvdXkD2rvTeoUr3WI="; subPkgs = "./cmd/templ"; ldflags = "-s -w";
    check = chk ''cd "$W" && printf 'package main\n\ntempl hello(name string) {\n\t<div>Hello, { name }</div>\n}\n' > h.templ && "$out/bin/templ" generate -f h.templ -stdout'' "func hello\\(name string\\) templ\\.Component"; };
  # tmx2lua (MIT): converts Tiled .tmx maps to Lua tables.
  tmx2lua = pkg { pname = "tmx2lua"; version = "1.0.1"; src = gh "hawkthorne/tmx2lua" "v1.0.1" "33a96b3188ef692609df651bfdde9b5eb89e2db5fca885dc51f0a0965dad3cda";
    vendorHash = "sha256-xGzdxIYeUgoXiVjXu++KNRRNNtx0XJ+H/FUeblpnpBc="; subPkgs = ".";
    check = chk ''cd "$W" && printf '<?xml version="1.0"?>\n<map version="1.0" orientation="orthogonal" width="2" height="1" tilewidth="8" tileheight="8"><tileset firstgid="1" name="t" tilewidth="8" tileheight="8"><image source="t.png" width="8" height="8"/></tileset><layer name="g" width="2" height="1"><data encoding="csv">1,0</data></layer></map>\n' > m.tmx && "$out/bin/tmx2lua" m.tmx && cat m.lua'' "name = \"g\""; };
  # addlicense (Apache-2.0): adds license headers to source files.
  addlicense = pkg { pname = "addlicense"; version = "1.2.0"; src = gh "google/addlicense" "v1.2.0" "d2e05668e6f3da9b119931c2fdadfa6dd19a8fc441218eb3f2aec4aa24ae3f90";
    vendorHash = "sha256-bbYCYT2Ccs93XXS7Gvm76JvldKzIdyZW1pEJ6IPAK6M="; subPkgs = ".";
    check = chk ''cd "$W" && printf 'package x\n' > a.go && "$out/bin/addlicense" -c solnix -l mit -y 2026 a.go && head -1 a.go'' "Copyright \\(c\\) 2026 solnix"; };
  # align (MIT): aligns delimited text into columns (the module commits its vendor/).
  align = pkg { pname = "align"; version = "1.1.3"; src = gh "Guitarbum722/align" "v1.1.3" "b386fd179d3c6fb7a2b5e65aee98e9eeaf0108741fe249bd9fce40c506d59819";
    vendorHash = null; subPkgs = "./cmd/align";
    check = chk ''printf 'a,bb\nccc,d\n' | "$out/bin/align"'' "^a +, *bb"; };
  # anko (MIT): a scriptable interpreter written in Go (the v0.1.9 tag's version constant says 0.1.8: upstream).
  anko = pkg { pname = "anko"; version = "0.1.9"; src = gh "mattn/anko" "v0.1.9" "195c59d0654eb08b2408ae5ee30d8429bbd2c04ea6a90c35df847c15b208c7d4";
    vendorHash = null; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/anko" -e 'println(6*7)' '' "^42$"; };
  # asciigraph (BSD-3-Clause): ASCII line graphs in the terminal.
  asciigraph = pkg { pname = "asciigraph"; version = "0.10.0"; src = gh "guptarohit/asciigraph" "v0.10.0" "91fe3822427db43b5bdaa158d39387fc01e4e03d999457da658f9b223b762020";
    vendorHash = null; subPkgs = "./cmd/asciigraph"; ldflags = "-s -w";
    check = chk ''printf '1\n2\n3\n' | "$out/bin/asciigraph" -h 3'' "3\\.00"; };
  # asmfmt (MIT): the Go assembler source formatter.
  asmfmt = pkg { pname = "asmfmt"; version = "1.3.2"; src = gh "klauspost/asmfmt" "v1.3.2" "4bb6931aefcf105c0e0bc6d239845f6350aceba5b2b76e84c961ba8d100f8fc6";
    vendorHash = null; subPkgs = "./cmd/asmfmt"; ldflags = "-s -w";
    check = chk ''printf 'TEXT foo(SB),NOSPLIT,$0\nRET\n' | "$out/bin/asmfmt"'' "TEXT foo\\(SB\\), NOSPLIT, \\$0"; };
  # codeowners (MIT): shows the owners of files from a CODEOWNERS file.
  codeowners = pkg { pname = "codeowners"; version = "1.2.1"; src = gh "hmarr/codeowners" "v1.2.1" "6ab6ce2683eca12c3d7bee65f1087f03e97f34c682e24493b33a005dfcd701cd";
    vendorHash = "sha256-iyBRrpDhYxVarEq2l9PisYKd0sRYyowOPqFtSWkV+tU="; subPkgs = "./cmd/codeowners";
    check = chk ''cd "$W" && printf '* @solnix\n' > CODEOWNERS && touch a && "$out/bin/codeowners" -f CODEOWNERS a'' "^a +@solnix"; };
  # certstrap (Apache-2.0): a small certificate authority CLI.
  certstrap = pkg { pname = "certstrap"; version = "1.4.0"; src = gh "square/certstrap" "v1.4.0" "10f1d123aa0ec066e3256741f1d945b5dfd2c61ca24855556e3a8db93b44d8c5";
    vendorHash = "sha256-ezmCAmK3s8c4H2AOmXJvCo5glqkTXsmJfiorPH8PH/c="; subPkgs = "."; ldflags = "-X main.release=1.4.0";
    # vendored gopass keeps terminal.go off solaris (so illumos) with "// +build !solaris", but the line follows a /* */ license
    # block, and Go reads +build lines only in the leading // comments, so it collides with terminal_solaris.go. A //go:build line
    # is read anywhere before the package clause: the same constraint, now honoured.
    prep = ''
      f=vendor/github.com/howeyc/gopass/terminal.go
      [ "$(grep -cx '// +build !solaris' $f)" = 1 ] || { echo "FATAL: gopass build-tag anchor" >&2; exit 1; }
      sed -i 's|^// +build !solaris$|//go:build !solaris|' $f
    '';
    check = chk ''cd "$W" && "$out/bin/certstrap" --depot-path d init --passphrase "" --common-name solnixCA --curve P-256 && ls d'' "solnixCA\\.crt"; };
  # cidr-merger (MIT): merges and sorts IP ranges and CIDRs.
  cidr-merger = pkg { pname = "cidr-merger"; version = "1.1.3"; src = gh "zhanhb/cidr-merger" "v1.1.3" "48b13f950d56175712c47ea7b1c0a4a905fd2995dee76708625152c134ab1cba";
    vendorHash = "sha256-YYFazDdu4QQqWWWifhmWmikSF3pV7G8zzXsq/WahsSA="; subPkgs = ".";
    check = chk ''printf '10.0.0.0/25\n10.0.0.128/25\n' | "$out/bin/cidr-merger"'' "^10\\.0\\.0\\.0/24$"; };
  # csvdiff (MIT): diffs two CSV files by primary key.
  csvdiff = pkg { pname = "csvdiff"; version = "1.4.0"; src = gh "aswinkarthik/csvdiff" "v1.4.0" "cf9804ae5006cba3ae4ecff218f57e3d136f06d9614fd466189eacd8068d6e6a";
    vendorHash = "sha256-oabz2t15Nb21h4++O09pDXvQtnyphM95iJriiZ8HBRg="; subPkgs = ".";
    check = chk ''cd "$W" && printf 'id,a\n1,x\n2,y\n' > b.csv && printf 'id,a\n1,x\n2,z\n3,w\n' > d.csv && "$out/bin/csvdiff" b.csv d.csv --format rowmark'' "Additions 1"; };
  # cue (Apache-2.0): the CUE data validation language CLI.
  cue = pkg { pname = "cue"; version = "0.17.1"; src = gh "cue-lang/cue" "v0.17.1" "32279a50fdd37223ce66a1864d38914c7938e6378e256ff1ec8bb7a7be0bb0fc";
    vendorHash = "sha256-kerpXVcGrFmsQoFvk8J+nfM46qfLzLNIQ5OxwPERTFs="; subPkgs = "./cmd/cue"; ldflags = "-s -w -X cuelang.org/go/cmd/cue/cmd.version=v0.17.1";
    check = chk ''cd "$W" && printf 'a: 1 + 41\n' > x.cue && "$out/bin/cue" export x.cue'' "\"a\": 42"; };
  # chglog (MIT): changelog management (goreleaser).
  chglog = pkg { pname = "chglog"; version = "0.7.4"; src = gh "goreleaser/chglog" "v0.7.4" "07942438f6a4329a86ded3f5048f43bc2f9d07cdf26ecbcf247e78e7ec75005c";
    vendorHash = "sha256-IWmlj2v3FU0ScufIku7MI1TPtW9A88M/48QtNKuBseA="; subPkgs = "./cmd/chglog"; ldflags = "-s -w -X=main.version=0.7.4";
    check = chk ''"$out/bin/chglog" version'' "chglog 0\\.7\\.4"; };
  # bump (MIT): picks the next semver for a GitHub repo's release.
  bump = pkg { pname = "bump"; version = "0.2.6"; src = gh "mroth/bump" "v0.2.6" "bcc5b6a76a0924615bf5106555e9d4d40f7728511926c6b5c9715c918dfe4a15";
    vendorHash = "sha256-aw8N2EJASYLg9McamZ0HydIBwGLuOudyIgpUXhJit9Y="; subPkgs = "."; ldflags = "-X main.buildVersion=0.2.6 -X main.buildCommit=0.2.6 -X main.buildDate=1970-01-01";
    check = chk ''"$out/bin/bump" --version'' "^0\\.2\\.6$"; };
}
