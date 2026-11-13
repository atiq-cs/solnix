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
  # bomber-go (MPL-2.0): tool to scans Software Bill of Materials (SBOMs) for vulnerabilities.
  bomber-go = pkg { pname = "bomber-go"; version = "0.5.1"; src = gh "devops-kung-fu/bomber" "refs/tags/v0.5.1" "f4d8165ea9d3be0e88fdb33d35870588df308f31a4c40f14f09f0b68570f6ae1";
    vendorHash = "sha256-nLv/ySXzHDL/F16hWyfhXJt3jzq06BDJKxLW+hnTBxQ="; subPkgs = "."; ldflags = "-s";
    check = chk ''"$out/bin/bomber" --version'' "0\\.5\\.1"; };
  # broom (MIT): interactive CLI tool for managing local git branches.
  broom = pkg { pname = "broom"; version = "0.3.0"; src = gh "a-camarillo/broom" "v0.3.0" "9e6572743b3047b0a24cb3c608acd6dd7316514f8424dab3233aee382b861ce1";
    vendorHash = "sha256-D/tW5LnFsSboa3e2AITj47XhZXVnGk/HiCAvtCuMlcs="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/broom" --version'' "0\\.3\\.0"; };
  # brows (MIT): CLI tool to browse GitHub releases.
  brows = pkg { pname = "brows"; version = "0.1.3"; src = gh "rubysolo/brows" "refs/tags/v0.1.3" "d10d13f2fcaa4208f50b872971ea198fcdbebaedb710dbbe1cd70d3210cc9562";
    vendorHash = "sha256-ZFTAk3BZhbzlinDpZCvOnwhORkn66jfXYduqy7p8cs0="; subPkgs = "."; ldflags = "-X main.Version=0.1.3";
    check = chk ''"$out/bin/brows" version'' "0\\.1\\.3"; };
  # bunster (BSD-3-Clause): compile shell scripts to static binaries.
  bunster = pkg { pname = "bunster"; version = "0.9.0"; src = gh "yassinebenaid/bunster" "refs/tags/v0.9.0" "ef9ae7ab1bbaa1ee00cc185d82e7c0f6e9d320a3ef23e6315f8a859b1e91f3fd";
    vendorHash = "sha256-HpGCTBQSIXSMAOjwY6shemY30BRe8I/1fL2JEAbxOeE="; subPkgs = "./cmd/bunster";
    check = chk ''"$out/bin/bunster" version'' "0\\.9\\.0"; };
  # buttplug-mcp (MIT): buttplug.io Model Context Protocol (MCP) Server.
  buttplug-mcp = pkg { pname = "buttplug-mcp"; version = "0.0.1"; src = gh "ConAcademy/buttplug-mcp" "v0.0.1" "076f3e7d29d9c667050802e036386052418cd1e6cdf2d363e38839fa8ec86906";
    vendorHash = "sha256-XHZsicvOmZgd5iPrt7q00of/KDHjkQn7lrK/4L6peMo="; subPkgs = "./cmd/buttplug-mcp"; ldflags = "-s -w -X main.version=0.0.1";
    check = chk ''"$out/bin/buttplug-mcp" --help'' "[-]-log-file"; };
  # c-for-go (MIT): automatic C-Go Bindings Generator for the Go Programming Language.
  c-for-go = pkg { pname = "c-for-go"; version = "1.3.0"; src = gh "xlab/c-for-go" "v1.3.0" "a3a3c020fddfce8ec2d0140068b1fd942884629bd3d8d1e6ba804ba2cf57398e";
    vendorHash = "sha256-J5xh1VyDQ6yDd1H3s6qH6UmITW3mcT/yfhsHvT4EBVs="; subPkgs = ".";
    check = chk ''"$out/bin/c-for-go" --help'' "[Uu]sage"; };
  # capslock (BSD-3-Clause): capability analysis CLI for Go packages that informs users of which privileged operations a given package can access.
  capslock = pkg { pname = "capslock"; version = "0.3.4"; src = gh "google/capslock" "v0.3.4" "fb64041b3244e07036d108b2912ad8353b9daf0cd71d5ea232ec84657c55e296";
    vendorHash = "sha256-zLo41wHCThf84YS5Ip/yaLoMiAqNJDAwxeulAsdXLe0="; subPkgs = "./cmd/capslock"; ldflags = "-s";
    check = chk ''"$out/bin/capslock" --help'' "[Uu]sage"; };
  # cariddi (GPL-3.0-or-later): crawler for URLs and endpoints.
  cariddi = pkg { pname = "cariddi"; version = "1.4.6"; src = gh "edoardottt/cariddi" "refs/tags/v1.4.6" "9a33ebf9324c3f7f28c72161c80c994eaa3ca495c487eefed39a2e6861d65674";
    vendorHash = "sha256-vTcjN3ZQLT+i8kzRcvrn0VkFwL0V8CMpTt+OgGMJwLI="; subPkgs = "./cmd/cariddi"; ldflags = "-w -s";
    check = chk ''"$out/bin/cariddi" --version'' "1\\.4\\.6"; };
  # catbox (MIT): pipe mbox messages into shell commands.
  catbox = pkg { pname = "catbox"; version = "0.2.2"; src = gh "konimarti/catbox" "refs/tags/v0.2.2" "58fd2beb31932eea23f6409321b645330a391164aac5a09c18420a57f2f9af4f";
    vendorHash = "sha256-L52x/B2XJ7trNPYWp98bqSDkjNfzyiazv5/GVHR6S9c="; subPkgs = ".";
    check = chk ''"$out/bin/catbox" --help'' "[Uu]sage"; };
  # cdk-go (GPL-2.0-only): container penetration toolkit.
  cdk-go = pkg { pname = "cdk-go"; version = "1.5.6"; src = gh "cdk-team/CDK" "refs/tags/v1.5.6" "23a924e29c2045e0841b7277f41f99940abe8e36dc82ed7cceb89372f898ffc2";
    vendorHash = "sha256-SjkV+AXG2nEm0BJoDZAz649b1FcKNmHB6pwGAQfyzUs="; subPkgs = "./cmd/cdk";
    check = chk ''"$out/bin/cdk" --help'' "[Uu]sage"; };
  # cent (Apache-2.0): tool to handle Nuclei community templates.
  cent = pkg { pname = "cent"; version = "2.2.0"; src = gh "xm1k3/cent" "refs/tags/v2.2.0" "a8fe788dbb4c56fa763d891e62150fa8541c4ca8215f148a5f70891100f97a0f";
    vendorHash = "sha256-eZyIfDzkYhyOVyYKWxN3Mmlk+gg8S7OVlgJl6iOs1vw="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/cent" --help'' "[Uu]sage"; };
  # cero (MIT): scrape domain names from SSL certificates of arbitrary hosts.
  cero = pkg { pname = "cero"; version = "1.3.0"; src = gh "glebarez/cero" "v1.3.0" "7f3062df536105a98aa2fd06b6ce958f022c1bded4d86e971774ebd419cae2e7";
    vendorHash = "sha256-dbycM9jEdDgMN/EJblswXfLjCmeuGCD7MsRsaBu9iIM="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/cero" --help'' "[Uu]sage"; };
  # certgraph (GPL-2.0-only): intelligence tool to crawl the graph of certificate alternate names.
  certgraph = pkg { pname = "certgraph"; version = "0.1.3"; src = gh "lanrat/certgraph" "refs/tags/v0.1.3" "2f4cfc8bea214db05d958bc0faf468e97e646b0b2e6c9dba45f4ff122393cdc0";
    vendorHash = "sha256-D6FvtTwda9cfyjQtNyndrmXy8JnG5YK/YGm8WPba4nM="; subPkgs = "."; ldflags = "-w -s -X=main.version=0.1.3";
    check = chk ''"$out/bin/certgraph" --version'' "0\\.1\\.3"; };
  # certinfo (MIT): print x509 certificate info.
  certinfo = pkg { pname = "certinfo"; version = "1.0.40"; src = gh "pete911/certinfo" "v1.0.40" "7e07db7be0a24f1db15d69157da700da64e3e4b6f76a149d517312f03384b5e2";
    vendorHash = null; subPkgs = "."; ldflags = "-X main.Version=1.0.40";
    check = chk ''"$out/bin/certinfo" --version'' "1\\.0\\.40"; };
  # certstream-server-go (MIT): drop-in replacement in Golang for the certstream server by Calidog.
  certstream-server-go = pkg { pname = "certstream-server-go"; version = "1.10.1"; src = gh "d-Rickyy-b/certstream-server-go" "refs/tags/v1.10.1" "be62429873d0b376fb0f522a46e2bbcf15a2d013c87c10d13878ed29b4a7fcd4";
    vendorHash = "sha256-eOMYjKeUh15tgnB/sCv/En/ShdW8aZsblaRZ4wKHFec="; subPkgs = "./cmd/certpicker ./cmd/certstream-server-go"; ldflags = "-s -w";
    check = chk ''"$out/bin/certstream-server-go" --version'' "1\\.10\\.1"; };
  # cf-tool (MIT): codeforces CLI (Submit, Parse, Test, etc.). Support Contests, Gym, Groups, acmsguru, Windows, macOS, Linux, 7 MB.
  cf-tool = pkg { pname = "cf-tool"; version = "202405140250"; src = gh "sempr/cf-tool" "202405140250" "ec1933eb49300c84706a66a79a531c39a897009789764e8f1037c7759d2e5592";
    vendorHash = "sha256-ww8nCbRZuyP4wIH95nNhIF9RRCLzNx/2Zjd+9Ph8+R8="; subPkgs = ".";
    check = chk ''"$out/bin/cf" --help'' "[Uu]sage"; };
  # chamber (MIT): tool for managing secrets by storing them in AWS SSM Parameter Store.
  chamber = pkg { pname = "chamber"; version = "3.1.5"; src = gh "segmentio/chamber" "refs/tags/v3.1.5" "8658307013875044ddb023b5cf221085b4ecdfb3d093929443e636b8d1817e88";
    vendorHash = "sha256-yuIbTgtRp5Mhkzv6lOZYT7XMlUHmtcafzwafyv4h6oQ="; subPkgs = "."; ldflags = "-s -w -X main.Version=v3.1.5";
    check = chk ''"$out/bin/chamber" version'' "3\\.1\\.5"; };
  # changetower (MIT): tools to watch for webppage changes.
  changetower = pkg { pname = "changetower"; version = "1.0"; src = gh "Dc4ts/ChangeTower" "v1.0" "75de5858040bf14db26ab92dcf4b930f8eca3845a4c883a43cdb34efa811e954";
    vendorHash = "sha256-4aZzxjs/U/pts7nCvEiGtV1pC7Sf+knDfxxLxwLPYOk="; subPkgs = ".";
    check = chk ''"$out/bin/ChangeTower" --help'' "[Uu]sage"; };
  # charm-freeze (MIT): tool to generate images of code and terminal output.
  charm-freeze = pkg { pname = "charm-freeze"; version = "0.2.2"; src = gh "charmbracelet/freeze" "v0.2.2" "f0e959bc0c83c0a00d9da8362ca0d928191ad3207fc542c757e9eddda4014e08";
    vendorHash = "sha256-j3QfQIkgwItUzMkJPgcZLGXFkNkzINnfJCdddc02lzg="; subPkgs = "."; ldflags = "-s -w -X=main.Version=0.2.2";
    check = chk ''"$out/bin/freeze" --version'' "0\\.2\\.2"; };
  # checkip (Apache-2.0): CLI tool that checks an IP address using various public services.
  checkip = pkg { pname = "checkip"; version = "0.55.0"; src = gh "jreisinger/checkip" "refs/tags/v0.55.0" "92eb74dc62aa274fb1d5393efeab8ed77ab477b6391cd3b83a6f4a5ca5e42053";
    vendorHash = "sha256-ioiUmPkZkcklE27DUkPSc+EO7TlZ21Ehj8fh8w+yRJg="; subPkgs = "."; ldflags = "-w -s";
    check = chk ''"$out/bin/checkip" --help'' "[-]no-active"; };
  # chkbit (MIT): check your files for data corruption and run quick file deduplication.
  chkbit = pkg { pname = "chkbit"; version = "6.6.0"; src = gh "laktak/chkbit" "refs/tags/v6.6.0" "69a5c709d78604ed9d21b5439b2fbae96e21f729d7d36f417d50348dc9fdcc81";
    vendorHash = "sha256-OFo8HL7E4pUV1KyrPFKowvh25wB5vwE8miG+lMUOnq8="; subPkgs = "./cmd/chkbit ./scripts"; ldflags = "-s -w -X main.appVersion=6.6.0";
    check = chk ''"$out/bin/chkbit" version'' "6\\.6\\.0"; };
  # chopchop (Apache-2.0): CLI to search for sensitive services/files/folders.
  chopchop = pkg { pname = "chopchop"; version = "1.0.0"; src = gh "michelin/ChopChop" "v1.0.0" "3f8b487dd3bb4f758731eb60d64da8ae15b86baae8fc141b45e36fd2a21221e7";
    vendorHash = "sha256-skHRnxGRpTpWdCJL6ZVLF6cHPszbb9ymn8iy8+P9Eig="; subPkgs = ". ./tests";
    check = chk ''"$out/bin/gochopchop" --help'' "[Uu]sage"; };
  # cirrusgo (MIT): tool to scan SAAS and PAAS applications.
  cirrusgo = pkg { pname = "cirrusgo"; version = "0.1.0"; src = gh "Ph33rr/cirrusgo" "v0.1.0" "2888a8a8a85116f56cf92bc1b7e24b5b5a04e12158f5c7835b31e0c3eda6cb5e";
    vendorHash = "sha256-R/ttBjlG01t4DCrtLePfX3D1laXj5h4oWKy7a1BNN08="; subPkgs = "./cmd/cirrusgo";
    check = chk ''"$out/bin/cirrusgo" --version'' "0\\.1\\.0"; };
  # cloudbrute (MIT): cloud enumeration tool.
  cloudbrute = pkg { pname = "cloudbrute"; version = "1.0.7"; src = gh "0xsha/CloudBrute" "v1.0.7" "3130e7c3d2e85ee5d3b5c2d9e519849c6f52c286c65aeffc5a29b88648547727";
    vendorHash = "sha256-pnzdwWVHgIIiW5OJ5ae2bOZcXkUq4qVSSYY8Tphws/Y="; subPkgs = ".";
    check = chk ''"$out/bin/cloudbrute" --help'' "[Uu]sage"; };
  # cloudflare-dynamic-dns (MIT): dynamic DNS client for Cloudflare.
  cloudflare-dynamic-dns = pkg { pname = "cloudflare-dynamic-dns"; version = "4.5.13"; src = gh "zebradil/cloudflare-dynamic-dns" "refs/tags/4.5.13" "2107b9ddb7b757a5e2d9c3e0aeae6b04311c7968eacf19014315b4c7dea4c8af";
    vendorHash = "sha256-99YL3xURN7guD/DbQy7AhFwJix6We2F5CR2TVz/U2kU="; subPkgs = "."; ldflags = "-s -X=main.version=4.5.13 -X=main.commit=nixpkg-4.5.13 -X=main.date=1970-01-01";
    check = chk ''"$out/bin/cloudflare-dynamic-dns" --version'' "4\\.5\\.13"; };
  # cloudmonkey (Apache-2.0): CLI for Apache CloudStack.
  cloudmonkey = pkg { pname = "cloudmonkey"; version = "6.5.0"; src = gh "apache/cloudstack-cloudmonkey" "6.5.0" "bb491140103f0d8c178966355114f0eb9b35ad64323fba7448d475112d8847fc";
    vendorHash = null; subPkgs = ".";
    check = chk ''"$out/bin/cloudstack-cloudmonkey" version'' "6\\.5\\.0"; };
  # cloudprober (Apache-2.0): monitor availability and performance of various components of your system.
  cloudprober = pkg { pname = "cloudprober"; version = "0.14.3"; src = gh "cloudprober/cloudprober" "refs/tags/v0.14.3" "13c013f9c80abc011646f4c3e90bc9e68ed3d94ce6b2794934545d980060d5c5";
    vendorHash = "sha256-EFv+taXqmdJXtlJHfIUoUOf1eaoXZV/mHfbyB9zqe9Q="; subPkgs = "./cmd/cloudprober ./contrib/gcp/cmd ./internal/rds/client/cmd ./internal/rds/server/cmd ./internal/servers/udp/cmd ./prober/cmd ./probes/dns/cmd ./probes/external/cmd ./probes/http/cmd ./probes/ping/cmd ./probes/tcp/cmd ./probes/udp/cmd ./tools/genprotofacade";
    check = chk ''"$out/bin/cloudprober" --help'' "[Uu]sage"; };
  # clusterlint (Apache-2.0): best practices checker for Kubernetes clusters.
  clusterlint = pkg { pname = "clusterlint"; version = "0.15.0"; src = gh "digitalocean/clusterlint" "refs/tags/v0.15.0" "71e47fe52fdd71de38d13764b56642e482e613ded0acf85b6785c64b230d9cd9";
    vendorHash = null; subPkgs = "./cmd/clusterlint"; ldflags = "-X main.Version=0.15.0";
    check = chk ''"$out/bin/clusterlint" --version'' "0\\.15\\.0"; };
  # credential-detector (MIT): tool to detect potentially hard-coded credentials.
  credential-detector = pkg { pname = "credential-detector"; version = "1.14.6"; src = gh "ynori7/credential-detector" "v1.14.6" "759ed133804a2a46d13b1fdf7aea630dc5c8756b305a2f95f0f4750072525bfb";
    vendorHash = "sha256-YaaNm0JKUeOIEl/fMCfgL6aDHcGF0Sg7LHwfp+cA7oU="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/credential-detector" --help'' "[Uu]sage"; };
  # crictty (MIT): terminal-based cricket scorecard viewer.
  crictty = pkg { pname = "crictty"; version = "0.1.2"; src = gh "ashish0kumar/crictty" "refs/tags/v0.1.2" "59d58dd2d28f0149a5475ce4f7070cef1e0c40a222deb35695589ec7bda77ca9";
    vendorHash = "sha256-CyD2u7rVfE/zl9pb5C6Tgd4JH74d1TzN1n7GV78V59U="; subPkgs = "."; ldflags = "-s -w -X main.version=0.1.2";
    check = chk ''"$out/bin/crictty" --version'' "0\\.1\\.2"; };
  # crlfuzz (MIT): tool to scan for CRLF vulnerability.
  crlfuzz = pkg { pname = "crlfuzz"; version = "1.4.1"; src = gh "dwisiswant0/crlfuzz" "v1.4.1" "7ef3ea3890b501aab1507e2fd53cc6390cebafc6dbce5efca1faf03b967db8a3";
    vendorHash = "sha256-3bqGE3l5BSVozlCl2OBUNjqSZRIyoOg0Uhc8k8VppIQ="; subPkgs = "./cmd/crlfuzz";
    check = chk ''"$out/bin/crlfuzz" --help'' "[Uu]sage"; };
  # crypto-tracker (MIT): program to retrieve the latest price for several cryptocurrencies using the CoinMarketCap API.
  crypto-tracker = pkg { pname = "crypto-tracker"; version = "0.1.8"; src = gh "Nox04/crypto-tracker" "v0.1.8" "1b6963a72812c064081dc68a8a97930344c0464bdd2e4f93d2379c55129ba6cb";
    vendorHash = "sha256-qiNwJUTteb1EXTF2Bu9dgDY4aMp+pw9deASzVxVU1xo="; subPkgs = ".";
    check = chk ''"$out/bin/crypto-tracker" --help'' "[Uu]sage"; };
  # cryptoscan (Apache-2.0): cryptographic Discovery Scanner.
  cryptoscan = pkg { pname = "cryptoscan"; version = "1.5.0"; src = gh "csnp/cryptoscan" "refs/tags/v1.5.0" "02eeb6dba72c37c49ace81e868737c19ab13b9472d590cf7787075e31d9b99fe";
    vendorHash = "sha256-NK+2mc68ip8nArjnik1Ezhn6pwRBcE2P07q0MsRNPSI="; subPkgs = "./cmd/cryptoscan"; ldflags = "-s -X=main.version=1.5.0 -X=main.commit=refs/tags/v1.5.0 -X=main.date=1970-01-01T00:00:00Z";
    check = chk ''"$out/bin/cryptoscan" --version'' "1\\.5\\.0"; };
  # css-checker (MIT): command-line tool for identifying similar or duplicated CSS code.
  css-checker = pkg { pname = "css-checker"; version = "0.4.1"; src = gh "ruilisi/css-checker" "v0.4.1" "f4505129517eafd53881562743b9c461b5c0c2acfc38a43f694787e65d8492f2";
    vendorHash = "sha256-Wm5Hbhc4jbxrr4Tp0Mj6szhLMSTVlK9jlI5mRhWkBv8="; subPkgs = ". ./build"; ldflags = "-s -w";
    check = chk ''"$out/bin/css-checker" --version'' "0\\.4\\.1"; };
  # cw (Apache-2.0): best way to tail AWS CloudWatch Logs from your terminal.
  cw = pkg { pname = "cw"; version = "4.1.1"; src = gh "lucagrulla/cw" "v4.1.1" "49542e32cdf910a5bbebda1c841a1fac11c4224ef23c8b35cc4632b1bdb788a8";
    vendorHash = "sha256-91os1wWNa6Q1ZUwz94d9EmETlypge7XJGCj03uhSiZM="; subPkgs = ".";
    check = chk ''"$out/bin/cw" --version'' "4\\.1\\.1"; };
  # damon (MPL-2.0): terminal UI (TUI) for HashiCorp Nomad.
  damon = pkg { pname = "damon"; version = "0-unstable-2021-10-06"; src = gh "hashicorp/damon" "542c79aecc44b1d0500f9cb9b2e13f07db1e2f35" "212e4960c42906ab1ab63874f3ac9d416d941b4f86bf9b30b7324ca8d8b8e7ba";
    vendorHash = "sha256-3JD4vVAr5mWoS0XDQfhWoAjvRBxXEs6T9FKe/gPz+tU="; subPkgs = "./cmd/damon";
    check = chk ''"$out/bin/damon" --help'' "[Uu]sage"; };
  # dcrctl (ISC): secure Decred wallet daemon written in Go (golang).
  dcrctl = pkg { pname = "dcrctl"; version = "1.8.0"; src = gh "decred/dcrctl" "release-v1.8.0" "f8aef35e02d5f28f8c67f1424dfc008f0bc203b2abcda129b7550f5a84faa2a6";
    vendorHash = "sha256-1cZpXylStK36igTvHTF1JLYFUkuShXifLePstGaBdfA="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/dcrctl" --version'' "1\\.8\\.0"; };
  # dcrd (ISC): decred daemon in Go (golang).
  dcrd = pkg { pname = "dcrd"; version = "2.1.5"; src = gh "decred/dcrd" "refs/tags/release-v2.1.5" "9723576d4fe163e684877b794eee0ce6642fdb5ba53f2ea43ec53d54e3062152";
    vendorHash = "sha256-OHb03k7Gl2DpFnziY/h5vQMTyf8YBEY2IR/DVAOC+1s="; subPkgs = ". ./cmd/promptsecret";
    check = chk ''"$out/bin/dcrd" --version'' "2\\.1\\.5"; };
}
