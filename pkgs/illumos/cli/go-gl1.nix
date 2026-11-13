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
  # dcrwallet (ISC): secure Decred wallet daemon written in Go (golang).
  dcrwallet = pkg { pname = "dcrwallet"; version = "2.1.7"; src = gh "decred/dcrwallet" "release-v2.1.7" "30d4d49420c33242a0ea11e71802d02c467c6c4ee4c8dd7206e4ae5d9c13b633";
    vendorHash = "sha256-/3Jodzmc8t4t/WzGfzh0wclHvdeWA9pG4MQy36gCdso="; subPkgs = ".";
    check = chk ''"$out/bin/dcrwallet" --version'' "2\\.1\\.7"; };
  # ddns-go (MIT): simple and easy to use DDNS.
  ddns-go = pkg { pname = "ddns-go"; version = "6.17.7"; src = gh "jeessy2/ddns-go" "v6.17.7" "f7001004e092d9641aad5a94158e0b4cae4a53a7f5c7d96d5c6af3d246c56fcc";
    vendorHash = "sha256-jYwaltjaSgS6AmtodeVVFCP7ErkosguP0tTNMTnDT98="; subPkgs = "."; ldflags = "-X main.version=6.17.7";
    check = chk ''"$out/bin/ddns-go" --help'' "[Uu]sage"; };
  # der-ascii (Apache-2.0): small human-editable language to emit DER or BER encodings of ASN.1 structures and malformed variants of them.
  der-ascii = pkg { pname = "der-ascii"; version = "0.8.0"; src = gh "google/der-ascii" "v0.8.0" "1ab23597139a6e006efc38e1105b81bf8ca2486c3fab42be7a9ccabb8a1aef2a";
    vendorHash = null; subPkgs = "./cmd/ascii2der ./cmd/der2ascii"; ldflags = "-s -w";
    check = chk ''"$out/bin/ascii2der" --help'' "[Uu]sage"; };
  # deterministic-zip (GPL-3.0-only): simple (almost drop-in) replacement for zip that produces deterministic files.
  deterministic-zip = pkg { pname = "deterministic-zip"; version = "6.1.0"; src = gh "timo-reymann/deterministic-zip" "refs/tags/6.1.0" "1062573b4e5857f181e71c329ff1933aca20d1875620b901884ab6068ccd7982";
    vendorHash = "sha256-WyqhMIDRnuZz7v9evL+YSOHr7sXGFvzuMYDcOLu1ig4="; subPkgs = "."; ldflags = "-s -X github.com/timo-reymann/deterministic-zip/pkg/buildinfo.GitSha=refs/tags/6.1.0 -X github.com/timo-reymann/deterministic-zip/pkg/buildinfo.Version=6.1.0";
    check = chk ''"$out/bin/deterministic-zip" --version'' "6\\.1\\.0"; };
  # diskbloom (Apache-2.0): A pastel treemap TUI that shows what's eating your disk.
  diskbloom = pkg { pname = "diskbloom"; version = "0.1.0"; src = gh "Zingzy/diskbloom" "refs/tags/v0.1.0" "b0fa7c67c17251423b7e89fecf4c4d1f3722537a0049ba2771d90e24d0c8ebad";
    vendorHash = "sha256-P+HVCvcyp3yIOHpGo2ZwyoBUt0Ia35SjKn8fn9ZGw6M="; subPkgs = "."; ldflags = "-s -w -X main.version=0.1.0";
    check = chk ''"$out/bin/diskbloom" --version'' "0\\.1\\.0"; };
  # dismap (GPL-3.0-only): asset discovery and identification tools.
  dismap = pkg { pname = "dismap"; version = "0.4"; src = gh "zhzyker/dismap" "v0.4" "c381f4974a3cc9a4a748e5829c8d811eedf117f5a03563e33ed796d337652626";
    vendorHash = "sha256-oOxMS93tBRFP1E4pXj1ky7Xp2Daj/8s0ejts+qVNCM0="; subPkgs = "./cmd/dismap";
    check = chk ''"$out/bin/dismap" --version'' "0\\.4"; };
  # dismember (MIT): tool to scan memory for secrets.
  dismember = pkg { pname = "dismember"; version = "0.0.1"; src = gh "liamg/dismember" "refs/tags/v0.0.1" "7f78d5f986b97ee81f7b74f678e7bd6e4c48e83057778ee6d6e09d154ce5a45d";
    vendorHash = "sha256-Rkj/KRnCRXgIJm9YE/NCDchQw1/x+3vG/p4qjWtccHI="; subPkgs = ".";
    check = chk ''"$out/bin/dismember" --help'' "[Uu]sage"; };
  # dli (MIT): CLI based tool for managing DNS records.
  dli = pkg { pname = "dli"; version = "0-unstable-2025-09-06"; src = gh "haylinmoore/dli" "176302f80cf771a7a15d9df58c3296a979f18e28" "9d5b81f18d5c936a1819a7fbe8e48aeb5221b3e31af003038a0c02997c532c05";
    vendorHash = "sha256-Gc2LKv6lbNtAJPR4c4f2Ollf474Gl583EMLWc7WN15I="; subPkgs = ".";
    check = chk ''"$out/bin/dli" --help'' "[Uu]sage"; };
  # dns-over-https (MIT): high performance DNS over HTTPS client & server.
  dns-over-https = pkg { pname = "dns-over-https"; version = "2.3.10"; src = gh "m13253/dns-over-https" "refs/tags/v2.3.10" "9df05f730099ca1a7bae506a1532a3876a74c87e74a0e7a19c97d2363cbdfefb";
    vendorHash = "sha256-TD9GDGsCTBOd+tDrk5sPGZWWcAruKF7dwkasfdulN54="; subPkgs = "./doh-client ./doh-server"; ldflags = "-w -s";
    check = chk ''"$out/bin/doh-client" --version'' "2\\.3\\.10"; };
  # dnss (Apache-2.0): daemon for using DNS over HTTPS.
  dnss = pkg { pname = "dnss"; version = "0-unstable-2024-03-17"; src = gh "albertito/dnss" "da8986dd432870f5710e3e8652c92c95f34b830b" "ef914bd61a2f425adc39c03f40bb6968d39917f94150ff2356ea79efb1cad816";
    vendorHash = "sha256-bVD7gMNvbzdKcX0FxqgjprZiKHRtJr97wZ0AclWYiEM="; subPkgs = ".";
    check = chk ''"$out/bin/dnss" --help'' "[Uu]sage"; };
  # dnstake (MIT): tool to check missing hosted DNS zones.
  dnstake = pkg { pname = "dnstake"; version = "0.1.1"; src = gh "pwnesia/dnstake" "refs/tags/v0.1.1" "23e30d180026ae2713504172322f4140082718510a91c985e53b0b98c030fcd4";
    vendorHash = "sha256-Axlhv0G7nfRvCpPBUlJtO5jaK/xfjub3i44q5/ucg4s="; subPkgs = "./cmd/dnstake";
    check = chk ''"$out/bin/dnstake" --version'' "0\\.1\\.1"; };
  # doc2go (Apache-2.0 / BSD-3-Clause): your Go project's documentation, to-go.
  doc2go = pkg { pname = "doc2go"; version = "0.12.1"; src = gh "abhinav/doc2go" "v0.12.1" "600437b096b8b51190c679f63340a75a8507210666ee6285c267c132e6e02515";
    vendorHash = "sha256-2ZXIxNBb+NCyTudSMsXP7SbvcrozctP47/NjYq6xsIA="; subPkgs = "."; ldflags = "-s -w -X main._version=0.12.1";
    check = chk ''"$out/bin/doc2go" --version'' "0\\.12\\.1"; };
  # docker-credential-env (MIT): environment-driven docker credential helper.
  docker-credential-env = pkg { pname = "docker-credential-env"; version = "1.7.0"; src = gh "isometry/docker-credential-env" "refs/tags/v1.7.0" "96745058f2979ee954cdd9cc37ab59c975502b2886f652988539f1b2cda9b21c";
    vendorHash = "sha256-TEc5P3jU9zRFa9pBuE2gaqGby1g/o/AFZMF4B9batWA="; subPkgs = "."; ldflags = "-s -X=github.com/docker/docker-credential-helpers/credentials.Name=docker-credential-env -X=github.com/docker/docker-credential-helpers/credentials.Package=github.com/isometry/docker-credential-env -X=github.com/docker/docker-credential-helpers/credentials.Version=1.7.0 -X=github.com/docker/docker-credential-helpers/credentials.Revision=v1.7.0";
    check = chk ''"$out/bin/docker-credential-env" --version'' "1\\.7\\.0"; };
  # dockfmt (MIT): dockerfile format.
  dockfmt = pkg { pname = "dockfmt"; version = "0.3.3-unstable-2020-09-17"; src = gh "jessfraz/dockfmt" "1455059b8bb53ab4723ef41946c43160583a8333" "21fe11c47ab7d3612a7bed1881d3e404e65df6991629b4fd84c7c5d87c20327d";
    vendorHash = null; subPkgs = "."; ldflags = "-w -s -X github.com/jessfraz/dockfmt/version.VERSION=0.3.3-unstable-2020-09-17";
    check = chk ''"$out/bin/dockfmt" version'' "0\\.3\\.3-unstable-2020-09-17"; };
  # dorkscout (Apache-2.0): tool to automate the work with Google dorks.
  dorkscout = pkg { pname = "dorkscout"; version = "1.0"; src = gh "R4yGM/dorkscout" "1.0" "ac3c7813d84e90818bf93fbefb4176386681ce8bbe021b0b2d44362290786d00";
    vendorHash = "sha256-sf50xikjTuH61+kBZJjWbNCW5Xu5StGj8yKDbzDLIes="; subPkgs = ".";
    check = chk ''"$out/bin/dorkscout" --help'' "[Uu]sage"; };
  # drift (MIT): terminal screensaver that turns idle time into ambient art.
  drift = pkg { pname = "drift"; version = "1.3.0"; src = gh "phlx0/drift" "refs/tags/v1.3.0" "6c8545a667ff3ede2093a042c21f6dd0034916ed43d5c37180ec9ebca3d7a350";
    vendorHash = "sha256-axQsrGooz7Zk774/5GQmXBFD3he0tlEZhNoHyVv62vM="; subPkgs = "."; ldflags = "-s -X=main.version=1.3.0 -X=main.commit=v1.3.0 -X=main.date=1970-01-01T00:00:00Z";
    check = chk ''"$out/bin/drift" version'' "1\\.3\\.0"; };
  # dstp (MIT): run common networking tests against your site.
  dstp = pkg { pname = "dstp"; version = "0.4.23"; src = gh "ycd/dstp" "v0.4.23" "1ab45012204cd68129fd05723dd768ea4a9ce08e2f6c2fa6468c2c88ab65c877";
    vendorHash = "sha256-/R89n5B3jIk9M7B+WYMLxyT3avGbRhTTBlaYlf+kNCM="; subPkgs = "./cmd/dstp";
    check = chk ''"$out/bin/dstp" --help'' "[Uu]sage"; };
  # duckling-proxy (MIT): gemini proxy to access the Small Web.
  duckling-proxy = pkg { pname = "duckling-proxy"; version = "0.2.1-unstable-2021-07-23"; src = gh "LukeEmmet/duckling-proxy" "e2bfd73a60d7afa43f13a9d420d514131fee8fd1" "91857d77dfcd15785add8e62b4efe37a9d31e56f956ca3f84e3ce548ae9097d4";
    vendorHash = "sha256-DRDAbNdoqhJON1P7t/5d8SLwbUGk3eecQM5saBfyiNA="; subPkgs = ".";
    check = chk ''"$out/bin/duckling-proxy" --help'' "[Uu]sage"; };
  # e1s (MIT): easily Manage AWS ECS Resources in Terminal.
  e1s = pkg { pname = "e1s"; version = "2.0.0"; src = gh "keidarcy/e1s" "refs/tags/v2.0.0" "d2846602a86b245ca85e0f80d3a02f5cdeb6320d12b87189894f1cfc5531ac28";
    vendorHash = "sha256-j7e4mnxzWbmv+FWy8KvcVz8Yz/CMEnrEhO9Z5yK/534="; subPkgs = "./cmd/e1s";
    check = chk ''"$out/bin/e1s" --version'' "2\\.0\\.0"; };
  # lexido (AGPL-3.0-only): terminal assistant, powered by Generative AI.
  lexido = pkg { pname = "lexido"; version = "1.4.3"; src = gh "micr0-dev/lexido" "v1.4.3" "c39cf8f93cce2480773c9099ece1d8a90c1e350cf48cad56eebea96fbc04981f";
    vendorHash = "sha256-Tf6eePB0+P6jzGuYGELDJ7rvvBO0X+aItYhaA9W8lx0="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/lexido" --version'' "1\\.4\\.3"; };
  # license-scanner (Apache-2.0): utility that provides an API and CLI to identify licenses and legal terms.
  license-scanner = pkg { pname = "license-scanner"; version = "0.12.0"; src = gh "CycloneDX/license-scanner" "refs/tags/v0.12.0" "0682560617d2481f7070dc2ed389bafad2ff6a23eb5074a65f49f24c3ad2142c";
    vendorHash = "sha256-jM4QIOyHMTU6gmFxTjC+SgKNdtqu/6K/c8UfS9BAFFo="; subPkgs = ".";
    check = chk ''"$out/bin/license-scanner" --help'' "[Uu]sage"; };
  # lmp (GPL-3.0-only): scanning and validation toolkit for the Log4J vulnerability.
  lmp = pkg { pname = "lmp"; version = "2.0"; src = gh "0xInfection/LogMePwn" "v2.0" "ab20121e54be694f42ebf2e1c4988b02f333fd8dcafc0a726dbfd725c1cf8f71";
    vendorHash = "sha256-eGMbSsuF1dXWhXdr2H3/y+jovLYzNdmqE2VYnfeIRVs="; subPkgs = ".";
    check = chk ''"$out/bin/lmp" --version'' "2\\.0"; };
  # ls-lint (MIT): extremely fast file and directory name linter.
  ls-lint = pkg { pname = "ls-lint"; version = "2.3.1"; src = gh "loeffel-io/ls-lint" "v2.3.1" "ea6b53fb2bf13055e1cd5eb4aeeddc883044e859a617adebd1802181cdb44b14";
    vendorHash = "sha256-B+VQ4dSl2DDkSbvceCX/rzmYAV2lir6ejHEiYnaGObE="; subPkgs = "./cmd/ls_lint";
    check = chk ''"$out/bin/ls_lint" --help'' "[-]error-output-format"; };
  # lsh (MIT): command-Line Interface for Latitude.sh.
  lsh = pkg { pname = "lsh"; version = "1.7.0"; src = gh "latitudesh/cli" "v1.7.0" "cc73c0050b96850654510ba2801b95305b3151b0b03e77923e096d3fe2433984";
    vendorHash = "sha256-gCcU95ln28jDJTHgD72pO94vGDWpxs5ELzKtzKQp87c="; subPkgs = ".";
    check = chk ''"$out/bin/lsh" --help'' "[Uu]sage"; };
  # lwc (MIT): live-updating version of the UNIX wc command.
  lwc = pkg { pname = "lwc"; version = "0.4.5-unstable-2022-07-26"; src = gh "timdp/lwc" "3330928c9d82200837350f85335f5e6c09f0658b" "03aca8c331295a30ad41cd8fac1f30e08ceeed322235be18e1fc6ebe39d8bab4";
    vendorHash = "sha256-FKTugB3Jgn19YTRDq5YJC8+BSr1usKGV4GPlhSDmGCQ="; subPkgs = "./cmd/lwc"; ldflags = "-s -X=main.version=3330928c9d82200837350f85335f5e6c09f0658b";
    check = chk ''"$out/bin/lwc" --help'' "[-]-max-line-length"; };
  # maildir-rank-addr (MIT): generate a ranked addressbook from a maildir folder.
  maildir-rank-addr = pkg { pname = "maildir-rank-addr"; version = "1.4.1"; src = gh "ferdinandyb/maildir-rank-addr" "refs/tags/v1.4.1" "5536cbfd0dd1f686dbe0bcf6a45d3c62659e5d7172b5df8ca3d257a6bf66b6cd";
    vendorHash = "sha256-U5XuY6S22e/tGtI4dIW+UMkmTZRcRUVMCnYHCYSIXoY="; subPkgs = ".";
    check = chk ''"$out/bin/maildir-rank-addr" --help'' "[-]-addr-book-add-unmatched"; };
  # mantra (GPL-3.0-only): tool used to hunt down API key leaks in JS files and pages.
  mantra = pkg { pname = "mantra"; version = "3.1"; src = gh "brosck/Mantra" "refs/tags/v3.1" "379894f36ef04a6b4e57e77112070e23dcc75569d1df98a8f128fe24a8b5e0b1";
    vendorHash = null; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/mantra" version'' "3\\.1"; };
  # marathonctl (MIT): CLI tool for Marathon.
  marathonctl = pkg { pname = "marathonctl"; version = "0.0.7"; src = gh "shoenig/marathonctl" "v0.0.7" "874d1f2c249184dda3c153940f945068253e590f5989d528a19ba84e116fd909";
    vendorHash = "sha256-eNo47uUgrQ7y6AtHqpywsFEhkli4ei234U+dTE5vEG0="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/marathonctl" --help'' "[Uu]sage"; };
  # markscribe (MIT): your personal markdown scribe with template-engine and Git(Hub) & RSS powers.
  markscribe = pkg { pname = "markscribe"; version = "0.6.0"; src = gh "muesli/markscribe" "v0.6.0" "3f414311426038e27e8b03d8892f4c485f10d068ba96a75bf2fd1cf23f20c22e";
    vendorHash = "sha256-yY6Ms213qU0tjxiKj/HgjS1lkhgYDDuftxv/lSj5Pec="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/markscribe" --help'' "[Uu]sage"; };
  # mastotool (MIT): collection of command-line tools to work with your Mastodon account.
  mastotool = pkg { pname = "mastotool"; version = "0.2.4"; src = gh "muesli/mastotool" "v0.2.4" "df66e3122f1ba0cdd4d682a3751339e56181f0fab94800082e031c620848b23a";
    vendorHash = "sha256-BDxnVAlgKYF++c8TkAGxuw8wLRMdzG5Od7TTwyuq93o="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/mastotool" --help'' "[Uu]sage"; };
  # matrix-corporal (AGPL-3.0-only): reconciliator and gateway for a managed Matrix server.
  matrix-corporal = pkg { pname = "matrix-corporal"; version = "2.2.0"; src = gh "devture/matrix-corporal" "2.2.0" "0aa5eb983e792de6011f52763762ede3322149fadf5e89c496123baee8e95af2";
    vendorHash = "sha256-orjwfTsJaaZj1jpL+hnn06qDqRWSdZokcN02j7e8Vx4="; subPkgs = "."; ldflags = "-s -w -X main.GitCommit=2.2.0 -X main.GitBranch=2.2.0 -X main.GitState=nixpkgs -X main.GitSummary=2.2.0 -X main.Version=2.2.0";
    check = chk ''"$out/bin/devture-matrix-corporal" --version'' "2\\.2\\.0"; };
  # mdschema (MIT): A declarative schema-based Markdown validator that helps maintain consistent documentation structure across projects.
  mdschema = pkg { pname = "mdschema"; version = "0.15.5"; src = gh "jackchuka/mdschema" "refs/tags/v0.15.5" "0d54eb1abaeb0c23b45d61a1398f0eafea3ba0cfd6e22a6b78cda0b1f5df1526";
    vendorHash = "sha256-6VRBh84nAy++ZbNn8JPYALXEDRkfnlvMYUGRK60JvZc="; subPkgs = "./cmd/mdschema"; ldflags = "-s -w -X=github.com/jackchuka/mdschema/internal/version.Version=0.15.5 -X=github.com/jackchuka/mdschema/internal/version.Commit=refs/tags/v0.15.5 -X=github.com/jackchuka/mdschema/internal/version.Date=1970-01-01T00:00:00Z";
    check = chk ''"$out/bin/mdschema" version'' "0\\.15\\.5"; };
  # meg (MIT): fetch many paths for many hosts without flooding hosts.
  meg = pkg { pname = "meg"; version = "0.3.0"; src = gh "tomnomnom/meg" "v0.3.0" "55f8928d048f5a8204ff2bc353fbbcb1954daa7b199ef7068217f99310086aa8";
    vendorHash = "sha256-13Kce9x2yCHBBLFJFP0o6PVVxsdqKhZX7IMeFj0VQCM="; subPkgs = ".";
    check = chk ''"$out/bin/meg" --help'' "[Uu]sage"; };
  # melt (MIT): backup and restore Ed25519 SSH keys with seed words.
  melt = pkg { pname = "melt"; version = "0.6.2"; src = gh "charmbracelet/melt" "v0.6.2" "e6e7d1f3eba506ac7e310bbc497687e7e4e457fa685843dcf1ba00349614bfdc";
    vendorHash = "sha256-DINZkZc/tsEi1+XiYprx/cyDmafjVBHiBfI5/Hr0U70="; subPkgs = "./cmd/melt"; ldflags = "-s -w -X=main.Version=0.6.2";
    check = chk ''"$out/bin/melt" --help'' "[Uu]sage"; };
  # meme-image-generator (MIT): command line utility for creating image macro style memes.
  meme-image-generator = pkg { pname = "meme-image-generator"; version = "1.0.2"; src = gh "nomad-software/meme" "v1.0.2" "de332ca1827868fabd67f28148d17560d34e9dc103e0fc89875ab4688af550d9";
    vendorHash = null; subPkgs = ".";
    check = chk ''"$out/bin/meme" --help'' "[Uu]sage"; };
  # mesos-dns (Apache-2.0): DNS-based service discovery for Mesos.
  mesos-dns = pkg { pname = "mesos-dns"; version = "0.10.1"; src = gh "m3scluster/mesos-dns" "refs/tags/v0.10.1" "0f61085bf2fdc4e9bea8c60be269517817975299d2f797b7847206abcc26d464";
    vendorHash = "sha256-QdFdS27n/kY4m3MqT/5p1QSFmuOCsxpeXquVGn51hVw="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/mesos-dns" --help'' "[Uu]sage"; };
  # metabigor (MIT): tool to perform OSINT tasks.
  metabigor = pkg { pname = "metabigor"; version = "2.2.0"; src = gh "j3ssie/metabigor" "refs/tags/v2.2.0" "865d5940c157894d707be83cc4eb34f6f18b4e716f460259f823aa322e616407";
    vendorHash = "sha256-HidEzXuLeV9IcxJX3A/k00JC1mH0NIzJF/nxcsW3sug="; subPkgs = "./cmd/metabigor"; ldflags = "-s";
    check = chk ''"$out/bin/metabigor" --version'' "2\\.2\\.0"; };
  # micromdm (MIT): mobile Device Management server for Apple Devices, focused on giving you all the power through an API.
  micromdm = pkg { pname = "micromdm"; version = "1.13.1"; src = gh "micromdm/micromdm" "v1.13.1" "44212fe9ca0376b9ee5b61b7c5a74c488a746e2952ed238bd0bdad8e9140e4bd";
    vendorHash = "sha256-98P+JDILj4tIOzkqEx6BBR4MwbwNYLL61rthWxfEVr4="; subPkgs = "./cmd/mdmctl ./cmd/micromdm";
    check = chk ''"$out/bin/micromdm" --help'' "[Uu]sage"; };
  # minio-certgen (BSD-3-Clause): simple Minio tool to generate self-signed certificates, and provides SAN certificates with DNS and IP entries.
  minio-certgen = pkg { pname = "minio-certgen"; version = "1.4.0"; src = gh "minio/certgen" "v1.4.0" "b8465a146d55da55fbe349adfb7939d69acbdf0a9a63062f587b63d687f6ab54";
    vendorHash = null; subPkgs = ".";
    check = chk ''"$out/bin/certgen" --help'' "[-]common-name"; };
  # misconfig-mapper (MIT): tool to uncover security misconfigurations on popular third-party services.
  misconfig-mapper = pkg { pname = "misconfig-mapper"; version = "1.19.0"; src = gh "intigriti/misconfig-mapper" "refs/tags/v1.19.0" "41274e2d921c651bb7e3dd604ec9ea14a9327d621fdf734502f657a1f7ee2ac8";
    vendorHash = "sha256-R+H1KFp/bVs+llt7DVATzUW6zfLC27NbpaTrBGyAaT8="; subPkgs = "./cmd/misconfig-mapper"; ldflags = "-s -w";
    check = chk ''"$out/bin/misconfig-mapper" --help'' "[-]skip-misconfiguration-checks"; };
  # mkbrr (GPL-2.0-or-later): tool to create, modify and inspect torrent files.
  mkbrr = pkg { pname = "mkbrr"; version = "1.25.0"; src = gh "autobrr/mkbrr" "refs/tags/v1.25.0" "8ae71c48e7615b6753f3d10dc255ecc6a41985a000b263f2d69aac467afb4fdc";
    vendorHash = "sha256-er5l36k/jS2hXlRD+qLpY5XseG2elH4TykHjnDA9uxY="; subPkgs = "."; ldflags = "-s -w -X main.version=v1.25.0 -X main.buildTime=unknown";
    check = chk ''"$out/bin/mkbrr" version'' "1\\.25\\.0"; };
  # mmv-go (MIT): rename multiple files using your $EDITOR.
  mmv-go = pkg { pname = "mmv-go"; version = "0.1.6"; src = gh "itchyny/mmv" "v0.1.6" "18d181e6a53437ad18c4409f3c423bc23687152a17b53a605dde13dfffb0d215";
    vendorHash = "sha256-T7Jnr2PxoZqtjSWvrnbxEaXdd3zMzpdYhLSyZXgt8dc="; subPkgs = "./cmd/mmv"; ldflags = "-s -w -X main.revision=v0.1.6";
    check = chk ''"$out/bin/mmv" --version'' "0\\.1\\.6"; };
  # moji (MIT): find and download fonts from the terminal.
  moji = pkg { pname = "moji"; version = "0.8.0"; src = gh "Microck/moji" "refs/tags/v0.8.0" "43989e70b8dba28180e5a9bbbc51c833d74a4ebe652a2a263b266d8eea9983f4";
    vendorHash = "sha256-iG88IOx5cJubfgehi3TfShPMwWgIiEScBH0XoCLN3gE="; subPkgs = "./cmd/moji"; ldflags = "-s -X github.com/microck/moji/internal/app.Version=0.8.0 -X github.com/microck/moji/internal/app.ReleaseMarker=moji-release-version:0.8.0:moji-marker-end";
    check = chk ''"$out/bin/moji" --version'' "0\\.8\\.0"; };
  # moq (MIT): interface mocking tool for go generate.
  moq = pkg { pname = "moq"; version = "0.8.1"; src = gh "matryer/moq" "v0.8.1" "30368b3bd1e9ae523b983c07ddc3ded6fe4865d2b027de09c72cf47a74928bfc";
    vendorHash = "sha256-PJKQQgEQst6qpsPsjqydqQKJ0LmInlcG5H8174d3Rfk="; subPkgs = "."; ldflags = "-s -w -X main.Version=0.8.1";
    check = chk ''"$out/bin/moq" --version'' "0\\.8\\.1"; };
  # mpls (Apache-2.0): live preview of markdown using Language Server Protocol.
  mpls = pkg { pname = "mpls"; version = "0.23.0"; src = gh "mhersson/mpls" "refs/tags/v0.23.0" "78c7c6290813378783df1c227b1c9c540be1ae75c55c20cb680da87f88252cb5";
    vendorHash = "sha256-3Sldpqmnyvujgo7hXBphqoIqH9Hcfb7UmJtq99fSv3Q="; subPkgs = "."; ldflags = "-s -w -X github.com/mhersson/mpls/cmd.Version=0.23.0 -X github.com/mhersson/mpls/internal/mpls.Version=0.23.0";
    check = chk ''"$out/bin/mpls" --version'' "0\\.23\\.0"; };
  # mqtt-benchmark (Apache-2.0): MQTT broker benchmarking tool.
  mqtt-benchmark = pkg { pname = "mqtt-benchmark"; version = "0.2.0"; src = gh "krylovsk/mqtt-benchmark" "refs/tags/v0.2.0" "0ee1ca4fe52ec51fc13effd90fb190e74cee4a31d462b03217cef2f9ca84083b";
    vendorHash = "sha256-uXyhmfGU0RsdvYUYKhvZg2aWcJi76MkfmP86aiyRZcg="; subPkgs = ".";
    check = chk ''"$out/bin/mqtt-benchmark" --help'' "[-]message-interval"; };
  # mssqlhound (Apache-2.0): go collector for adding MSSQL attack paths to BloodHound with OpenGraph.
  mssqlhound = pkg { pname = "mssqlhound"; version = "2.0.4"; src = gh "SpecterOps/MSSQLHound" "refs/tags/v2.0.4" "862ddce8dbf1fa6838e2f949a1c9967fa9de7d301705e7cb6e72dafaa9e41436";
    vendorHash = "sha256-wMDXvYjYMWRqnJvXW3wgmnuRiFK1ZBBqwQKVos4tn/s="; subPkgs = "./cmd/mssqlhound";
    check = chk ''"$out/bin/mssqlhound" --version'' "2\\.0\\.4"; };
  # mtr-exporter (BSD-3-Clause): mtr-exporter periodically executes mtr to a given host and provides the measured results as prometheus metrics.
  mtr-exporter = pkg { pname = "mtr-exporter"; version = "0.7.0"; src = gh "mgumz/mtr-exporter" "0.7.0" "34e5afa79eea8f10c3a90d0914d19d9438971f1e0d11a81ac48e56d38e6a475f";
    vendorHash = null; subPkgs = "./cmd/mtr-exporter";
    check = chk ''"$out/bin/mtr-exporter" --help'' "[Uu]sage"; };
  # mufetch (MIT): neofetch-style CLI for music metadata with album art display.
  mufetch = pkg { pname = "mufetch"; version = "0.1.1"; src = gh "ashish0kumar/mufetch" "refs/tags/v0.1.1" "c6cba3e87e21809c640e540d396d3f72bdaa4fd42fdb79de43ada7cd6a589f0e";
    vendorHash = "sha256-guNbRX/rdrZvaJ37cRB/v3SV3wrLQnHiOLAq2vC2CIw="; subPkgs = "."; ldflags = "-s -w -X github.com/ashish0kumar/mufetch/cmd.version=0.1.1";
    check = chk ''"$out/bin/mufetch" --version'' "0\\.1\\.1"; };
  # muffet (MIT): website link checker which scrapes and inspects all pages in a website recursively.
  muffet = pkg { pname = "muffet"; version = "2.11.7"; src = gh "raviqqe/muffet" "refs/tags/v2.11.7" "21e96ba16b1b0de1d2bee16dafad4c1a5996fc6e0f550edc1377ab791421716a";
    vendorHash = "sha256-M2q2lH2Kz1eXoOauFzglgGToylAaMA4MbFAvU7JoXUI="; subPkgs = ".";
    check = chk ''"$out/bin/muffet" --version'' "2\\.11\\.7"; };
  # mullvad-compass (Unlicense): find the best Mullvad VPN server to connect to.
  mullvad-compass = pkg { pname = "mullvad-compass"; version = "0.0.4"; src = gh "Ch00k/mullvad-compass" "refs/tags/0.0.4" "bdd9f4c6b858c9dfac31ad1c590d701560a200a4c613ee1f73ddcf1e8c68d64c";
    vendorHash = "sha256-O3OyOlr+lVofUrFdnHU07BGuSRL3Wk9lKmMpdHDr/9U="; subPkgs = "./cmd/mullvad-compass"; ldflags = "-s -w -X main.Version=0.0.4";
    check = chk ''"$out/bin/mullvad-compass" --version'' "0\\.0\\.4"; };
  # mx-takeover (MIT): tool to work with DNS MX records.
  mx-takeover = pkg { pname = "mx-takeover"; version = "0.1.1"; src = gh "musana/mx-takeover" "refs/tags/v0.1.1" "98f067e99d82b0fe57ed8605985d6a48b4bfee34e6cbc90ce221c52bbbe151fb";
    vendorHash = "sha256-eUCBTSt3Gss1BZRqWiPiRd4Ep8uafB7oFpCAijlC7z0="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/mx-takeover" --help'' "[-]show-only-mx"; };
  # mynewt-newt (Apache-2.0): build and package management tool for embedded development.
  mynewt-newt = pkg { pname = "mynewt-newt"; version = "1.15.0"; src = gh "apache/mynewt-newt" "mynewt_1_15_0_tag" "cb9619f4c0dd567b893cb6e48898f30a6e467fe174da18adb91a1c0da391b000";
    vendorHash = "sha256-2I7fG06M+7Q+9YQ52MPwPSYx8miIY5YDlunS8Hg2vtg="; subPkgs = "./newt ./newtvm";
    check = chk ''"$out/bin/newt" version'' "1\\.15\\.0"; };
  # nexusd (MIT): full-feature WAMP v2 router written in Go.
  nexusd = pkg { pname = "nexusd"; version = "3.3.1"; src = gh "gammazero/nexus" "v3.3.1" "806bf9fad1078e0ca7161cc7b1b2319f9185328527eb7649f1e10c58e9128b83";
    vendorHash = "sha256-NzO4YlmBHqaKOCPvJcZkh0ncVpdJsjKFyxSQWpQ7ktI="; subPkgs = "./nexusd";
    check = chk ''"$out/bin/nexusd" --help'' "[Uu]sage"; };
  # nftrace (Apache-2.0): commodity tool to use nftables trace functionality.
  nftrace = pkg { pname = "nftrace"; version = "0.1.0"; src = gh "aojea/nftrace" "refs/tags/v0.1.0" "394bcb5411e99ac328e25d44789fe613c30adc11fda8b97cf758f2b1001112a5";
    vendorHash = "sha256-+6rAQYGKkEf9aB82nx6Fm2CgK5tPntiMG+KmAijYMRI="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/nftrace" version'' "0\\.1\\.0"; };
  # nilaway (Apache-2.0): static Analysis tool to detect potential Nil panics in Go code.
  nilaway = pkg { pname = "nilaway"; version = "0-unstable-2025-03-07"; src = gh "uber-go/nilaway" "19305c7c699bd0d370acd26d6769df1d7af8fb29" "2d20839ee595cb51494aecba789cea7dcbf04d02fe2fd8c495c5e786ed15d57d";
    vendorHash = "sha256-TEEM8TJp8d8MUeJxo8fb6bVIm7N8dVgVRFt+eLQBGYw="; subPkgs = "./cmd/nilaway"; ldflags = "-s -w";
    check = chk ''"$out/bin/nilaway" --help'' "[-]experimental-anonymous-function"; };
  # nix-converter (MIT): all-in-one converter configuration language to Nix and vice versa.
  nix-converter = pkg { pname = "nix-converter"; version = "1.0.0"; src = gh "theobori/nix-converter" "refs/tags/1.0.0" "7628d9c37a67ce252b7d3ccfe504c1a18f4fd764fd99636aec550b6acdd76b6c";
    vendorHash = "sha256-i+r7y04iJYauKBzXLxuGzHf1b21tJVzkRUuXqNmt+qU="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/nix-converter" --help'' "[-]sort-iterators"; };
  # nix-store-gcs-proxy (Apache-2.0): HTTP nix store that proxies requests to Google Storage.
  nix-store-gcs-proxy = pkg { pname = "nix-store-gcs-proxy"; version = "0.1.0"; src = gh "tweag/nix-store-gcs-proxy" "v0.1.0" "4e4ff145dc50306c26b63f74906b13ce50817d435052aea046411b0103e6109d";
    vendorHash = "sha256-GmB+unTwa+oa2WlDFnHnYguB2GQdX1D9lhMn6Dgq7n4="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/nix-store-gcs-proxy" --help'' "[-]-bucket-name"; };
  # nomore403 (MIT): tool to bypass 403/40X response codes.
  nomore403 = pkg { pname = "nomore403"; version = "2.0.1"; src = gh "devploit/nomore403" "refs/tags/v2.0.1" "d020655d1834d78ec8a6bb944d1c43b3600333411bb312d5faeacf082e488242";
    vendorHash = "sha256-Xjaf2OKnIkEXPLzD8aXzcwFODaKub5lcitit0JmfdHE="; subPkgs = "."; ldflags = "-s -w -X=main.Version=2.0.1 -X=main.BuildDate=1970-01-01T00:00:00Z";
    check = chk ''"$out/bin/nomore403" --version'' "2\\.0\\.1"; };
  # notify (MIT): allows sending the output from any tool to Slack, Discord and Telegram.
  notify = pkg { pname = "notify"; version = "1.0.7"; src = gh "projectdiscovery/notify" "v1.0.7" "ec9f1e6c48f975b58d30162071d954db0cd771ea3f5dc7168f5ecdc73658c0ad";
    vendorHash = "sha256-FvyMjUoFRKKo4LFqbzGQMufHhDoIuX089iviCmLp3ow="; subPkgs = "./cmd/notify";
    check = chk ''"$out/bin/notify" --version'' "1\\.0\\.7"; };
  # nova (Apache-2.0): find outdated or deprecated Helm charts running in your cluster.
  nova = pkg { pname = "nova"; version = "3.12.0"; src = gh "FairwindsOps/nova" "v3.12.0" "f2bb6e7b16efd5b6667840174693df0f95510baee1354a39ee3477d9a082732d";
    vendorHash = "sha256-yko/QlR4fdDNXvykWb6pvrFcUs6JqbCfvxeVcNcpG6c="; subPkgs = "."; ldflags = "-X main.version=3.12.0 -s -w";
    check = chk ''"$out/bin/nova" version'' "3\\.12\\.0"; };
  # np (AGPL-3.0-only): tool to parse, deduplicate, and query multiple port scans.
  np = pkg { pname = "np"; version = "0.11.0"; src = gh "leesoh/np" "refs/tags/v0.11.0" "f13b7b712ecbafd71d4a3857161e2b2f2d8b19c95ce62b739232af3c430654dd";
    vendorHash = "sha256-GWvxsDzahbunDUVeVnL9ZAR/k0Ih8gsaOv8MFHUvCsw="; subPkgs = "./cmd/np"; ldflags = "-s -w";
    check = chk ''"$out/bin/np" --help'' "[Uu]sage"; };
  # nsq (MIT): realtime distributed messaging platform.
  nsq = pkg { pname = "nsq"; version = "1.3.0"; src = gh "nsqio/nsq" "v1.3.0" "c6289e295aaa40c8d9651de76e66bc9f23e7f5c40b1cc051ea5901965093e1f0";
    vendorHash = "sha256-pIMIGZ+f++PHOpQtObIDce8XaVJeqdCRM6rSRP0ga70="; subPkgs = "./apps/nsq_stat ./apps/nsq_tail ./apps/nsq_to_file ./apps/nsq_to_http ./apps/nsq_to_nsq ./apps/nsqadmin ./apps/nsqd ./apps/nsqlookupd ./apps/to_nsq"; ldflags = "-s -w";
    check = chk ''"$out/bin/nsq_stat" --version'' "1\\.3\\.0"; };
  # nvcat (Apache-2.0): `cat` but with syntax highlighting powered by Neovim.
  nvcat = pkg { pname = "nvcat"; version = "0.1.5"; src = gh "brianhuster/nvcat" "refs/tags/v0.1.5" "3afe384a17ebf16eb38702c51cfca6faad13eec20b83f0c9a0988d79c0a3f519";
    vendorHash = "sha256-4k0T0vZD8hueHIH9SYXN55Ps0n8vzQHMAvABQ17j7vY="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/nvcat" --help'' "[Uu]sage"; };
  # nvdtools (Apache-2.0): tools to work with the feeds (vulnerabilities, CPE dictionary etc.) distributed by National Vulnerability Database.
  nvdtools = pkg { pname = "nvdtools"; version = "0.1.5"; src = gh "facebookincubator/nvdtools" "refs/tags/v0.1.5" "78265d34f934df76407019dfe242424587b6c87f3bd359141d0ffef7c48172a8";
    vendorHash = "sha256-mg1NnzY7EUERBVl6UW5Q3bURZJq+lA+rT5P8BHbujnY="; subPkgs = "./cmd/cpe2cve ./cmd/csv2cpe ./cmd/fireeye2nvd ./cmd/flexera2nvd ./cmd/idefense2nvd ./cmd/nvdsync ./cmd/rbs2nvd ./cmd/redhat2nvd ./cmd/redhat_filter ./cmd/redhat_query ./cmd/rpm2cpe ./cmd/rustsec2nvd ./cmd/snyk2nvd ./cmd/vfeed2nvd ./cmd/vulndb ./cmd/wfnconvert ./vulndb/sqlutil/b64schema"; ldflags = "-s -w";
    check = chk ''"$out/bin/cpe2cve" --help'' "[Uu]sage"; };
  # oak (MIT): expressive, simple, dynamic programming language.
  oak = pkg { pname = "oak"; version = "0.3"; src = gh "thesephist/oak" "v0.3" "05bc1c09da8f8d199d169e5a5c5ab2f2923bad6fac624f497f5ea365f378e38a";
    vendorHash = "sha256-MwUaHkNZbJP0d0GcyTfRs67jGqwgsJBvy1XuI9K1pk8="; subPkgs = ".";
    check = chk ''"$out/bin/oak" version'' "0\\.3"; };
  # oauth2l (Apache-2.0): simple CLI for interacting with Google API authentication.
  oauth2l = pkg { pname = "oauth2l"; version = "1.3.6"; src = gh "google/oauth2l" "v1.3.6" "5e09371bc245946cadecd3c73de7b782c1f933816678f7f5dff0d5632da5ae0a";
    vendorHash = null; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/oauth2l" --help'' "[Uu]sage"; };
  # octoscan (GPL-3.0-only): static vulnerability scanner for GitHub action workflows.
  octoscan = pkg { pname = "octoscan"; version = "0.1.7"; src = gh "synacktiv/octoscan" "refs/tags/v0.1.7" "8108b8e298333cc10ac47219fe871640ce8de05b86efab6a8f328fb13b5c27f3";
    vendorHash = "sha256-S4f7eH7sTYvrHGUg01J2hPlWkrEBrYNb3k85t58a+dA="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/octoscan" --help'' "[Uu]sage"; };
  # oh (MIT): new Unix shell.
  oh = pkg { pname = "oh"; version = "0.8.3"; src = gh "michaelmacinnis/oh" "v0.8.3" "3ffd50ae66167ef6c7dcd4e1982b8902d34fbfb88d49bda5f6893bf0bcd92da8";
    vendorHash = "sha256-Dc1FHTskWXQydTK2Jm2AeL4LMkodaq3VLvywjsDeztQ="; subPkgs = ".";
    check = chk ''"$out/bin/oh" --version'' "0\\.8\\.3"; };
  # okms-cli (Apache-2.0): command Line Interface to interact with your OVHcloud KMS services.
  okms-cli = pkg { pname = "okms-cli"; version = "0.5.0"; src = gh "ovh/okms-cli" "refs/tags/v0.5.0" "19fbcf501517fa3e6c0d8f0d15a1d802475c38351f99f646c02697ee4ac43dbd";
    vendorHash = "sha256-1I8Wp0Iwiz4/h02hYgMRu1Gkh2sUT/6a08XivAo7gAI="; subPkgs = "./cmd/okms"; ldflags = "-s -w -X main.version=0.5.0 -X main.commit=refs/tags/v0.5.0 -X main.date=unknown";
    check = chk ''"$out/bin/okms" version'' "0\\.5\\.0"; };
  # okta-aws-cli (Apache-2.0): CLI for having Okta as the IdP for AWS CLI operations.
  okta-aws-cli = pkg { pname = "okta-aws-cli"; version = "2.6.0"; src = gh "okta/okta-aws-cli" "v2.6.0" "2d68b99fc8b16145169d3f7f780216bd9b4ec73eed48ee609bdecd2b99100f77";
    vendorHash = "sha256-ULBIqXd4Am9bEdar1TBSuX33RHTwVCGTJ5QWkdfGfTU="; subPkgs = "./cmd/okta-aws-cli"; ldflags = "-s -w";
    check = chk ''"$out/bin/okta-aws-cli" --version'' "2\\.6\\.0"; };
  # openrisk (MIT): tool that generates an AI-based risk score.
  openrisk = pkg { pname = "openrisk"; version = "0.0.1"; src = gh "projectdiscovery/openrisk" "refs/tags/v0.0.1" "d3a9baddfe99c40a4456fa6a87fd088d8a7238504a94b9226407ef088e530431";
    vendorHash = "sha256-zqvm+wmLL1Zr0YMXuy1/Mii5bs7XA31exr4FV1cQYhs="; subPkgs = "."; ldflags = "-s";
    check = chk ''"$out/bin/openrisk" --version'' "0\\.0\\.1"; };
  # osc (MIT): command line tool to access the system clipboard from anywhere using the ANSI OSC52 sequence.
  osc = pkg { pname = "osc"; version = "0.4.8"; src = gh "theimpostor/osc" "refs/tags/v0.4.8" "cfe4e92c7190e3a0db8131a01ec8f9215334ea78ce9a99d8a2db29217acf094d";
    vendorHash = "sha256-CO9eYLlYVXP0HEb/VAoB6zQ64kGF36PUtj9A0dew5v4="; subPkgs = ".";
    check = chk ''"$out/bin/osc" --help'' "[Uu]sage"; };
  # ossutil (MIT): user friendly command line tool to access Alibaba Cloud OSS.
  ossutil = pkg { pname = "ossutil"; version = "1.7.18"; src = gh "aliyun/ossutil" "refs/tags/v1.7.18" "54c9531d1c1ff914fb01b31af44c9d8fdf3112f7ea7e091a12efa606c6c8903c";
    vendorHash = "sha256-VqlIi5aefpjfcgURU02vo8rRB2tmx1SMMXW2I8AJ0HI="; subPkgs = ".";
    check = chk ''"$out/bin/ossutil" --version'' "1\\.7\\.18"; };
  # otpauth (ISC): google Authenticator migration decoder.
  otpauth = pkg { pname = "otpauth"; version = "0.6.1"; src = gh "dim13/otpauth" "v0.6.1" "27c18aa53f6eeb95e1a43a49fdbe6b692d40f7bf6d59125c8ab8bd469504e8c0";
    vendorHash = "sha256-7SXto1fSTzBRDThr+DUpyDqzYbSlnBhun37bdO/Jr9c="; subPkgs = ".";
    check = chk ''"$out/bin/otpauth" --help'' "[Uu]sage"; };
  # ots (Apache-2.0): share end-to-end encrypted secrets with others via a one-time URL.
  ots = pkg { pname = "ots"; version = "0.3.1"; src = gh "sniptt-official/ots" "v0.3.1" "09f0b0d7ca44ec8414dbf631009df8c00f4750247c0f9ba25a32f0aa270e09cc";
    vendorHash = "sha256-xtI3gzNBkA8qfwUdX1CEKNE5k8pODQetNmmGrDwvjHg="; subPkgs = "."; ldflags = "-X main.version=0.3.1 -X main.buildSource=nix";
    check = chk ''"$out/bin/ots" --help'' "[Uu]sage"; };
  # pacproxy (Apache-2.0): no-frills local HTTP proxy server powered by a proxy auto-config (PAC) file.
  pacproxy = pkg { pname = "pacproxy"; version = "2.0.6"; src = gh "williambailey/pacproxy" "v2.0.6" "e1b060083e308744bd2b3c1c65c09012fe8b94aa41d0be54313a1d36cc9fcb48";
    vendorHash = "sha256-+q6fuU5JdfFHVFvit2ZO9Zl8B/lG89bUvaGD5xRfSwQ="; subPkgs = ".";
    check = chk ''"$out/bin/pacproxy" --version'' "2\\.0\\.6"; };
  # panicparse (Apache-2.0): crash your app in style (Golang).
  panicparse = pkg { pname = "panicparse"; version = "2.5.0"; src = gh "maruel/panicparse" "v2.5.0" "93d1158cb9f6ae117cd94b5f95a00ee02282c6f866676e7aa55d6468dadde64a";
    vendorHash = "sha256-HDmEP9x/skKddZ0lxvQN5gJOxj2HYZn9n9uUE+lBSSQ="; subPkgs = ".";
    check = chk ''"$out/bin/panicparse" --help'' "[-]force-color"; };
  # paralus-cli (Apache-2.0): command Line Interface tool for Paralus.
  paralus-cli = pkg { pname = "paralus-cli"; version = "0.1.5"; src = gh "paralus/cli" "v0.1.5" "df1e05e84c62dca5dc257fca0842965f7c403223315f7c884f473ace6c4ac8d2";
    vendorHash = "sha256-rsEmSOHYgCKhMAmZL7aTa4tEzjIrqRfc/8Qar1gA49M="; subPkgs = "."; ldflags = "-s -w -X main.version=0.1.5 -X main.buildNum=0.1.5";
    check = chk ''"$out/bin/cli" version'' "0\\.1\\.5"; };
  # easyjson (MIT): fast JSON serializer for Go.
  easyjson = pkg { pname = "easyjson"; version = "0.9.2"; src = gh "mailru/easyjson" "v0.9.2" "0a6b7a5175aeb38c52ae794d49373f2a9baa5a5e47b7cf430db2cbb668297689";
    vendorHash = "sha256-j9AfUrCF6v3Qco8V8NOvJ1kZ36kGGPHwwqwnhdz6Cpg="; subPkgs = "./easyjson";
    check = chk ''"$out/bin/easyjson" --help'' "[Uu]sage"; };
  # efm-langserver (MIT): general purpose Language Server.
  efm-langserver = pkg { pname = "efm-langserver"; version = "0.0.57"; src = gh "mattn/efm-langserver" "v0.0.57" "5a00742ab59c146514f652cc1d8cd34df1b0b1c692706261e4a97131f9cbe935";
    vendorHash = "sha256-dU0+jqD06n2Ncp+caEKJz6PPFc+bUsKPC0tvzXgDlBQ="; subPkgs = ".";
    check = chk ''"$out/bin/efm-langserver" --help'' "[Uu]sage"; };
  # elfinfo (BSD-3-Clause): small utility for showing information about ELF files.
  elfinfo = pkg { pname = "elfinfo"; version = "1.2.2"; src = gh "xyproto/elfinfo" "1.2.2" "33c9bf9942dfa770fa6530f5a268f15d96abcd4c57aaddf93636cdfcd2dfc540";
    vendorHash = null; subPkgs = ".";
    check = chk ''"$out/bin/elfinfo" --version'' "1\\.2\\.2"; };
  # enumer (BSD-2-Clause): go tool to auto generate methods for enums.
  enumer = pkg { pname = "enumer"; version = "1.7.2"; src = gh "dmarkham/enumer" "refs/tags/v1.7.2" "ef310c9af9061540944b47659500fae4ba493312babe4ed681c8ffead4f86ab6";
    vendorHash = "sha256-J0etGLycrT2fXOrxyH55fI6oEnxt40ABM1RJ2tuXhFc="; subPkgs = ".";
    check = chk ''"$out/bin/enumer" --help'' "[Uu]sage"; };
  # enumerepo (MIT): tool to list all public repositories for (valid) GitHub usernames.
  enumerepo = pkg { pname = "enumerepo"; version = "1.0.0"; src = gh "trickest/enumerepo" "refs/tags/v1.0.0" "bb4c4019426e7050aa46feb4904ab43a43d7770772001a0be28e9e33ae74390e";
    vendorHash = "sha256-ijaajmxLAdUdWZnR+zGIkGjTgGc4FbU+hOaCNyT5kM0="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/enumerepo" --help'' "[-]adjust-delay"; };
  # errcheck (MIT): checks for unchecked errors in go programs.
  errcheck = pkg { pname = "errcheck"; version = "1.30.0"; src = gh "kisielk/errcheck" "v1.30.0" "0c7b3bfdc9cc659d87c6ed72eb8980e4740e2990a6243a6e67743394ea1c20ff";
    vendorHash = "sha256-J0MIU9A1oRd3SDiduv93WeCBXlmVnzKn3GSq5Iakcuc="; subPkgs = ".";
    check = chk ''"$out/bin/errcheck" --help'' "[Uu]sage"; };
  # exiflooter (Apache-2.0): finds geolocation on all image urls and directories.
  exiflooter = pkg { pname = "exiflooter"; version = "1.0.0"; src = gh "aydinnyunus/exiflooter" "v1.0.0" "37c41033aec93a3a21de6699db7352bd398fc947033c41ce2513b440a7b9588f";
    vendorHash = "sha256-TfGCE/T7to7HWQBzFiLarpxbyWCHmBE6JoXsr0XRtFw="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/exifLooter" --help'' "[-]-open-street-map"; };
  # extrude (MIT): tool to analyse binaries for missing security features.
  extrude = pkg { pname = "extrude"; version = "0.0.12"; src = gh "liamg/extrude" "v0.0.12" "ec33eb0851fa6111aa9449f7c817e8571f4dbd95d8df9944df31dcd8bf59c5a5";
    vendorHash = "sha256-qOo4ZwmP2tOlcfKYcy2iW/D2g+nRZfwk2516pLgEDRg="; subPkgs = "./cmd/extrude";
    check = chk ''"$out/bin/extrude" --help'' "[-]-fail-on-warning"; };
  # fanbox-dl (MIT): pixiv FANBOX Downloader.
  fanbox-dl = pkg { pname = "fanbox-dl"; version = "0.29.1"; src = gh "hareku/fanbox-dl" "v0.29.1" "709589e12676ddd636f00d9673883758cb30efa742b36f54324e211067d551f4";
    vendorHash = "sha256-NG0zE9d6aW/AMFXfLTuP7RgKq6uxilRGfh5k8UReepY="; subPkgs = "./cmd/fanbox-dl";
    check = chk ''"$out/bin/fanbox-dl" --help'' "[-]-ignore-creator"; };
  # favirecon (MIT): tool to detect technologies, WAF, exposed panels and known services.
  favirecon = pkg { pname = "favirecon"; version = "1.1.0"; src = gh "edoardottt/favirecon" "refs/tags/v1.1.0" "3cc64b241fc357cda44ea11ffbe036fbf7160049d0011c45a9963746e6e27bfb";
    vendorHash = "sha256-K0M1md/C5U80Ltg1J7kL9ftIHZu3jpPEbtwDmw25pvI="; subPkgs = "./cmd/favirecon"; ldflags = "-s";
    check = chk ''"$out/bin/favirecon" version'' "1\\.1\\.0"; };
  # feishu-cli (MIT): CLI for Feishu (Lark) Open Platform.
  feishu-cli = pkg { pname = "feishu-cli"; version = "1.43.0"; src = gh "riba2534/feishu-cli" "refs/tags/v1.43.0" "c6a73861892ec1d85d82c3d16db94bae63d11edb6b395509b9f7f36b9e984855";
    vendorHash = "sha256-JTCJW/tok36S2lfATuiCNSVxREmyUx407nDdfHhEvB8="; subPkgs = "."; ldflags = "-X main.Version=v1.43.0";
    check = chk ''"$out/bin/feishu-cli" --version'' "1\\.43\\.0"; };
  # ffuf (MIT): tool for web fuzzing.
  ffuf = pkg { pname = "ffuf"; version = "2.3.0"; src = gh "ffuf/ffuf" "refs/tags/v2.3.0" "cdb2e58259f380862850eba587f71a9dc1738fb5edc1ea60414fae30fd0ed4f2";
    vendorHash = "sha256-M8d0jQS9fXHZiVGyWxjTnhZJ9qanKQNLwZmqIPS9LQo="; subPkgs = "."; ldflags = "-s -X=github.com/ffuf/ffuf/v2/pkg/ffuf.VERSION=2.3.0 -X=github.com/ffuf/ffuf/v2/pkg/ffuf.VERSION_APPENDIX=";
    check = chk ''"$out/bin/ffuf" --version'' "2\\.3\\.0"; };
  # figurine (Apache-2.0): print your name in style.
  figurine = pkg { pname = "figurine"; version = "2.1.1"; src = gh "arsham/figurine" "v2.1.1" "9e799917edb627a6df30bec60898b3583b2c550c087c55efb75b695e91ea60d5";
    vendorHash = "sha256-MxZI5cuQsQMqG9VVX8JJ5cWP5idTrHZS449DHbT+mkE="; subPkgs = "."; ldflags = "-s -w -X main.version=2.1.1 -X main.currentSha=v2.1.1";
    check = chk ''"$out/bin/figurine" --version'' "2\\.1\\.1"; };
  # files-cli (MIT): files.com Command Line App for Windows, Linux, and macOS.
  files-cli = pkg { pname = "files-cli"; version = "2.15.463"; src = gh "files-com/files-cli" "refs/tags/v2.15.463" "d1f81619f269e991523c824f6352e93d20e250074d895268ea39b3a327e894e9";
    vendorHash = "sha256-rTQPPTPzCkLyTsUPReX4Dutr7aE5j6aQVPFQ5qFL9rA="; subPkgs = "."; ldflags = "-s -X main.version=2.15.463";
    check = chk ''"$out/bin/files-cli" --version'' "2\\.15\\.463"; };
  # flarectl (BSD-3-Clause): CLI application for interacting with a Cloudflare account.
  flarectl = pkg { pname = "flarectl"; version = "0.116.0"; src = gh "cloudflare/cloudflare-go" "v0.116.0" "d594cdf6730046eae27240324d32a8f43a2affa7f61706459ae912fa9f4d085b";
    vendorHash = "sha256-HUJDGTdZI1oJj2pvldrp6s3A+2ZZMLwakN83RUnlABs="; subPkgs = "./cmd/flarectl"; ldflags = "-s -w";
    check = chk ''"$out/bin/flarectl" --help'' "[-]-account-id"; };
  # fork-cleaner (MIT): quickly clean up unused forks on your GitHub account.
  fork-cleaner = pkg { pname = "fork-cleaner"; version = "2.4.0"; src = gh "caarlos0/fork-cleaner" "refs/tags/v2.4.0" "28ded4826d8a36d25857b824bea1ae480c76029ff50e8d831f79e18c360ff032";
    vendorHash = "sha256-ecEONfRAZ1QeMcRUL88SK8QRXcGv24e2g1PPWcCl5H0="; subPkgs = "./cmd/fork-cleaner"; ldflags = "-s -w -X main.version=2.4.0 -X main.builtBy=nixpkgs";
    check = chk ''"$out/bin/fork-cleaner" --version'' "2\\.4\\.0"; };
  # frangipanni (MIT): convert lines of text into a tree structure.
  frangipanni = pkg { pname = "frangipanni"; version = "0.5.0"; src = gh "birchb1024/frangipanni" "v0.5.0" "11a181c582f57c1a3d0f1cc934eacb6a7e18ca458c6575c84efcbb9b4bfcc0e2";
    vendorHash = "sha256-ExQfeSyYP0WmzlR5n3UnOn/aTosOuwY2yQZ1TaWH5QY="; subPkgs = ".";
    check = chk ''"$out/bin/frangipanni" --help'' "[-]no-fold"; };
  # fscan (MIT): intranet comprehensive scanning tool.
  fscan = pkg { pname = "fscan"; version = "2.2.2"; src = gh "shadow1ng/fscan" "refs/tags/v2.2.2" "4ad616dc215ceb683113ec6d3b96480d13e3321495e0f9657c1bb42aa6d62556";
    vendorHash = "sha256-LcyCpMdY9ZjhaO/NK8AbR983nAjE9QBxudXD7uts/Vs="; subPkgs = ".";
    check = chk ''"$out/bin/fscan" version'' "2\\.2\\.2"; };
  # fsql (MIT): search through your filesystem with SQL-esque queries.
  fsql = pkg { pname = "fsql"; version = "0.5.2"; src = gh "kashav/fsql" "v0.5.2" "21f12261516bfa2ebc4136b7e7e08a23743809e847dfdace3c1f6ac88023277d";
    vendorHash = "sha256-l3e7+Rq/tRDbmvFf9Z1YiKT2WJ+6KQ1CpVrp95bJjjA="; subPkgs = "./cmd/fsql"; ldflags = "-s -w";
    check = chk ''"$out/bin/fsql" --version'' "0\\.5\\.2"; };
  # galer (MIT): tool to fetch URLs from HTML attributes.
  galer = pkg { pname = "galer"; version = "0.2.0"; src = gh "dwisiswant0/galer" "refs/tags/v0.2.0" "1752d3062ad8dc39e4e34fb84088e58aa1544d3893147097502c4ec36920210f";
    vendorHash = "sha256-rjCYCHKRKQfO/AlFjAMRZmyP1wMkhiszv0Tg8HSmaSk="; subPkgs = ".";
    check = chk ''"$out/bin/galer" --version'' "0\\.2\\.0"; };
  # gat (MIT): cat alternative written in Go.
  gat = pkg { pname = "gat"; version = "0.31.0"; src = gh "koki-develop/gat" "refs/tags/v0.31.0" "424ad788c91081fe5db432f99d108802bb96ef5688b0ccb263cc4ca673efb155";
    vendorHash = "sha256-uhn5b0H0k3Hqn6Qt/vHFiXf3HWQKqj21Z3eJqXhZMoI="; subPkgs = ". ./docs ./tapes"; ldflags = "-s -w -X github.com/koki-develop/gat/cmd.version=v0.31.0";
    check = chk ''"$out/bin/gat" --version'' "0\\.31\\.0"; };
  # gatus-cli (MIT): client for Gatus, an automated developer-oriented status page.
  gatus-cli = pkg { pname = "gatus-cli"; version = "1.0.0"; src = gh "TwiN/gatus-cli" "refs/tags/v1.0.0" "9afc71669c0f5b51a5f7818618d8c5c0147aa76d6f1af66f829b4e74fd5410a8";
    vendorHash = "sha256-Q55rfj8WuNBdDHCIkT1p7Qvk4nCro9w6LT/+32VnjYo="; subPkgs = "."; ldflags = "-s -w -X main.version=1.0.0";
    check = chk ''"$out/bin/gatus-cli" --help'' "[Uu]sage"; };
  # gau (MIT): tool to fetch known URLs.
  gau = pkg { pname = "gau"; version = "2.2.4"; src = gh "lc/gau" "refs/tags/v2.2.4" "537abafca9065a7ed5d93aa7722d85da0815abf6b08c2d1494483171558ce3f7";
    vendorHash = "sha256-kQ2PUKPsGFXn5QPPXwLbTjN/+5g9MeA6l+dgE5Inebw="; subPkgs = "./cmd/gau"; ldflags = "-w -s";
    check = chk ''"$out/bin/gau" --version'' "2\\.2\\.4"; };
  # gci (BSD-3-Clause): controls golang package import order and makes it always deterministic.
  gci = pkg { pname = "gci"; version = "0.14.0"; src = gh "daixiang0/gci" "refs/tags/v0.14.0" "433d6dd89ebcb9f928f91729b9243971f6233970f78efc41ae672fe376de4e88";
    vendorHash = "sha256-7fT/nXvqM4uqg7Y2+3kzwgviWnjO9JTrT0zPU1vC6JA="; subPkgs = ". ./internal"; ldflags = "-s";
    check = chk ''"$out/bin/gci" --version'' "0\\.14\\.0"; };
  # gcov2lcov (MIT): convert go coverage files to lcov format.
  gcov2lcov = pkg { pname = "gcov2lcov"; version = "1.1.1"; src = gh "jandelgado/gcov2lcov" "v1.1.1" "5a8973d8680b6c242de3b89970b0f1f6b07fec31e7cd6fedcd3e100b17cd8bba";
    vendorHash = "sha256-Poz2QI8iLGkYGrbz03CK+kk/z0U4VKOCOmDCoF27+OA="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/gcov2lcov" --help'' "[-]use-absolute-source-path"; };
  # gemget (MIT): command line downloader for the Gemini protocol.
  gemget = pkg { pname = "gemget"; version = "1.9.0"; src = gh "makew0rld/gemget" "v1.9.0" "ded2b0d86e24d0a35a35ea412d08ebff636698fa5114e0da80b5b4c1b003e431";
    vendorHash = "sha256-Ydj8IJVtMtIknwb5y/L9P2eWngPoq118mCF/izf8+NA="; subPkgs = ".";
    check = chk ''"$out/bin/gemget" --version'' "1\\.9\\.0"; };
  # geoipupdate (Apache-2.0): automatic GeoIP database updater.
  geoipupdate = pkg { pname = "geoipupdate"; version = "8.0.0"; src = gh "maxmind/geoipupdate" "v8.0.0" "5c08b39d2ac49ad492138b3d618dddac130065852b6237ec450bac856ace7e0a";
    vendorHash = "sha256-2awt5CELXnxNvluodOWpXoaeJ6lLgIBwXcBH5IY+CGA="; subPkgs = "./cmd/geoipupdate"; ldflags = "-X main.version=8.0.0";
    check = chk ''"$out/bin/geoipupdate" --version'' "8\\.0\\.0"; };
  # gerrit-queue (Apache-2.0): merge bot for Gerrit.
  gerrit-queue = pkg { pname = "gerrit-queue"; version = "0.0.1"; src = gh "flokli/gerrit-queue" "v0.0.1" "85fb7210a0278326104568cbe8ecd7500028c65637a1da3494864f0162b44b02";
    vendorHash = "sha256-Kdkcb7GWIf4uUSDfRvpVtp7JvuCFjKwW03da+mGNMu4="; subPkgs = ".";
    check = chk ''"$out/bin/gerrit-queue" --help'' "[-]-trigger-interval"; };
  # gh-aw (MIT): gh extension for GitHub Agentic Workflows.
  gh-aw = pkg { pname = "gh-aw"; version = "0.89.21"; src = gh "github/gh-aw" "refs/tags/v0.89.21" "5295ba4118e916f05d264e362afa34be46c7c83b4ff3da951cc394229c644694";
    vendorHash = "sha256-49vqhSB1LPcMEEJFLYGbsxh1sGFelUwY/CS+PYnWME8="; subPkgs = "./cmd/gh-aw"; ldflags = "-s -w -X main.version=0.89.21";
    check = chk ''"$out/bin/gh-aw" --version'' "0\\.89\\.21"; };
  # gh-do (MIT): do and undo and notify with GitHub CLI.
  gh-do = pkg { pname = "gh-do"; version = "0.6.0"; src = gh "k1LoW/gh-do" "refs/tags/v0.6.0" "ec3657d74317c0ac93745374fe9f5c4e27440b85856476d79206c659c809f6ec";
    vendorHash = "sha256-LGQ1oNfwxKav2qAkym2JZcF5FsH3n28GpcLAfiNmXtE="; subPkgs = "./cmd/gh-do"; ldflags = "-s -w -X main.version=0.6.0";
    check = chk ''"$out/bin/gh-do" --version'' "0\\.6\\.0"; };
  # gh-i (Apache-2.0): search github issues interactively.
  gh-i = pkg { pname = "gh-i"; version = "0.0.10"; src = gh "gennaro-tedesco/gh-i" "v0.0.10" "ebd317a28e13a78c51e52d948f15a114325419cec355b6f4f0855598f6fbfbcb";
    vendorHash = "sha256-piSBXwRUhP3ul2GouAdONTR5gz/+G3FB/ep0s0LjVpU="; subPkgs = "."; ldflags = "-s";
    check = chk ''"$out/bin/gh-i" --version'' "0\\.0\\.10"; };
  # gh-ost (MIT): triggerless online schema migration solution for MySQL.
  gh-ost = pkg { pname = "gh-ost"; version = "1.1.11"; src = gh "github/gh-ost" "refs/tags/v1.1.11" "f1cf96257d3f29922a8bd5a906fd742d852cbfb43a0a607e778a9b135cf3133c";
    vendorHash = null; subPkgs = "./go/cmd/gh-ost"; ldflags = "-s -w -X main.AppVersion=1.1.11";
    check = chk ''"$out/bin/gh-ost" --version'' "1\\.1\\.11"; };
  # gh-poi (MIT): gitHub CLI extension to safely clean up your local branches.
  gh-poi = pkg { pname = "gh-poi"; version = "0.18.5"; src = gh "seachicken/gh-poi" "v0.18.5" "a252a0e7922c46dff689becbf68fdc0bc0b9b1308f9f705b9f4d4594f5547144";
    vendorHash = "sha256-CaxsFV3sMGcGDTdpSsh4X6P2ytWlkSyy6RQw79QI1ck="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/gh-poi" --help'' "[-]-dry-run"; };
  # gh-review-conductor (Apache-2.0): gitHub CLI extension to apply PR review comments and suggestions directly to your local code.
  gh-review-conductor = pkg { pname = "gh-review-conductor"; version = "2.0.0"; src = gh "gh-tui-tools/gh-review-responder" "refs/tags/v2.0.0" "5ed493ccdadc1bd0b7c4bcc75681d6dca75d2b14d1b557cc662d303141f046db";
    vendorHash = "sha256-N2bscNgTydEvPCjvlJd6R6QynVE6AlsJIy4VOs9DSSA="; subPkgs = "."; ldflags = "-s -w -X github.com/gh-tui-tools/gh-review-conductor/cmd.version=2.0.0";
    check = chk ''"$out/bin/gh-review-responder" --help'' "[-]-no-color"; };
  # gh-s (Apache-2.0): search github repositories interactively.
  gh-s = pkg { pname = "gh-s"; version = "0.0.12"; src = gh "gennaro-tedesco/gh-s" "v0.0.12" "007455d0c324791af04c95dcf47d8ad82a1dddbd2f45cdd7785d69899e23b717";
    vendorHash = "sha256-2pU9wuoUnM+AGg4LJWoIVP0hDZae0pFputNQ92rDJKw="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/gh-s" --version'' "0\\.0\\.12"; };
  # gh-skyline (MIT): generate a 3D model of your GitHub contribution history.
  gh-skyline = pkg { pname = "gh-skyline"; version = "0.1.9"; src = gh "github/gh-skyline" "refs/tags/v0.1.9" "fd40fb5ea0f144e0e96f8638504f4197efe93ebe8e9db7ebd3b7f63ef2f0b4fa";
    vendorHash = "sha256-KPWk0ZugTw1mfnGEXHONySBzL2+PJC8dDauUJ9SXH5I="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/gh-skyline" --help'' "[-]-art-only"; };
  # gh-token (MIT): manage installation access tokens for GitHub apps from your terminal.
  gh-token = pkg { pname = "gh-token"; version = "2.0.10"; src = gh "Link-/gh-token" "v2.0.10" "106fcc0f6fc9ac7f990154be668779c38826dd8e7dd663443bcde05cdcc82bfc";
    vendorHash = "sha256-wQ2szaacKyzSRBp6qZnQLaz1cRAJF2TbUNV68UG3Blo="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/gh-token" --version'' "2\\.0\\.10"; };
  # ghosttohugo (MIT): convert Ghost export to Hugo posts.
  ghosttohugo = pkg { pname = "ghosttohugo"; version = "0.5.3"; src = gh "jbarone/ghostToHugo" "v0.5.3" "2fb42a3ffa50bd38fdeeb6dffa5d5b6308fe5cf17a44f134573ecfe830366494";
    vendorHash = "sha256-pWxMXxx1wcgxDes5IuWcmCv5Mfj9VnR8A1C4bgli00I="; subPkgs = ".";
    check = chk ''"$out/bin/ghostToHugo" --help'' "[Uu]sage"; };
  # git-hound (MIT): reconnaissance tool for GitHub code search.
  git-hound = pkg { pname = "git-hound"; version = "3.2"; src = gh "tillson/git-hound" "refs/tags/v3.2" "be883cd265a2cc049c9ed8c7bbf29dccf89789173b19b237618d9c9613ee9127";
    vendorHash = "sha256-w55xscTB3NUaKpT9CG3wjbf0hp9l3tGXB+9cJcacYHI="; subPkgs = ".";
    check = chk ''"$out/bin/git-hound" --help'' "[-]-many-results"; };
  # git-lfs-transfer (MIT): server-side implementation of the Git LFS pure-SSH protocol.
  git-lfs-transfer = pkg { pname = "git-lfs-transfer"; version = "0.1.0-unstable-2026-08-12"; src = gh "charmbracelet/git-lfs-transfer" "971c0284dc33b1ed3f7ed9dde5d4fc0cee62db6b" "92d6720202aa5a059c6683df78f1fa47722c0c48ff1dc4ebfc0bc8137d988702";
    vendorHash = "sha256-Y8C61lmjBVLer5ka6g+5LMur5kICXHlP8h/WMEkNczY="; subPkgs = ".";
    check = chk ''"$out/bin/git-lfs-transfer" --help'' "[Uu]sage"; };
  # git-releaser (Apache-2.0): tool for creating Git releases based on Semantic Versioning.
  git-releaser = pkg { pname = "git-releaser"; version = "0.1.7"; src = gh "git-releaser/git-releaser" "refs/tags/v0.1.7" "e00ae3f73cebf54c5011e48e32a063c642b5b4885203cfc3827558f7337bec01";
    vendorHash = "sha256-0Jn1hH/Y9FRqoINgYaxEAY0NDdEQiVmxtB7/I/+jHPg="; subPkgs = "."; ldflags = "-X main.version=0.1.7";
    check = chk ''"$out/bin/git-releaser" --help'' "[Uu]sage"; };
  # git-subtrac (Apache-2.0): keep the content for your git submodules all in one place: the parent repo.
  git-subtrac = pkg { pname = "git-subtrac"; version = "0.04"; src = gh "apenwarr/git-subtrac" "v0.04" "162baf3614e7ba0c6ccf2838acae4780bbf8e1795e8294d9a32ff32379125e27";
    vendorHash = "sha256-GV21IcOjCUysXucDPF9jaw8tmlhaTfBRuTFyjerlBH4="; subPkgs = ".";
    check = chk ''"$out/bin/git-subtrac" --help'' "[-]-auto-exclude"; };
  # git-who (MIT): git blame for file trees.
  git-who = pkg { pname = "git-who"; version = "1.3"; src = gh "sinclairtarget/git-who" "v1.3" "7af9950b8786a52e71e80457986f8b961064dc39923de1e330bc9fede42feef4";
    vendorHash = "sha256-aWkAz9NEhlAy2aNQ5WN5o0hjn4VZokJmGpgmjdKjJRc="; subPkgs = ".";
    check = chk ''"$out/bin/git-who" --help'' "[Uu]sage"; };
  # github-markdown-toc-go (MIT): easy TOC creation for GitHub README.md (in go).
  github-markdown-toc-go = pkg { pname = "github-markdown-toc-go"; version = "2.0.1"; src = gh "ekalinin/github-markdown-toc.go" "v2.0.1" "62f34f003912244c8d6d94cad9a273ddb3f29f6f01133d16fdefd0c017030526";
    vendorHash = "sha256-YTWLpqoILkDCvr3uaM3i3kh7OO9Y/gGdeRnXdp5Ll3M="; subPkgs = "./cmd/gh-md-toc";
    check = chk ''"$out/bin/gh-md-toc" --version'' "2\\.0\\.1"; };
  # github-release (MIT): commandline app to create and edit releases on Github (and upload artifacts).
  github-release = pkg { pname = "github-release"; version = "0.11.0"; src = gh "github-release/github-release" "refs/tags/v0.11.0" "6e6d3d77ce7d6acf6c4e4e0e005c71641ba7c2eb67d9f1f2e2cf2cc5f5c68086";
    vendorHash = null; subPkgs = "."; ldflags = "-s";
    check = chk ''"$out/bin/github-release" --version'' "0\\.11\\.0"; };
  # gitlab-ci-validate (MIT): command line tool to validate .gitlab-ci.yml files.
  gitlab-ci-validate = pkg { pname = "gitlab-ci-validate"; version = "0.6.0"; src = gh "Code0x58/gitlab-ci-validate" "refs/tags/v0.6.0" "87ec830bf1a7a5a1d921ff17a3894d5351bb5c835511d23dfd5d6cb3eb5d5194";
    vendorHash = "sha256-YWxDilcYoOqU+i4KRevy9596W6VsQiET10pCrhGr22o="; subPkgs = "."; ldflags = "-s -w -X=main.version=0.6.0";
    check = chk ''"$out/bin/gitlab-ci-validate" --help'' "[-]project-id"; };
  # gitmux (MIT): git in your tmux status bar.
  gitmux = pkg { pname = "gitmux"; version = "0.11.5"; src = gh "arl/gitmux" "v0.11.5" "c6a01faa5372a8c4ab24bc3a2c9665a9f430c45c79b175c1510388433637ca72";
    vendorHash = "sha256-+WpzB+KHUkawWj/4Gdpm9CH3nuLvcZ/cXS2D5RbI5DY="; subPkgs = "."; ldflags = "-X main.version=0.11.5";
    check = chk ''"$out/bin/gitmux" --version'' "0\\.11\\.5"; };
  # gitsnip (MIT): CLI tool to download specific folders from a git repository.
  gitsnip = pkg { pname = "gitsnip"; version = "0.1.1"; src = gh "dagimg-dot/gitsnip" "refs/tags/v0.1.1" "d5e3c7d75b1b5145128d92cdb56abe08b623af22d96aa520e2411b18a794e4c6";
    vendorHash = "sha256-6O64eV+joSdYbPrHRM9X/cFuF1AZzEXEwImdOj6nUrc="; subPkgs = "./cmd/gitsnip"; ldflags = "-s -w -X github.com/dagimg-dot/gitsnip/internal/cli.version=0.1.1 -X github.com/dagimg-dot/gitsnip/internal/cli.commit=refs/tags/v0.1.1 -X github.com/dagimg-dot/gitsnip/internal/cli.builtBy=nixpkgs";
    check = chk ''"$out/bin/gitsnip" version'' "0\\.1\\.1"; };
  # gitty (MIT): contextual information about your git projects, right on the command-line.
  gitty = pkg { pname = "gitty"; version = "0.7.0"; src = gh "muesli/gitty" "v0.7.0" "cea3f7fa92653abd18ce951f24c64321edab8d8da9340f764c25cbfe8eba36ef";
    vendorHash = "sha256-bkXqVVXO/13NrwxrXw3wfpEfb0oA/i/YI0O2qBtqKzA="; subPkgs = "."; ldflags = "-s -w -X=main.Version=0.7.0";
    check = chk ''"$out/bin/gitty" --version'' "0\\.7\\.0"; };
  # gjo (MIT): small utility to create JSON objects.
  gjo = pkg { pname = "gjo"; version = "1.0.3"; src = gh "skanehira/gjo" "1.0.3" "89c2cb3fcb679a6d9dbfda4db9bde557ed5e1dae8b76f14450eb6e63956229e5";
    vendorHash = null; subPkgs = ".";
    check = chk ''"$out/bin/gjo" --help'' "[Uu]sage"; };
  # glance-agent (GPL-3.0-only): lightweight service that exposes system metrics via an HTTP API.
  glance-agent = pkg { pname = "glance-agent"; version = "0.1.0"; src = gh "glanceapp/agent" "refs/tags/v0.1.0" "a6294a60202b2c893c72e3c583156286936375b68f45d3f7ea563a2ea7b59ade";
    vendorHash = "sha256-M/L8zU8dwUnfebKZNLWpFJsJbwwcPUg9CFkRayEtmIc="; subPkgs = "."; ldflags = "-s -X github.com/glanceapp/agent/internal/agent.buildVersion=0.1.0";
    check = chk ''"$out/bin/agent" --version'' "0\\.1\\.0"; };
  # gnostic (Apache-2.0): compiler for APIs described by the OpenAPI Specification with plugins for code generation and other API support tasks.
  gnostic = pkg { pname = "gnostic"; version = "0.7.0"; src = gh "google/gnostic" "v0.7.0" "fa324d72ff38c35ed4eddc869f0a240ccac8d16b69cc6398077128c727a1b05b";
    vendorHash = "sha256-R/BMdYJ193DDUYUWRyXpJ1Xz59pi0anVTTUPf0Ag8i8="; subPkgs = ". ./cmd/disco ./cmd/parse-linter-output ./cmd/petstore-builder ./cmd/protoc-gen-jsonschema ./cmd/protoc-gen-openapi ./cmd/report ./cmd/report-messages ./cmd/vocabulary-operations ./generate-gnostic ./linters/go/gnostic-lint-descriptions ./linters/go/gnostic-lint-paths ./openapiv3/schema-generator ./plugins/gnostic-analyze ./plugins/gnostic-analyze/summarize ./plugins/gnostic-complexity ./plugins/gnostic-linter ./plugins/gnostic-plugin-request ./plugins/gnostic-process-plugin-response ./plugins/gnostic-summary ./plugins/gnostic-vocabulary ./tools/format-schema ./tools/j2y2j";
    check = chk ''"$out/bin/gnostic" --help'' "[-]-messages-out"; };
  # go-callvis (MIT): visualize call graph of a Go program using Graphviz.
  go-callvis = pkg { pname = "go-callvis"; version = "0.7.1"; src = gh "ondrajz/go-callvis" "v0.7.1" "8e78313de9c79c0d9bd215de9591924b29e13f8abb2bd5b524f29998b457b70d";
    vendorHash = "sha256-lDSKDj7LOeCKkIxB0qCpR0+mX3bzT7QSFlUNaeYKnxc="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/go-callvis" --version'' "0\\.7\\.1"; };
  # go-cqhttp (AGPL-3.0-only): golang implementation of OneBot based on Mirai and MiraiGo.
  go-cqhttp = pkg { pname = "go-cqhttp"; version = "1.2.0"; src = gh "Mrs4s/go-cqhttp" "v1.2.0" "2abf0b93c9fdf42a009134c8f8d1637c351a5c985e37432a733c847a834d630b";
    vendorHash = "sha256-PQBoK11LdpbMBwcSu5HAQ3WJ0dDvk8VEejBx+YcZVKM="; subPkgs = ". ./cmd/api-generator ./winres/gen";
    check = chk ''"$out/bin/go-cqhttp" --help'' "[-]update-protocol"; };
  # go-enum (MIT): enum generator for go.
  go-enum = pkg { pname = "go-enum"; version = "0.9.5"; src = gh "abice/go-enum" "refs/tags/v0.9.5" "70818e5c177493c335124abb5c102038bf31b0a77fb53e546979fd8131378939";
    vendorHash = "sha256-5ZVlSQmhgLo6u37q3TPdxD6hEy44ZE7F4oRAFKRalrM="; subPkgs = "."; ldflags = "-s -w -X main.version=v0.9.5 -X main.builtBy=nixpkgs";
    check = chk ''"$out/bin/go-enum" --version'' "0\\.9\\.5"; };
  # go-grip (MIT): preview Markdown files locally before committing them.
  go-grip = pkg { pname = "go-grip"; version = "0.10.0"; src = gh "chrishrb/go-grip" "refs/tags/v0.10.0" "15fe41b2c2e6c3d8ace76acb0b53871ec5045f22ab663f4d31ad300cf178cdde";
    vendorHash = "sha256-N+RfzvZW6TkOKmwcylmM4A5hyDj2+nIsklKHt35ut6c="; subPkgs = ".";
    check = chk ''"$out/bin/go-grip" --help'' "[-]-bounding-box"; };
  # go-i18n (MIT): translate your Go program into multiple languages.
  go-i18n = pkg { pname = "go-i18n"; version = "2.7.0"; src = gh "nicksnyder/go-i18n" "refs/tags/v2.7.0" "1f81e62fe1d0819617ade79cb8c219f873232ae675584e8b0d6f3928b7398965";
    vendorHash = "sha256-eGcTbsJ5AgLNN9vdOOPBORxoZZXaonps9rszPYBZ6Us="; subPkgs = "./goi18n";
    check = chk ''"$out/bin/goi18n" --help'' "[Uu]sage"; };
  # go-import-lint (MIT): golang source code analyzer that checks imports order.
  go-import-lint = pkg { pname = "go-import-lint"; version = "1.2.0"; src = gh "hedhyw/go-import-lint" "refs/tags/v1.2.0" "0e46246f833a02de40e53dab934441f18c5e9d8fb443ab3fe0af2e04efbb7566";
    vendorHash = null; subPkgs = "./cmd/go-import-lint";
    check = chk ''"$out/bin/go-import-lint" --help'' "[Uu]sage"; };
  # go-jsonnet (Apache-2.0): implementation of Jsonnet in pure Go.
  go-jsonnet = pkg { pname = "go-jsonnet"; version = "0.22.0"; src = gh "google/go-jsonnet" "refs/tags/v0.22.0" "9c463043a05c1e833c57136521e808ee8df192131f00c636235a2b54823d8c4c";
    vendorHash = "sha256-Lf+z0gHoGcBn+/zu2EOJL7ZU9wMGmivF5bOxTXQNzqQ="; subPkgs = "./cmd/jsonnet ./cmd/jsonnet-deps ./cmd/jsonnet-lint ./cmd/jsonnetfmt"; ldflags = "-s -w";
    check = chk ''"$out/bin/jsonnet" --version'' "0\\.22\\.0"; };
  # go-junit-report (MIT): convert go test output to junit xml.
  go-junit-report = pkg { pname = "go-junit-report"; version = "2.1.0"; src = gh "jstemmer/go-junit-report" "v2.1.0" "6320a11a2a8c564f5a92a44eeae40950246ae5c70b3c679a1e702e128d6e900b";
    vendorHash = "sha256-M0UUge3p1GGHzxGjKukmPOc13+/jdnivustfj6c5gAU="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/go-junit-report" --version'' "2\\.1\\.0"; };
  # go-mod-graph-chart (MIT): tool build chart by go mod graph output with zero dependencies.
  go-mod-graph-chart = pkg { pname = "go-mod-graph-chart"; version = "0.5.3"; src = gh "PaulXu-cn/go-mod-graph-chart" "v0.5.3" "0822ddb214930662d6c91d28e72cf9960dbeb4b1c4ccc5013032ba11e8d58993";
    vendorHash = null; subPkgs = "./gmchart";
    check = chk ''"$out/bin/gmchart" version'' "0\\.5\\.3"; };
  # go-mod-upgrade (MIT): update outdated Go dependencies interactively.
  go-mod-upgrade = pkg { pname = "go-mod-upgrade"; version = "0.13.0"; src = gh "oligot/go-mod-upgrade" "refs/tags/v0.13.0" "6d1542421e346b855cbe1f997eb917b47afc0d03845e6f91b604eb7855172fb1";
    vendorHash = "sha256-kLKxQwvnAGzLML/3n4kb5eZsH8COoTPmTffH/5hLWlg="; subPkgs = "."; ldflags = "-X main.version=0.13.0";
    check = chk ''"$out/bin/go-mod-upgrade" --version'' "0\\.13\\.0"; };
  # go-org (MIT): org-mode parser and static site generator in go.
  go-org = pkg { pname = "go-org"; version = "1.7.0"; src = gh "niklasfasching/go-org" "v1.7.0" "51aaa3c2347e4b4b028cb35559292a5e67680ea282fe595eec7721fc0c017162";
    vendorHash = "sha256-wMsSbZ1j/4CpKjC1spo2LJIJ+ljnYupbv6wZ3PLTsJc="; subPkgs = ".";
    check = chk ''"$out/bin/go-org" --help'' "[Uu]sage"; };
  # go-protobuf (BSD-3-Clause): go bindings for protocol buffer.
  go-protobuf = pkg { pname = "go-protobuf"; version = "1.5.4"; src = gh "golang/protobuf" "v1.5.4" "d75e6960ecfabaaa83a7261b1b630d24e9c63aca79615fb15bf33e11b62fd019";
    vendorHash = "sha256-Ffb/M9SqOP7iEQC6izV4kHG7SDG6c+j6QXEFqg/jic4="; subPkgs = "./internal/cmd/generate-alias ./protoc-gen-go";
    check = chk ''"$out/bin/generate-alias" --help'' "[Uu]sage"; };
  # go-shadowsocks2 (Apache-2.0): fresh implementation of Shadowsocks in Go.
  go-shadowsocks2 = pkg { pname = "go-shadowsocks2"; version = "0.1.5"; src = gh "shadowsocks/go-shadowsocks2" "v0.1.5" "7932c11d2315d263c09b5e7775ad2b9adf6cd3c132d59d98962c9598a1300acc";
    vendorHash = "sha256-McZ8A2Z++ugweOlZY/X6Wjc2J0HH30Oz9CvVALweglM="; subPkgs = ".";
    check = chk ''"$out/bin/go-shadowsocks2" --help'' "[-]plugin-opts"; };
  # go-swagger (Apache-2.0): golang implementation of Swagger 2.0, representation of your RESTful API.
  go-swagger = pkg { pname = "go-swagger"; version = "0.36.6"; src = gh "go-swagger/go-swagger" "refs/tags/v0.36.6" "e74772227718a6e022b12542929e983b419635279666227fdc09fb92b8533594";
    vendorHash = "sha256-idqwh8au2PC26Fi+Kuot+p/47Jr4XEGx7OKHwN1ybbo="; subPkgs = "./cmd/swagger"; ldflags = "-s -X=github.com/go-swagger/go-swagger/cmd/swagger/commands.Version=0.36.6 -X=github.com/go-swagger/go-swagger/cmd/swagger/commands.Commit=refs/tags/v0.36.6";
    check = chk ''"$out/bin/swagger" version'' "0\\.36\\.6"; };
  # go-tools (MIT): collection of tools and libraries for working with Go code, including linters and static analysis.
  go-tools = pkg { pname = "go-tools"; version = "2026.2.2"; src = gh "dominikh/go-tools" "refs/tags/2026.2.2" "f957eca5ee25bba46711433bfc320e0e900304ebb89641264bde256031926139";
    vendorHash = "sha256-iZuAy0XnN3+inooz5mh5yuBED1gWZWEH9j0SvA1FPjg="; subPkgs = "./cmd/staticcheck ./cmd/structlayout ./cmd/structlayout-optimize ./cmd/structlayout-pretty ./internal/cmd/ast-to-pattern ./internal/cmd/gogrep ./internal/cmd/irdump ./internal/cmd/unused";
    check = chk ''"$out/bin/staticcheck" --version'' "2026\\.2\\.2"; };
  # go-xmlstruct (MIT): generate Go structs from multiple XML documents.
  go-xmlstruct = pkg { pname = "go-xmlstruct"; version = "1.11.2"; src = gh "twpayne/go-xmlstruct" "refs/tags/v1.11.2" "efdbdfda869acc09c21913a5eef893b44fb954d7500e1e5b87f287c5624e4b75";
    vendorHash = "sha256-WX4XEAusnc8myuh8lHARKfdYzKF9z5pK8Cbhlw5hOjw="; subPkgs = "./cmd/goxmlstruct";
    check = chk ''"$out/bin/goxmlstruct" --help'' "[-]-use-pointers-for-optional-fields"; };
  # goa (MIT): design-based APIs and microservices in Go.
  goa = pkg { pname = "goa"; version = "3.30.0"; src = gh "goadesign/goa" "v3.30.0" "28ae003f3888e0763484ec91b4650c9df23e670c920450fdae6977c430268362";
    vendorHash = "sha256-6Z6JVZwn0fUsZq+LDBn98cMsA1r8SzCAzN95YDn+04E="; subPkgs = "./cmd/goa";
    check = chk ''"$out/bin/goa" version'' "3\\.30\\.0"; };
  # goat (MIT): go ASCII Tool. Render ASCII art as SVG diagrams.
  goat = pkg { pname = "goat"; version = "0.5.1"; src = gh "blampe/goat" "v0.5.1" "83ba5f079c8e5464fb8838127af70f477a54eb9eaf979d04abcd5f57c7db4a1c";
    vendorHash = "sha256-yS7HpJ7SyhydYm4cbZJID+VZgLOjtc930GB2lRYei7E="; subPkgs = "./cmd/goat ./cmd/goldmark ./cmd/tmpl-expand";
    check = chk ''"$out/bin/goat" --help'' "[-]list-embedded"; };
  # goblob (MIT): enumeration tool for publicly exposed Azure Storage blobs.
  goblob = pkg { pname = "goblob"; version = "1.2.2"; src = gh "Macmod/goblob" "refs/tags/v1.2.2" "27371cf514b4a007de8b7e6c01925111243bfdcb7a6b9622f412ab3a9492326e";
    vendorHash = null; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/goblob" --help'' "[Uu]sage"; };
  # gobuster (Apache-2.0): tool used to brute-force URIs, DNS subdomains, Virtual Host names on target web servers.
  gobuster = pkg { pname = "gobuster"; version = "3.8.2"; src = gh "OJ/gobuster" "refs/tags/v3.8.2" "6919232eafbd0c4bbc9664d7f434b6a8d82133aa09f1400341ef6985ceff208a";
    vendorHash = "sha256-Or1SsDMaSHvnpFyPA2Xva5X2w4acTJBthJzdHmR3soc="; subPkgs = ". ./vhs"; ldflags = "-s -w";
    check = chk ''"$out/bin/gobuster" --version'' "3\\.8\\.2"; };
  # gocovsh (GPL-3.0-only): go Coverage in your terminal: a tool for exploring Go Coverage reports from the command line.
  gocovsh = pkg { pname = "gocovsh"; version = "0.6.1"; src = gh "orlangure/gocovsh" "refs/tags/v0.6.1" "d0076556bb6762a9bd75ae5f50d99ea6806673e9302b2629bc53eb35abae8cd7";
    vendorHash = "sha256-gbKoGc+lingQWqy/O2VYvAzMd0gM0IZQE6M4YASlK1U="; subPkgs = "."; ldflags = "-s -X main.version=0.6.1 -X main.commit=v0.6.1 -X main.date=19700101T000000Z";
    check = chk ''"$out/bin/gocovsh" --version'' "0\\.6\\.1"; };
  # goda (MIT): go Dependency Analysis toolkit.
  goda = pkg { pname = "goda"; version = "0.9.4"; src = gh "loov/goda" "v0.9.4" "e277e37c9584575938540a05881674a089bfd35818b28cd05663ecb740267465";
    vendorHash = "sha256-sW6Tx4fnmzUt+NiSTtVYeP3HPnYRYfdn0UqfcNog/jM="; subPkgs = ".";
    check = chk ''"$out/bin/goda" --help'' "[Uu]sage"; };
  # godef (BSD-3-Clause): print where symbols are defined in Go source code.
  godef = pkg { pname = "godef"; version = "1.2.0"; src = gh "rogpeppe/godef" "v1.2.0" "38cdb91bcec60e38fb4b463e961608a88bc083796fe97230d68d8bc91a12fc79";
    vendorHash = "sha256-9HdX2Hk/8G6hhP1fEakgqiNrPqnnbddBksvkxpRXPgU="; subPkgs = ".";
    check = chk ''"$out/bin/godef" --help'' "[-]new-implementation"; };
  # gofumpt (BSD-3-Clause): stricter gofmt.
  gofumpt = pkg { pname = "gofumpt"; version = "0.12.0"; src = gh "mvdan/gofumpt" "v0.12.0" "b6d5d14692cad23996da4329bf24d30324af30125dd5261e6d9b0c5bc8b20b28";
    vendorHash = "sha256-PzIzdvrBkUnUUH2zyBtCFCoXYSHlJFK053D1m2Syu0Y="; subPkgs = "."; ldflags = "-s -X main.version=v0.12.0";
    check = chk ''"$out/bin/gofumpt" --version'' "0\\.12\\.0"; };
  # gogogadget (MIT): single binary collection of tools useful for penetration testers and system administrators.
  gogogadget = pkg { pname = "gogogadget"; version = "0.1.0"; src = gh "VigilantSys/GoGoGadget" "refs/tags/v0.1.0" "5d275f7a9719c3728384761ad9851e005dfcfacb98179794f7231f6f7b5f3642";
    vendorHash = "sha256-OgkEwhZ2k5hheVp7EfAD/+rQrYozTuYtNqHIt318xlE="; subPkgs = "."; ldflags = "-s";
    check = chk ''"$out/bin/gogogadget" --help'' "[Uu]sage"; };
  # goimports-reviser (MIT): right imports sorting & code formatting tool (goimports alternative).
  goimports-reviser = pkg { pname = "goimports-reviser"; version = "3.13.2"; src = gh "incu6us/goimports-reviser" "v3.13.2" "17c90e414f492cb1d0444845655b45729bf0636d6f421a3b17180702713a3934";
    vendorHash = "sha256-EqBClSMtz66qQzU2RUTEHyB+u6MYOiRUh7sNky1cgwA="; subPkgs = "."; ldflags = "-s -w -X=main.Tag=v3.13.2";
    check = chk ''"$out/bin/goimports-reviser" --version'' "3\\.13\\.2"; };
  # gojo (MIT): yet another Go implementation of jo.
  gojo = pkg { pname = "gojo"; version = "0.3.3"; src = gh "itchyny/gojo" "refs/tags/v0.3.3" "a80d9949ad29592e93a1dc342c48e6b626f1c9337649786fad941f26c0304ab4";
    vendorHash = "sha256-no57XWFespOJo1Vbrn1aW6n6Wg9kuANft0AGY/A/Mxw="; subPkgs = "./cmd/gojo";
    check = chk ''"$out/bin/gojo" --version'' "0\\.3\\.3"; };
  # gojsontoyaml (MIT): simply tool to convert json to yaml written in Go.
  gojsontoyaml = pkg { pname = "gojsontoyaml"; version = "0.1.0"; src = gh "brancz/gojsontoyaml" "v0.1.0" "487a5c46d1bdad1348e3297aaf2cd859c943e487dc9592ffd000dc3e364d6700";
    vendorHash = null; subPkgs = ".";
    check = chk ''"$out/bin/gojsontoyaml" --help'' "[Uu]sage"; };
  # gokart (Apache-2.0): static analysis tool for securing Go code.
  gokart = pkg { pname = "gokart"; version = "0.5.1"; src = gh "praetorian-inc/gokart" "v0.5.1" "81bf1e26531117de4da9b160ede80aa8f6c4d4984cc1d7dea398083b8e232eb7";
    vendorHash = "sha256-rb/2EMRfA3KpFcz4d5J9hLh1yWL45zbFKmEGx10PVbI="; subPkgs = ".";
    check = chk ''"$out/bin/gokart" version'' "0\\.5\\.1"; };
  # gokey (BSD-3-Clause): vault-less password store.
  gokey = pkg { pname = "gokey"; version = "0.2.1"; src = gh "cloudflare/gokey" "refs/tags/v0.2.1" "b9f03491efa3b3481fc78246f62c6786ba19e9c9c8c36461cc8b949081f5896d";
    vendorHash = "sha256-ugPma+v3Afkw8IreBv7t7Cuvr53u7eKtqnMCw34m0yE="; subPkgs = "./cmd/gokey";
    check = chk ''"$out/bin/gokey" --help'' "[Uu]sage"; };
  # goldilocks (Apache-2.0): get your resource requests "Just Right".
  goldilocks = pkg { pname = "goldilocks"; version = "4.15.1"; src = gh "FairwindsOps/goldilocks" "refs/tags/v4.15.1" "0401803e6dd7ed954726ffd67ea15d78319c2d0d28c65a22ebc3cc159cdf7d35";
    vendorHash = "sha256-bLYCXcDDX0GYDo9Mv6IkNPTQ5pizhgiMlQI9WksV2bM="; subPkgs = "."; ldflags = "-s -w -X main.version=4.15.1";
    check = chk ''"$out/bin/goldilocks" version'' "4\\.15\\.1"; };
  # gollama (MIT): go manage your Ollama models.
  gollama = pkg { pname = "gollama"; version = "2.0.6"; src = gh "sammcj/gollama" "refs/tags/v2.0.6" "dd999558960f63daf36be8fe9fc04c32a15f53216115420c554b81cec6becb69";
    vendorHash = "sha256-yIRpAb0DQPr7wEFhyWFUfK3nPOwhHnOYLsyc1IXQ3Jg="; subPkgs = "."; ldflags = "-s -w -X main.Version=2.0.6";
    check = chk ''"$out/bin/gollama" --help'' "[-]no-cleanup"; };
  # gomatrix (BSD-2-Clause): displays "The Matrix" in a terminal.
  gomatrix = pkg { pname = "gomatrix"; version = "101.0.0"; src = gh "GeertJohan/gomatrix" "v101.0.0" "4d71d2509ac84f2340537d5e6f0eb9810b4173706f13cd6fe5e5e8ee5a69a50c";
    vendorHash = "sha256-VZzFtQo4ODojVfX/IyYEO5uj2WVCMfTZtfevAuxvswM="; subPkgs = ".";
    check = chk ''"$out/bin/gomatrix" --help'' "[Uu]sage"; };
  # gomodifytags (BSD-3-Clause): go tool to modify struct field tags.
  gomodifytags = pkg { pname = "gomodifytags"; version = "1.17.0"; src = gh "fatih/gomodifytags" "v1.17.0" "a490786d80c962dc946b8f9804ffec596c1087dbf91b122b9b5903c03b6da6b9";
    vendorHash = "sha256-CzPmB/lnHK/q5wRUGu2Dw8QkEi3nTDPQMLAi6XJRgKc="; subPkgs = ".";
    check = chk ''"$out/bin/gomodifytags" --help'' "[-]clear-options"; };
  # gomtree (BSD-3-Clause): file systems verification utility and library, in likeness of mtree(8).
  gomtree = pkg { pname = "gomtree"; version = "0.7.0"; src = gh "vbatts/go-mtree" "v0.7.0" "ba4687f1c9d4afc761a3f05af1267754a7e5e88965c9a1d2d8700579f5a6fa12";
    vendorHash = null; subPkgs = "./cmd/gomtree"; ldflags = "-s -X main.Version=0.7.0";
    check = chk ''"$out/bin/gomtree" --version'' "0\\.7\\.0"; };
  # gonzo (MIT): TUI log analysis tool.
  gonzo = pkg { pname = "gonzo"; version = "0.4.3"; src = gh "control-theory/gonzo" "refs/tags/v0.4.3" "cc9b0c79238f39b18f05ac5076c286166984d55056e8583fd9964b6594f7409f";
    vendorHash = "sha256-SvAE50fZ3m9IjOcJkYdIj0wcUCIBkX12//TwERpteTQ="; subPkgs = "./cmd/gonzo"; ldflags = "-s -w -X=main.version=0.4.3 -X=main.commit=v0.4.3 -X=main.buildTime=1970-01-01T00:00:00Z -X=main.goVersion=1.27.3";
    check = chk ''"$out/bin/gonzo" --version'' "0\\.4\\.3"; };
  # google-cloud-bigtable-tool (Apache-2.0): google Cloud Bigtable Tool.
  google-cloud-bigtable-tool = pkg { pname = "google-cloud-bigtable-tool"; version = "0.12.0"; src = gh "googleapis/cloud-bigtable-cbt-cli" "v.0.12.0" "884f976eb0b57ed02230b16db4622bcb1ebb128f5750f77cbce926259f06555e";
    vendorHash = "sha256-WUifvE0p93+PMevhTzzKXIZIX2GgIsnQ+q/fLs3SecA="; subPkgs = ".";
    check = chk ''"$out/bin/cbt" --help'' "[-]admin-endpoint"; };
  # goose-lang (MIT): goose converts a small subset of Go to Coq.
  goose-lang = pkg { pname = "goose-lang"; version = "0.9.2"; src = gh "goose-lang/goose" "v0.9.2" "b3348ad8b91d92e8da7d7fddd509966dd6f038a020f50d9efe70c2977c222f82";
    vendorHash = "sha256-YRJn1JLuuhm4T0pUOE1kjbmFVFH91Zg4S15Mm/qUlLw="; subPkgs = "./cmd/goose ./cmd/test_gen"; ldflags = "-s -w";
    check = chk ''"$out/bin/goose" --help'' "[-]skip-interfaces"; };
  # gopacked (AGPL-3.0-or-later): simple text-based Minecraft modpack manager.
  gopacked = pkg { pname = "gopacked"; version = "0.4.1"; src = gh "tulir/gopacked" "v0.4.1" "a121e9e297574a5926f34966e82deecf365e66d94a7b8c54fcb1fd8d1bdae44c";
    vendorHash = "sha256-wCnrOUBNexfdcu7EgC/YsdMDjid7tY9YgqnSxF/ut6Q="; subPkgs = "./cmd/gopacked ./cmd/twitchparse";
    check = chk ''"$out/bin/gopacked" --version'' "0\\.4\\.1"; };
  # goplantuml (MIT): plantUML Class Diagram Generator for golang projects.
  goplantuml = pkg { pname = "goplantuml"; version = "1.6.3"; src = gh "jfeliu007/goplantuml" "refs/tags/v1.6.3" "83a49407045e2236618c21df9a4e1cdc92fe95ede9003b767ccb6d21fe58162b";
    vendorHash = "sha256-7V9zFzHbeYbJOpJznhqTy2q/7k4LiS9YDrywDxk6Ic4="; subPkgs = "./cmd/goplantuml";
    check = chk ''"$out/bin/goplantuml" --help'' "[-]aggregate-private-members"; };
  # gore (MIT): yet another Go REPL that works nicely.
  gore = pkg { pname = "gore"; version = "0.7.0"; src = gh "x-motemen/gore" "v0.7.0" "88e2f6f52eb5fd4b5359d822f9f3fcb99a0f868eff1e4da19880bebba3143718";
    vendorHash = "sha256-Y4i4zDTrggFRfoql74RIQzdI5Uihb5y9Dx/jjieN9a4="; subPkgs = "./cmd/gore";
    check = chk ''"$out/bin/gore" --version'' "0\\.7\\.0"; };
  # goread (GPL-3.0-or-later): beautiful program to read your RSS/Atom feeds right in the terminal.
  goread = pkg { pname = "goread"; version = "1.7.3"; src = gh "TypicalAM/goread" "v1.7.3" "9b08cae05593034711c599b6b17605194a11bbfae769b4e7e0076a01ec197c37";
    vendorHash = "sha256-JmvDiS9RAvLzAilRgrTylxCuafBbZ6RT/QwRTFlc2pw="; subPkgs = ".";
    check = chk ''"$out/bin/goread" --version'' "1\\.7\\.3"; };
  # goreman (MIT): foreman clone written in go language.
  goreman = pkg { pname = "goreman"; version = "0.3.19"; src = gh "mattn/goreman" "refs/tags/v0.3.19" "d5076b8844a4e29815b557927c326d8683ca4a91c8b3ffdad6fd33f238149e43";
    vendorHash = "sha256-bum7v8x0ffvja5KO4oPbHwJzxnSv2XSMBBkbQT5U/fI="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/goreman" version'' "0\\.3\\.19"; };
  # gosec (Apache-2.0): golang security checker.
  gosec = pkg { pname = "gosec"; version = "2.30.0"; src = gh "securego/gosec" "v2.30.0" "58ad3a584453ad31f0b646818bcd1cc005afd20ef507d71cd41821fbba506332";
    vendorHash = "sha256-Nr7L1rzYzHZyCm7sAl5zyZTetPFf1CIt3qpfmpi44a4="; subPkgs = "./cmd/gosec"; ldflags = "-s -w -X main.Version=2.30.0 -X main.GitTag=v2.30.0 -X main.BuildDate=unknown";
    check = chk ''"$out/bin/gosec" --version'' "2\\.30\\.0"; };
  # gosh (MIT): reverse/bind shell generator.
  gosh = pkg { pname = "gosh"; version = "1.0.0"; src = gh "redcode-labs/GoSH" "refs/tags/v1.0.0" "ebe449450111bee67e96e74cb2345f4c69eaecff4cf373a5337faa9fe94e7c73";
    vendorHash = "sha256-sKJg2D7847hfaWmIXNgzO38fNKgvg2WECJGje8ZxFMY="; subPkgs = ".";
    check = chk ''"$out/bin/GoSH" --help'' "[Uu]sage"; };
  # gosimports (BSD-3-Clause): simpler goimports.
  gosimports = pkg { pname = "gosimports"; version = "0.3.8"; src = gh "rinchsan/gosimports" "v0.3.8" "f520d482d343b1ed378fa19d0a4bea114c03f868defbf1ada796ac87816f0d94";
    vendorHash = "sha256-om+sE3RvnaMSzAZBw4wU7L8Q4sxdWp2LE4cv8gffCGI="; subPkgs = "./cmd/gosimports"; ldflags = "-s -w -X main.version=0.3.8";
    check = chk ''"$out/bin/gosimports" --version'' "0\\.3\\.8"; };
  # gospider (MIT): fast web spider written in Go.
  gospider = pkg { pname = "gospider"; version = "1.1.6"; src = gh "jaeles-project/gospider" "v1.1.6" "7cea9840c8a81c4b6be2c5984b25398a13bfe83cfd613332e8092f4c69d6ab5f";
    vendorHash = "sha256-lnHoIxTOjRpgKhacaMQpw1/HVCkWT5ntwoxFVTjZ3qk="; subPkgs = ".";
    check = chk ''"$out/bin/gospider" --version'' "1\\.1\\.6"; };
  # gostatic (ISC): fast static site generator.
  gostatic = pkg { pname = "gostatic"; version = "2.35"; src = gh "sansolovyov/gostatic" "2.35" "a179a469938c4ea6be7185bfcab42153114e0b95b62006ec266eccf5e73d3ae3";
    vendorHash = "sha256-AgDJdmDmS76x8PWJqZbsbgn9KoqGFlSGB9qUbrUpryc="; subPkgs = ".";
    check = chk ''"$out/bin/gostatic" --version'' "2\\.35"; };
  # gotestdox (MIT): tool for formatting Go test results as readable documentation.
  gotestdox = pkg { pname = "gotestdox"; version = "0.2.3"; src = gh "bitfield/gotestdox" "v0.2.3" "575ec06ce737f5d9911d69dd39b75e376a2da0b73dc0bac023b4b0eaf8a01d5c";
    vendorHash = "sha256-4GYLdGbTH2tPbWrJVy3yF5olor/Sq0JQHbkgNmQWilU="; subPkgs = "./cmd/gotestdox"; ldflags = "-s -w";
    check = chk ''"$out/bin/gotestdox" -h'' "[Uu]sage"; };
  # gotestfmt (Unlicense): go test output for humans.
  gotestfmt = pkg { pname = "gotestfmt"; version = "2.5.0"; src = gh "gotesttools/gotestfmt" "v2.5.0" "dd9481db9472dbc7a4c1f15b7a25f3ce783e793bcc1ab25e336a88d0912e2121";
    vendorHash = null; subPkgs = "./cmd/gotestfmt ./cmd/gotestfmt-formatter";
    check = chk ''"$out/bin/gotestfmt" --help'' "[-]template-dir"; };
  # gotests (Apache-2.0): generate Go tests from your source code.
  gotests = pkg { pname = "gotests"; version = "1.9.0"; src = gh "cweill/gotests" "v1.9.0" "1a36874dd5beec211e9b9aaf7d72be8839e76b5ad0a002cb4e83b80ad948697b";
    vendorHash = "sha256-sX0XYjbE8f3/c7T0SaCWJbylOTiTvQYrWHQ8X/Y1l1s="; subPkgs = "./gotests";
    check = chk ''"$out/bin/gotests" --help'' "[-]ai-max-cases"; };
  # gotestwaf (MIT): tool for API and OWASP attack simulation.
  gotestwaf = pkg { pname = "gotestwaf"; version = "0.5.11"; src = gh "wallarm/gotestwaf" "refs/tags/v0.5.11" "4f80879d0e8e4fc81c98c720f3ee7352f4e50176dac84442124c92ea3a886027";
    vendorHash = "sha256-8BpGa2RIx6kotb4EohyiCH6pdIHn7yBQPjPO4UXKukw="; subPkgs = "./cmd/gotestwaf"; ldflags = "-w -s -X=github.com/wallarm/gotestwaf/internal/version.Version=v0.5.11";
    check = chk ''"$out/bin/gotestwaf" --version'' "0\\.5\\.11"; };
  # gotip (MIT): go test interactive picker.
  gotip = pkg { pname = "gotip"; version = "0.10.2"; src = gh "lusingander/gotip" "refs/tags/v0.10.2" "77451f3bb35954ed473620ab0b8848d32abb5535f8d31aeb83eb3d6bdc751d32";
    vendorHash = "sha256-W1TZLS2xlbweNClGq2E9MPY0l4DE2VpVUEDBdzDBd0A="; subPkgs = "./cmd/gotip"; ldflags = "-s -w";
    check = chk ''"$out/bin/gotip" --version'' "0\\.10\\.2"; };
  # gotree (BSD-3-Clause): display a tree of files and directories.
  gotree = pkg { pname = "gotree"; version = "1.4.3"; src = gh "elbachir-one/gt" "v1.4.3" "33de9e42658c50eb639f8a6848ad89cb279d3fc35286c639b44b8b665c8d6f17";
    vendorHash = null; subPkgs = ".";
    check = chk ''"$out/bin/gt" --help'' "[-]order-by-extension"; };
  # gotrue (MIT): SWT based API for managing users and issuing SWT tokens.
  gotrue = pkg { pname = "gotrue"; version = "1.0.1"; src = gh "netlify/gotrue" "v1.0.1" "45116abd6edd9cce336eebb2ddf82fc73796144427d1b42b04a5a1bf6dd1d79e";
    vendorHash = "sha256-TiyAiMH2lrvCJ3lb8Yu0zftFpeG/4Nz+QRzI5eVV+L4="; subPkgs = "."; ldflags = "-s -w -X=github.com/netlify/gotrue/cmd.Version=1.0.1";
    check = chk ''"$out/bin/gotrue" version'' "1\\.0\\.1"; };
  # goverter (MIT): generate type-safe Go converters by defining function signatures.
  goverter = pkg { pname = "goverter"; version = "1.11.1"; src = gh "jmattheis/goverter" "refs/tags/v1.11.1" "3c2efce15314bb275ecc5d8598852d50a005669054e8e8203a872ed6f5645877";
    vendorHash = "sha256-uzWbSk9Yr951/daF0C4aHmKhGEDPqe23wA/KDVq1zu4="; subPkgs = "./cmd/goverter";
    check = chk ''"$out/bin/goverter" --help'' "[-]output-constraint"; };
  # gowrap (MIT): goWrap is a command line tool for generating decorators for Go interfaces.
  gowrap = pkg { pname = "gowrap"; version = "1.5.0"; src = gh "hexdigest/gowrap" "refs/tags/v1.5.0" "16634184e07e01906a243545d6c234e078404684637f21b7254c84ddb4330496";
    vendorHash = "sha256-Y7e/bTva4+seNDylu8iW5rkPcsXu+Om/2MvrmZHnx2s="; subPkgs = "./cmd/gowrap"; ldflags = "-X=github.com/hexdigest/gowrap.version=1.5.0";
    check = chk ''"$out/bin/gowrap" --help'' "[Uu]sage"; };
  # grizzly (Apache-2.0): utility for managing Jsonnet dashboards against the Grafana API.
  grizzly = pkg { pname = "grizzly"; version = "0.7.1"; src = gh "grafana-cold-storage/grizzly" "v0.7.1" "81811b684ef1bddd3b7147c5095224552a0b35dc3ff210d10e6cbc5e12331160";
    vendorHash = "sha256-dkRYEnkELiom6LTpuOhfd+PBv35EuiIi0n/cyfKmZss="; subPkgs = "./cmd/grr";
    check = chk ''"$out/bin/grr" --help'' "[Uu]sage"; };
  # gron (MIT): make JSON greppable.
  gron = pkg { pname = "gron"; version = "0.7.1"; src = gh "tomnomnom/gron" "v0.7.1" "1c98f2ef2ba03558864b1ab5e9c4b47a2e89d3ffaf24cfa0ac75cd38d775feb4";
    vendorHash = "sha256-U9WojKqWjlf6pQRfOC86eAF25R7eA39a4KRC4ls19po="; subPkgs = "."; ldflags = "-s -w -X main.gronVersion=0.7.1";
    check = chk ''"$out/bin/gron" --version'' "0\\.7\\.1"; };
  # grpcurl (MIT): like cURL, but for gRPC: Command-line tool for interacting with gRPC servers.
  grpcurl = pkg { pname = "grpcurl"; version = "1.9.4"; src = gh "fullstorydev/grpcurl" "v1.9.4" "bea899ba2f483a951bf40aa05d41e069dd2f7bfe52d2a229717abfdb5620cb7c";
    vendorHash = "sha256-bkvyYDtUtXNa8Pf2J9p9nh97rS8bm2tKEtG4WZNSpdk="; subPkgs = "./cmd/grpcurl"; ldflags = "-s -w -X main.version=1.9.4";
    check = chk ''"$out/bin/grpcurl" --version'' "1\\.9\\.4"; };
  # gtfocli (Apache-2.0): GTFO Command Line Interface for search binaries commands to bypass local security restrictions.
  gtfocli = pkg { pname = "gtfocli"; version = "0.0.6"; src = gh "cmd-tools/gtfocli" "refs/tags/0.0.6" "b11ecb9b7ba6124c96599e774d51de7901e92a4a75d64dafb7b0d4e5c29fcc8c";
    vendorHash = "sha256-1LUZOyePUQEqcjFAYmS60KvlEm2XP1JRRF0YsLnhBoc="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/gtfocli" --help'' "[Uu]sage"; };
  # gungnir (MIT): command-line tool that continuously monitors certificate transparency (CT) logs for newly issued SSL/TLS certificates.
  gungnir = pkg { pname = "gungnir"; version = "1.4.0"; src = gh "g0ldencybersec/gungnir" "v1.4.0" "ace1c3746cbb411b8335244854fa4b2d9621764445b073bf99903c0deed877fb";
    vendorHash = "sha256-ayp4Cs9JUgfS1XZk9r90cjDkGnk5/ndjAGZl5UmCFLs="; subPkgs = "./cmd/gungnir"; ldflags = "-s -w";
    check = chk ''"$out/bin/gungnir" --help'' "[Uu]sage"; };
  # gx-go (MIT): tool for importing go packages into gx.
  gx-go = pkg { pname = "gx-go"; version = "1.9.0-unstable-2020-03-03"; src = gh "whyrusleeping/gx-go" "9c30fadeac4aee8346d28c36d6bd5063da3d189a" "092034aeb59a9ce517520fcc1ae940f2ac80ba8be3770a229035bc68f8cb302b";
    vendorHash = "sha256-j17GdPUGKw+KL9pEv14VV8AUgwa3+U0a48iIbzIyPk4="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/gx-go" --help'' "[Uu]sage"; };
  # h2spec (MIT): testing tool for HTTP/2 implementation.
  h2spec = pkg { pname = "h2spec"; version = "2.6.0"; src = gh "summerwind/h2spec" "refs/tags/v2.6.0" "c438130c70c6cec2c20276726a454a9249b64ba48ca89ce37f39aa721867b4f0";
    vendorHash = "sha256-+wqUM9XWE+Lu3Ygmv3fnXX9woVRrLgVWlWXAzjQNvj8="; subPkgs = "./cmd/h2spec ./cmd/h2specd"; ldflags = "-s -w -X=main.VERSION=2.6.0 -X main.COMMIT=2.6.0";
    check = chk ''"$out/bin/h2spec" --version'' "2\\.6\\.0"; };
  # hakrawler (GPL-3.0-only): web crawler for the discovery of endpoints and assets.
  hakrawler = pkg { pname = "hakrawler"; version = "2.1"; src = gh "hakluke/hakrawler" "2.1" "bdd108e83ac590121abed30fea5ecf41136007e720dfcac3dd429cd04f860292";
    vendorHash = "sha256-PdLKW3NlaRXwCM8ybvov86OvUjcNRud+NEUHXfL0TG0="; subPkgs = ".";
    check = chk ''"$out/bin/hakrawler" --help'' "[Uu]sage"; };
  # harsh (MIT): CLI habit tracking for geeks.
  harsh = pkg { pname = "harsh"; version = "0.14.5"; src = gh "wakatara/harsh" "refs/tags/v0.14.5" "37516772901d1cd31e7a9655dd3c3f522099f9c0467f3ef886d64301dd8b84a0";
    vendorHash = "sha256-vbUSs8i4rbSGnBfzWDX4a85JT3fQij+liUyj1vVtjkg="; subPkgs = ".";
    check = chk ''"$out/bin/harsh" --help'' "[-]-hide-ended"; };
  # hashi-up (MIT): lightweight utility to install HashiCorp Consul, Nomad, or Vault on any remote Linux host.
  hashi-up = pkg { pname = "hashi-up"; version = "0.16.0"; src = gh "jsiebens/hashi-up" "v0.16.0" "c1c793fbc6dbce5ccd61117dc4ca74b41cb9f43605b469f202071d39b0919dff";
    vendorHash = "sha256-TosXQ9+h817UL8zOCt00wqWLxz+rdkgnoFu6dC6YKA8="; subPkgs = ".";
    check = chk ''"$out/bin/hashi-up" --help'' "[Uu]sage"; };
  # hcdiag (MPL-2.0): collects and bundles product and platform diagnostics supporting Consul, Nomad, TFE, and Vault.
  hcdiag = pkg { pname = "hcdiag"; version = "0.5.13"; src = gh "hashicorp/hcdiag" "refs/tags/v0.5.13" "a22407652f683b9e20009b527c44fb59da659cceef67363270b9cd750ce7a342";
    vendorHash = "sha256-VIhZQ6hQNP1BJcYQvgqQWC7e1NO5SKS7Mjvxq7PgC+Q="; subPkgs = ".";
    check = chk ''"$out/bin/hcdiag" --version'' "0\\.5\\.13"; };
  # go-landlock (MIT): go library for the Linux Landlock sandboxing feature.
  go-landlock = pkg { pname = "go-landlock"; version = "0-unstable-2024-02-16"; src = gh "landlock-lsm/go-landlock" "efb66220540a9ef86aa0160d15e55f429d5b94d9" "8cdd3c56e4919d3a83223464740b74dac570713087253a06715df5beb2a74299";
    vendorHash = "sha256-vXdINia6HHIea4UQcyWG3jhtXpHSOPq+V230lNlohIs="; subPkgs = "./cmd/landlock-restrict-net ./cmd/landlock-restrict";
    check = chk ''"$out/bin/landlock-restrict-net" --help'' "[Uu]sage"; };
  # go-licence-detector (Apache-2.0): detect licences in Go projects and generate documentation.
  go-licence-detector = pkg { pname = "go-licence-detector"; version = "0.11.1"; src = gh "elastic/go-licence-detector" "v0.11.1" "12e7072a1fefb43d42299e72ee89d5b13a84ee0dbabe8a60b89e07fbe8cce1aa";
    vendorHash = "sha256-K9YlVtWaITIS63yqt3ZMsmUxnuLkbOYlEkWefeAStQQ="; subPkgs = ".";
    check = chk ''"$out/bin/go-licence-detector" --help'' "[-]-template-value"; };
  # gocyclo (BSD-3-Clause): calculate cyclomatic complexities of functions in Go source code.
  gocyclo = pkg { pname = "gocyclo"; version = "0.6.0"; src = gh "fzipp/gocyclo" "v0.6.0" "2cf9b301b6582f11bb41c4fcc24c50b74ea49db21704f1e4ba1f9c1d614f223a";
    vendorHash = null; subPkgs = "./cmd/gocyclo";
    check = chk ''"$out/bin/gocyclo" --help'' "[-]avg-short"; };
  # hcl2json (Apache-2.0): convert hcl2 to json.
  hcl2json = pkg { pname = "hcl2json"; version = "0.6.9"; src = gh "tmccombs/hcl2json" "v0.6.9" "df7361e4ea5f34de02a81afa06f515bc6379efeb5ab86c154c6a31def6bcb3dc";
    vendorHash = "sha256-wlBwVQk/kLsbTTr2feKKTjqZAeGGXZSPK+Hqeh7fWR0="; subPkgs = ".";
    check = chk ''"$out/bin/hcl2json" --help'' "[Uu]sage"; };
  # hcledit (MIT): command line editor for HCL.
  hcledit = pkg { pname = "hcledit"; version = "0.2.19"; src = gh "minamijoyo/hcledit" "v0.2.19" "c89c66d480caa4365ba6318580964e551ce89b52087c44c6d73daa8a5d83623b";
    vendorHash = "sha256-8RB8qu3IWEKWx8G3mwOWvEqPuRo1Ymj9Y4wMGxXsG6o="; subPkgs = ".";
    check = chk ''"$out/bin/hcledit" version'' "0\\.2\\.19"; };
  # hclfmt (MPL-2.0): code formatter for the Hashicorp Configuration Language (HCL) format.
  hclfmt = pkg { pname = "hclfmt"; version = "2.25.0"; src = gh "hashicorp/hcl" "refs/tags/v2.25.0" "a2cc385ada570cea4e623c4e7eae862e1a920482e91fb08d24590fc1c546e8d1";
    vendorHash = "sha256-wijMtlnruEMAzQ1LWN8C0XbHHByuZzmycbsZuiHrFP4="; subPkgs = "./cmd/hclfmt";
    check = chk ''"$out/bin/hclfmt" --help'' "[-]require-no-change"; };
  # helm-docs (GPL-3.0-only): tool for automatically generating markdown documentation for Helm charts.
  helm-docs = pkg { pname = "helm-docs"; version = "1.14.2"; src = gh "norwoodj/helm-docs" "v1.14.2" "88d1b3401220b2032cd27974264d2dc0da8f9e7b67a8a929a0848505c4e4a0ae";
    vendorHash = "sha256-GbbMzqQ+DuoWmJbcQ/FI3q5NqKahNLL2Wf9DGQQrx7Q="; subPkgs = "./cmd/helm-docs"; ldflags = "-w -s -X main.version=1.14.2";
    check = chk ''"$out/bin/helm-docs" --version'' "1\\.14\\.2"; };
  # helmsman (MIT): helm Charts (k8s applications) as Code tool.
  helmsman = pkg { pname = "helmsman"; version = "4.0.5"; src = gh "mkubaczyk/helmsman" "v4.0.5" "d7a49bd4322dfc4f1f8136fe0bcce5ef0bbb9aafe895945580178861fd908ac4";
    vendorHash = "sha256-VjWDeqNpPnIex1A1IT6Lu8azA3jQWFkTtRTADXxWg7w="; subPkgs = "./cmd/helmsman";
    check = chk ''"$out/bin/helmsman" --help'' "[-]check-for-chart-updates"; };
  # hexxy (MIT): modern and beautiful alternative to xxd and hexdump.
  hexxy = pkg { pname = "hexxy"; version = "0.1.1"; src = gh "sweetbbak/hexxy" "refs/tags/v0.1.1" "9ba337fde77a7fa1c79c82eb661dca33901830edf365ad21d5713efc52adcf5f";
    vendorHash = "sha256-r+au6j8YTd3BZ76thNN084m2JeLki+og6mQk1mSmejQ="; subPkgs = "./cmd/hexxy"; ldflags = "-s -w";
    check = chk ''"$out/bin/hexxy" --help'' "[-]-no-color"; };
  # hjson-go (MIT): utility to convert JSON to and from HJSON.
  hjson-go = pkg { pname = "hjson-go"; version = "4.7.1"; src = gh "hjson/hjson-go" "v4.7.1" "2881c114bcd194860155885e3c3586b6e41832818ea5cbf9c661a6a7990a79b6";
    vendorHash = null; subPkgs = "./hjson-cli"; ldflags = "-s -w";
    check = chk ''"$out/bin/hjson-cli" --help'' "[Uu]sage"; };
  # honeymarker (Apache-2.0): simple CRUD interface for dealing with per-dataset markers on honeycomb.io.
  honeymarker = pkg { pname = "honeymarker"; version = "0.2.12"; src = gh "honeycombio/honeymarker" "v0.2.12" "4d0e7f491d9040c01958746534be49cfa89ce5bd0d1754f66d90cad1c72cda8a";
    vendorHash = "sha256-F2unpvBo6nZdRbQq8F+xvTcHQFpR+nEC/ZrdP+nokNo="; subPkgs = ".";
    check = chk ''"$out/bin/honeymarker" --help'' "[Uu]sage"; };
  # honeyvent (Apache-2.0): CLI for sending individual events to honeycomb.io.
  honeyvent = pkg { pname = "honeyvent"; version = "1.1.3"; src = gh "honeycombio/honeyvent" "v1.1.3" "4efb7c383fb78d9062f4af07548253d58c943e0efebfdd58852a016eb20f599f";
    vendorHash = null; subPkgs = ".";
    check = chk ''"$out/bin/honeyvent" --help'' "[-]-no-tls-verify"; };
  # horcrux (MIT): split your file into encrypted fragments so that you don't need to remember a passcode.
  horcrux = pkg { pname = "horcrux"; version = "0.3-unstable-2023-09-19"; src = gh "jesseduffield/horcrux" "5e848abcca49a7ad359f5a24ef4ca7e0eda80889" "8e8951807067b9036a6f417847ba3f8cc2d36144afb43e8868a849b746ff79bb";
    vendorHash = null; subPkgs = ".";
    check = chk ''"$out/bin/horcrux" --help'' "[Uu]sage"; };
  # htmltest (MIT): tool to test generated HTML output.
  htmltest = pkg { pname = "htmltest"; version = "0.17.0"; src = gh "wjdp/htmltest" "v0.17.0" "2c89e56c837f4d715db9816942e007c973ba58de53d249abc80430c4b7e72f88";
    vendorHash = "sha256-XaFdpWSTdkuCw3WXA/pdf4XI2z4sv4extPFoujNC+gs="; subPkgs = "."; ldflags = "-w -s -X main.version=0.17.0";
    check = chk ''"$out/bin/htmltest" --version'' "0\\.17\\.0"; };
  # http-scanner (MIT): HTTP security vulnerability scanner that detects a wide range of web application vulnerabilities.
  http-scanner = pkg { pname = "http-scanner"; version = "1.0.1"; src = gh "aymaneallaoui/kafka-http-scanner" "refs/tags/1.0.1" "3650013181eb764fd45444b544db68f19da16c42ebe39505bc37a2dfe90c2446";
    vendorHash = "sha256-LDHNKqoYyzOzS5bu4h6d22BojRpjglXnsfAdpLugOSQ="; subPkgs = "."; ldflags = "-s -w -X=github.com/aymaneallaoui/kafka-http-scanner/pkg/utils.Version=1.0.1";
    check = chk ''"$out/bin/kafka-http-scanner" --help'' "[Uu]sage"; };
  # httprobe (MIT): take a list of domains and probe for working HTTP and HTTPS servers.
  httprobe = pkg { pname = "httprobe"; version = "0.2"; src = gh "tomnomnom/httprobe" "v0.2" "33a460c675487e1bf75d0761d850a98a8777715731b4de930d056abbeb4e4d2f";
    vendorHash = null; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/httprobe" --help'' "[-]prefer-https"; };
  # hydroxide (MIT): third-party, open-source ProtonMail bridge.
  hydroxide = pkg { pname = "hydroxide"; version = "0.2.32"; src = gh "emersion/hydroxide" "v0.2.32" "14e603ff7f96e86a8f71bd5d5e7970ed9afa61d90d07472168a8e2e4e1349198";
    vendorHash = "sha256-azrbVyM93n0X6BCBGWtWwPFafbRRAksjuweVLFvWxIA="; subPkgs = "./cmd/hydroxide";
    check = chk ''"$out/bin/hydroxide" --help'' "[-]api-endpoint"; };
  # iamy (MIT): cli tool for importing and exporting AWS IAM configuration to YAML files.
  iamy = pkg { pname = "iamy"; version = "2.4.0"; src = gh "99designs/iamy" "v2.4.0" "13bd9e66afbeb30d386aa132a4af5d2e9a231d2aadf54fe8e5dc325583379359";
    vendorHash = "sha256-CkoUgvpqjEBGG14OhfnPn5YUJ3LQLyE68yDnMkuKqlc="; subPkgs = "."; ldflags = "-X main.Version=v2.4.0 -s -w";
    check = chk ''"$out/bin/iamy" --version'' "2\\.4\\.0"; };
  # iferr (MIT): generate "if err != nil {" block.
  iferr = pkg { pname = "iferr"; version = "0-unstable-2024-01-22"; src = gh "koron/iferr" "9c3e2fbe4bd19a7f0338e42bb483562ed4cf4d50" "3e405ce41b7b110579620745840a95dc8578dbfbdb5c65098e50c7e2212c7e50";
    vendorHash = null; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/iferr" --help'' "[Uu]sage"; };
  # imgpkg (Apache-2.0): store application configuration files in Docker/OCI registries.
  imgpkg = pkg { pname = "imgpkg"; version = "0.48.3"; src = gh "carvel-dev/imgpkg" "v0.48.3" "c3a3150e81e5db07e3e1732e7f26a03167ab975bbae0d42526d7848404709033";
    vendorHash = null; subPkgs = "./cmd/imgpkg"; ldflags = "-X=carvel.dev/imgpkg/pkg/imgpkg/cmd.Version=0.48.3";
    check = chk ''"$out/bin/imgpkg" --version'' "0\\.48\\.3"; };
  # ineffassign (MIT): detect ineffectual assignments in Go code.
  ineffassign = pkg { pname = "ineffassign"; version = "0.2.0"; src = gh "gordonklaus/ineffassign" "refs/tags/v0.2.0" "5b0256a4151ec313ce65921f7434c70149aeb3056867a8e502bca4e7a06770a0";
    vendorHash = "sha256-HLwMMw5/untM3lId7RLQpoXk0bsiWBpSfu3zdkqkBWo="; subPkgs = ".";
    check = chk ''"$out/bin/ineffassign" --help'' "[-]check-escaping-errors"; };
  # influxdb2-token-manipulator (MIT): utility program to manipulate influxdb api tokens for declarative setups.
  influxdb2-token-manipulator = pkg { pname = "influxdb2-token-manipulator"; version = "1.0.0"; src = gh "oddlama/influxdb2-token-manipulator" "v1.0.0" "8cfeb703bebccb02648e0d71735b92e850aaddcd1d5c93cb81a48914cb0f32e3";
    vendorHash = "sha256-wfATrbk+ksWCkMqDRyZ+PXWbq9nUHj+DS3tm0kyIDU0="; subPkgs = ".";
    check = chk ''"$out/bin/influxdb2-token-manipulator" --help'' "[Uu]sage"; };
  # ingress2gateway (Apache-2.0): convert Ingress resources to Gateway API resources.
  ingress2gateway = pkg { pname = "ingress2gateway"; version = "0.5.0"; src = gh "kubernetes-sigs/ingress2gateway" "v0.5.0" "6afffb36873af934f1499d68ea73d432bb711a3025e8f3f5ab330162798ce871";
    vendorHash = "sha256-REERzvGPybZYSx3/qBrZ2kx4Jy66tMBitpqvB1kWZA0="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/ingress2gateway" --help'' "[Uu]sage"; };
  # invoice (MIT): command line invoice generator.
  invoice = pkg { pname = "invoice"; version = "0.1.0"; src = gh "maaslalani/invoice" "v0.1.0" "f34f20f6491f42c0e94dbde433a578f0dba98938f2e3186018d3e16d050abdaf";
    vendorHash = "sha256-C0PtDCSa18TswBsmL0TOPzW1ZYYxWHU4m4G1pTKVEh8="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/invoice" --help'' "[Uu]sage"; };
  # ipfs-upload-client (MIT): minimal CLI tool to upload files and directories to IPFS via Infura's IPFS or another API endpoint.
  ipfs-upload-client = pkg { pname = "ipfs-upload-client"; version = "0.1.2"; src = gh "infura/ipfs-upload-client" "v0.1.2" "7ef24e2e81998a000bad492f910f8ecb4e37dc6d31e6792067f0f30e132896b3";
    vendorHash = "sha256-ohXwisYClCdYNK2orTfcbWJzUGuZ8NjVAeQ/FjZg2Bc="; subPkgs = ".";
    check = chk ''"$out/bin/ipfs-upload-client" --help'' "[Uu]sage"; };
  # ipinfo (Apache-2.0): command Line Interface for the IPinfo API.
  ipinfo = pkg { pname = "ipinfo"; version = "3.3.2"; src = gh "ipinfo/cli" "refs/tags/ipinfo-3.3.2" "ad5464068ec370599bd7624cd69f58047ac56d8140ba8e50b468c80e06c438a1";
    vendorHash = null; subPkgs = "./cidr2ip ./cidr2range ./grepdomain ./grepip ./ipinfo ./matchip ./prips ./randip ./range2cidr ./range2ip ./splitcidr";
    check = chk ''"$out/bin/ipinfo" --version'' "3\\.3\\.2"; };
  # irccat (GPL-3.0-only): send events to IRC channels from scripts and other applications.
  irccat = pkg { pname = "irccat"; version = "0.4.13"; src = gh "irccloud/irccat" "v0.4.13" "0eaeb7ec6b8e8482ee11143cd3cf53fa08fbbfa3ea29904b6a6aa8843f73b04e";
    vendorHash = "sha256-pGsePUugwR5sI+497aD4gka5MRuUXg3DAu0boFrgnOI="; subPkgs = ".";
    check = chk ''"$out/bin/irccat" --help'' "[Uu]sage"; };
  # ircdog (ISC): simple wrapper over the raw IRC protocol that can respond to pings, and interprets formatting codes.
  ircdog = pkg { pname = "ircdog"; version = "0.5.5"; src = gh "ergochat/ircdog" "refs/tags/v0.5.5" "cc75fc53dfaeca27469b42db3596bc42a26259a6534c3edecf8d91bf6b52a4fe";
    vendorHash = null; subPkgs = ".";
    check = chk ''"$out/bin/ircdog" --version'' "0\\.5\\.5"; };
  # issue2md (Apache-2.0): CLI tool to convert GitHub issue into Markdown file.
  issue2md = pkg { pname = "issue2md"; version = "1.3.1"; src = gh "bigwhite/issue2md" "refs/tags/v1.3.1" "dc2e6178cf8aee52f3d9df190c3999523b64265cbc60e4ca7387aeefe006a6eb";
    vendorHash = null; subPkgs = ". ./cmd/issue2md"; ldflags = "-s";
    check = chk ''"$out/bin/issue2md" --help'' "[-]enable-user-links"; };
  # ivy (BSD-3-Clause): APL-like calculator.
  ivy = pkg { pname = "ivy"; version = "0.4.0"; src = gh "robpike/ivy" "v0.4.0" "d8a4d79aea6d99db7e3bf867c1f2b8df4e966abbd7623d1a8d5664ea4aa6ff8b";
    vendorHash = null; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/ivy" --help'' "[Uu]sage"; };
  # jp (Apache-2.0): command line interface to the JMESPath expression language for JSON.
  jp = pkg { pname = "jp"; version = "0.2.1"; src = gh "jmespath/jp" "0.2.1" "e88a49f61fffca8f431f78938f71e14d7792f7304344b7aa7391d06e4113f88b";
    vendorHash = "sha256-Kta19QcaA6mQafCIkDglvcAwimYw2L6sWsN4pKUdtKQ="; subPkgs = ".";
    check = chk ''"$out/bin/jp" --version'' "0\\.2\\.1"; };
  # jq-lsp (MIT): jq language server.
  jq-lsp = pkg { pname = "jq-lsp"; version = "0.1.19"; src = gh "wader/jq-lsp" "refs/tags/v0.1.19" "a209ea43c2ae6b0c1273a1cac8f6a8e1ac5f7e2d43c18160fda0690ea0656890";
    vendorHash = "sha256-bMx9fIpTEkapi0+Pxgv2/mdUgPm7mB1suJLRt/SN5y0="; subPkgs = "."; ldflags = "-s -w -X main.version=0.1.19 -X main.commit=refs/tags/v0.1.19 -X main.builtBy=Nix";
    check = chk ''"$out/bin/jq-lsp" --version'' "0\\.1\\.19"; };
  # jqfmt (MIT): like gofmt, but for jq.
  jqfmt = pkg { pname = "jqfmt"; version = "0.1.0"; src = gh "noperator/jqfmt" "refs/tags/v0.1.0" "5435c3166921ea103513d516c4d56ee00755d6b0b798f3edbdabfc06a1d98268";
    vendorHash = "sha256-q3X5hXrf4NKYQprs50Cvl6BYkHrehkf9RQCvS26VpSM="; subPkgs = "./cmd/jqfmt";
    check = chk ''"$out/bin/jqfmt" --help'' "[Uu]sage"; };
  # jqp (MIT): TUI playground to experiment with jq.
  jqp = pkg { pname = "jqp"; version = "0.8.0"; src = gh "noahgorstein/jqp" "v0.8.0" "c70e83975edb1c1dacb0fb067a0685e9632e21360805ade3dda03e54751e4855";
    vendorHash = "sha256-3FCsxalJIM2d0Ltj7QCgev0EHP9QFbFjKVu6BwTYfcE="; subPkgs = ".";
    check = chk ''"$out/bin/jqp" --version'' "0\\.8\\.0"; };
  # json2hcl (MIT): convert JSON to HCL, and vice versa.
  json2hcl = pkg { pname = "json2hcl"; version = "0.2.0"; src = gh "kvz/json2hcl" "v0.2.0" "ac10155d2d86a196a97e9cfb98e7a66f0b0505dee8904bbd3e32979370b81f34";
    vendorHash = "sha256-SHM+VctJyECXIQDwopyxLz3QMeMt6KpF3k9fDUAYTYw="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/json2hcl" --help'' "[Uu]sage"; };
  # jsonfmt (MIT): formatter for JSON files.
  jsonfmt = pkg { pname = "jsonfmt"; version = "0.5.2"; src = gh "caarlos0/jsonfmt" "refs/tags/v0.5.2" "07494aaec99d4c8cd7f0cea1bacd32e1d20321e541848aa6aafa64d64d89c9ab";
    vendorHash = "sha256-7GXwBFTntQoQfAMLsl8ZOrc5Ms3nMP0KQmS0/N11/eQ="; subPkgs = "."; ldflags = "-s -w -X=main.version=0.5.2";
    check = chk ''"$out/bin/jsonfmt" --version'' "0\\.5\\.2"; };
  # jsonnet-bundler (Apache-2.0): jsonnet package manager.
  jsonnet-bundler = pkg { pname = "jsonnet-bundler"; version = "0.6.0"; src = gh "jsonnet-bundler/jsonnet-bundler" "v0.6.0" "116ab7d6e6090d973998f69ace133c247ae36373fbffe5cb3dce668615b31dea";
    vendorHash = null; subPkgs = "./cmd/jb"; ldflags = "-s -w -X main.Version=0.6.0";
    check = chk ''"$out/bin/jb" --version'' "0\\.6\\.0"; };
  # jsonnet-language-server (AGPL-3.0-only): language Server Protocol server for Jsonnet.
  jsonnet-language-server = pkg { pname = "jsonnet-language-server"; version = "0.17.0"; src = gh "grafana/jsonnet-language-server" "refs/tags/v0.17.0" "7d51fbd633475f449772c95e410ffb498df5e4e2102c7ac49072a76f38a5b98b";
    vendorHash = "sha256-gZNWIoXuvI7EPp3i7bPwsmD50vflWrHmFDBZkpRyjlM="; subPkgs = "."; ldflags = "-s -w -X 'main.version=0.17.0'";
    check = chk ''"$out/bin/jsonnet-language-server" --version'' "0\\.17\\.0"; };
  # kail (MIT): kubernetes log viewer.
  kail = pkg { pname = "kail"; version = "0.17.4"; src = gh "boz/kail" "v0.17.4" "73ff6cbf4b1fd166ff4122f116112e08ade5639cddb70cd078539efeb96ff030";
    vendorHash = "sha256-Bn3gyhmmOHyFEhtehTuEo36RTBiAmLQvP3uuc2D9KH0="; subPkgs = "./cmd/kail"; ldflags = "-s -w -X main.version=0.17.4";
    check = chk ''"$out/bin/kail" version'' "0\\.17\\.4"; };
  # kanarenshu (MIT): minimal TUI application to practise Japanese from the terminal.
  kanarenshu = pkg { pname = "kanarenshu"; version = "0.1.4"; src = gh "nuixyz/kanarenshu" "refs/tags/v0.1.4" "f34cf25c08e4db141dbbe58fca6c68630d996cea5e2eebae4d9bcfbd99cb6bf0";
    vendorHash = "sha256-3/U/q+7Ij78O9pbZ56hqJi2xp/8x7qo80n2mlTFWzmY="; subPkgs = "./cmd/kanarenshu"; ldflags = "-s -w -X=main.version=0.1.4";
    check = chk ''"$out/bin/kanarenshu" --version'' "0\\.1\\.4"; };
  # kapowbang (Apache-2.0): expose command-line tools over HTTP.
  kapowbang = pkg { pname = "kapowbang"; version = "0.7.1"; src = gh "BBVA/kapow" "v0.7.1" "cba2b5891cb8146a9fe3e1fd5f91dba988d488b197fefaae486cacd902cd133b";
    vendorHash = "sha256-/eb8KmEIswjlvR0jD77Mgpc/y32hJ3D+udGhZN982R0="; subPkgs = ".";
    check = chk ''"$out/bin/kapow" --help'' "[Uu]sage"; };
  # kbld (Apache-2.0): seamlessly incorporates image building and image pushing into your development and deployment workflows.
  kbld = pkg { pname = "kbld"; version = "0.49.2"; src = gh "carvel-dev/kbld" "v0.49.2" "b6e5c4438d37dc0f034e58854948351f397000468b59deb50c00765f0ab1bd3f";
    vendorHash = null; subPkgs = "./cmd/kbld"; ldflags = "-X=carvel.dev/kbld/pkg/kbld/version.Version=0.49.2";
    check = chk ''"$out/bin/kbld" --version'' "0\\.49\\.2"; };
  # kbst (Apache-2.0): kubestack framework CLI.
  kbst = pkg { pname = "kbst"; version = "0.2.1"; src = gh "kbst/kbst" "refs/tags/v0.2.1" "a02615028a00f4ce1e0121f3c8822dc5245f79e4e34bb85de48cc6ba6b3d5047";
    vendorHash = "sha256-6HAbNWb4oMN9yUxmvWgvo6PkSRzOVVeRVd1PPqWurd4="; subPkgs = "."; ldflags = "-s -w -X github.com/kbst/kbst.version=0.2.1 -X github.com/kbst/kbst.buildDate=unknown -X github.com/kbst/kbst.gitCommit=refs/tags/v0.2.1 -X github.com/kbst/kbst.gitTag=v0.2.1 -X github.com/kbst/kbst.gitTreeState=clean";
    check = chk ''"$out/bin/kbst" --help'' "[Uu]sage"; };
  # ketch (MIT): fast, stateless CLI for web search and scrape. Built for AI agents.
  ketch = pkg { pname = "ketch"; version = "0.18.1"; src = gh "1broseidon/ketch" "refs/tags/v0.18.1" "dca4d1b126c66e2a8d85f0beb762d6334e6cd0fb10df7ddce0b57884716ad9ce";
    vendorHash = "sha256-ZfAMk0J55/eOg5D7ioZjIIx5diLKtwXpXdNmqpnoAU8="; subPkgs = ". ./cmd/readtest"; ldflags = "-s -w -X github.com/1broseidon/ketch/cmd.version=0.18.1";
    check = chk ''"$out/bin/ketch" --version'' "0\\.18\\.1"; };
  # kfilt (Apache-2.0): command-line tool that filters Kubernetes resources.
  kfilt = pkg { pname = "kfilt"; version = "1.0.0"; src = gh "ryane/kfilt" "v1.0.0" "eccc3e2c176109b2551f047f098d369a42986a9d9e9c4c99f61d79a3927b0c65";
    vendorHash = "sha256-3N9SlnsHPp+USPtx7i4bwgRixhJwDLPHsUwiHvRNkbA="; subPkgs = "."; ldflags = "-s -w -X github.com/ryane/kfilt/cmd.Version=1.0.0 -X github.com/ryane/kfilt/cmd.GitCommit=v1.0.0";
    check = chk ''"$out/bin/kfilt" --version'' "1\\.0\\.0"; };
  # kin-openapi (MIT): command line tool to validation openapi3 documents.
  kin-openapi = pkg { pname = "kin-openapi"; version = "0.152.0"; src = gh "getkin/kin-openapi" "refs/tags/v0.152.0" "f42d5d5ab8db4136b93895d3fceb46c85399e369c906433ff37401147294dc29";
    vendorHash = "sha256-G166SDGUXgyDeSO5LgsQpXspCyaceh2Gtmj63ibXByo="; subPkgs = "./cmd/validate";
    check = chk ''"$out/bin/validate" --help'' "[Uu]sage"; };
  # kiterunner (AGPL-3.0-only): contextual content discovery tool.
  kiterunner = pkg { pname = "kiterunner"; version = "1.0.2"; src = gh "assetnote/kiterunner" "v1.0.2" "d553ed6a063b1a65bc72060be137b89d7c48f4da6ebf4fe46057807a5aa3d069";
    vendorHash = "sha256-w6A9CjO+0tumCVo+Tn7Eukk8CYxFuKJEIQ1hAsgcl50="; subPkgs = "./cmd/kiterunner"; ldflags = "-s -w -X github.com/assetnote/kiterunner/cmd/kiterunner/cmd.Version=1.0.2";
    check = chk ''"$out/bin/kiterunner" version'' "1\\.0\\.2"; };
  # knit (MIT): simple and flexible build tool using Lua, similar to make/mk.
  knit = pkg { pname = "knit"; version = "1.1.1"; src = gh "zyedidia/knit" "v1.1.1" "f4a073568ef3b44d4cf80f4acff021368c5a2cc4f047ce7b4c6b5bfa57562e2b";
    vendorHash = "sha256-givrBowtckyooDec6oaO/DW2SFDg4ms2CmNERDvwnQ0="; subPkgs = "./cmd/knit"; ldflags = "-s -w -X github.com/zyedidia/knit/info.Version=1.1.1";
    check = chk ''"$out/bin/knit" --version'' "1\\.1\\.1"; };
  # konf (Apache-2.0): lightweight and blazing fast kubeconfig manager which allows to use different kubeconfigs at the same time.
  konf = pkg { pname = "konf"; version = "0.7.0"; src = gh "SimonTheLeg/konf-go" "v0.7.0" "bb924ff7ead75a34ac6956b58115826ffdb726b65f2635e740c1c3a73ca5d6a8";
    vendorHash = "sha256-AV+mJkJA9xf3EvjtZog5MYeBGm0Xr/DVGpXpyyzrlR8="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/konf-go" --help'' "[-]-konf-dir"; };
  # kt (MIT): kafka command line tool.
  kt = pkg { pname = "kt"; version = "13.1.0"; src = gh "fgeller/kt" "v13.1.0" "20cffe44f0f126ee42c634427cc3cdb6705e33dd4de3647a8c4a84ccec1d25f3";
    vendorHash = "sha256-/4RUvLwvEt2sc8lteh2zZNY80dVMzYLgNu9uoATgMoo="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/kt" --help'' "[Uu]sage"; };
  # ktunnel (GPL-3.0-only): cli that exposes your local resources to kubernetes.
  ktunnel = pkg { pname = "ktunnel"; version = "2.0.2"; src = gh "omrikiei/ktunnel" "v2.0.2" "ceeb56267807affea6abbbfda0906a46e956ffaa39faf2cf82937a310a5f6dcb";
    vendorHash = "sha256-TuYaKPJ4S7AZzaCkINt2U7ppAOH5t6AZpsoGcokssY8="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/ktunnel" --version'' "2\\.0\\.2"; };
  # kube-capacity (Apache-2.0): simple CLI that provides an overview of the resource requests, limits, and utilization in a Kubernetes cluster.
  kube-capacity = pkg { pname = "kube-capacity"; version = "0.8.0"; src = gh "robscott/kube-capacity" "v0.8.0" "71a1e515f88c1dbd8f02a652984f1a83b526bab86b5883bcc012a4dedc139bce";
    vendorHash = "sha256-GDZmEJJ5vAKcrMtmZZlRf4IFIWqZPiHTwW16N1/3SiI="; subPkgs = ".";
    check = chk ''"$out/bin/kube-capacity" --help'' "[-]-namespace-labels"; };
  # kube-review (Apache-2.0): create Kubernetes AdmissionReview requests from Kubernetes resource manifests.
  kube-review = pkg { pname = "kube-review"; version = "0.5.0"; src = gh "anderseknert/kube-review" "refs/tags/v0.5.0" "516f0cc0a371f4eeaa245ded832db537b2980c72977c310ab43c27a7483405a4";
    vendorHash = "sha256-NnKMo1a0iCk+y3iu2av0df8NI9Itx07HQKMZR2onKGk="; subPkgs = "."; ldflags = "-X github.com/anderseknert/kube-review/cmd.version=v0.5.0";
    check = chk ''"$out/bin/kube-review" version'' "0\\.5\\.0"; };
  # kubeconform (Apache-2.0): FAST Kubernetes manifests validator, with support for Custom Resources.
  kubeconform = pkg { pname = "kubeconform"; version = "0.8.0"; src = gh "yannh/kubeconform" "v0.8.0" "c345de9c3207f2d24628c64fe3cb9bed55c4248b12c181efe81ee907d6c994f2";
    vendorHash = null; subPkgs = "./cmd/kubeconform"; ldflags = "-s -w -X main.version=v0.8.0";
    check = chk ''"$out/bin/kubeconform" --help'' "[-]insecure-skip-tls-verify"; };
  # kubectl-df-pv (Apache-2.0): df-like utility for persistent volumes on Kubernetes.
  kubectl-df-pv = pkg { pname = "kubectl-df-pv"; version = "0.5.0"; src = gh "yashbhutwala/kubectl-df-pv" "v0.5.0" "91ca7e0631229fe0f9bb45f7e8868fc9ee9a03dee978989a73d3a4099bc82dbd";
    vendorHash = "sha256-xTsU8+6kgdkKvBFa1OStYzW+8CsOzQt33uUbaTFEtLg="; subPkgs = "./cmd/df-pv";
    check = chk ''"$out/bin/df-pv" --help'' "[-]-certificate-authority"; };
  # kubectl-evict-pod (Apache-2.0): this plugin evicts the given pod and is useful for testing pod disruption budget rules.
  kubectl-evict-pod = pkg { pname = "kubectl-evict-pod"; version = "0.0.15"; src = gh "rajatjindal/kubectl-evict-pod" "v0.0.15" "cc97ece1cfac60e08cee289effac163caaa63641e865543dcf79665a7e19e008";
    vendorHash = "sha256-vhk7Ja7jaKypl1Z7z9d2GWiXS06m1gUHCgSG6+B5/gk="; subPkgs = ".";
    check = chk ''"$out/bin/kubectl-evict-pod" --help'' "[-]-insecure-skip-tls-verify"; };
  # kubectl-example (Apache-2.0): kubectl plugin for retrieving resource example YAMLs.
  kubectl-example = pkg { pname = "kubectl-example"; version = "1.2.0"; src = gh "seredot/kubectl-example" "v1.2.0" "74b5b4bcb6ac89bbb28c6f96a900bed7a23532e2841b90e8437917a3a4819645";
    vendorHash = null; subPkgs = "./cmd/kubectl-example";
    check = chk ''"$out/bin/kubectl-example" --help'' "[Uu]sage"; };
  # kubectl-graph (Apache-2.0): kubectl plugin to visualize Kubernetes resources and relationships.
  kubectl-graph = pkg { pname = "kubectl-graph"; version = "0.7.0"; src = gh "steveteuber/kubectl-graph" "v0.7.0" "14c6051f87c4b82e991745009dd6a0ab8d4edb91d83c31df29cf24d426d057e6";
    vendorHash = "sha256-iKDVaQ0mzMfR9dKhhAq8mtK0gKsKCJ6Mk4Otk2aXzRk="; subPkgs = "./cmd/kubectl-graph";
    check = chk ''"$out/bin/kubectl-graph" --help'' "[-]-all-namespaces"; };
  # kubectl-tree (Apache-2.0): kubectl plugin to browse Kubernetes object hierarchies as a tree.
  kubectl-tree = pkg { pname = "kubectl-tree"; version = "0.6.0"; src = gh "ahmetb/kubectl-tree" "v0.6.0" "a2c62e887be6bd66c920edb26f9e8ad40d483d4d257e31641fbbef8f0ab1a6ce";
    vendorHash = "sha256-AAIXHn1pNuyiRQ4DTfn8JipTzwls6Z3HGQGmI6QIP48="; subPkgs = "./cmd/kubectl-tree";
    check = chk ''"$out/bin/kubectl-tree" --help'' "[-]-certificate-authority"; };
  # kubefetch (GPL-3.0-or-later): neofetch-like tool to show info about your Kubernetes Cluster.
  kubefetch = pkg { pname = "kubefetch"; version = "0.8.1"; src = gh "jkulzer/kubefetch" "0.8.1" "05d1fdb6a18f433186c924465dc7dd729ebbd48f89ff947c4b3c8697c97614ac";
    vendorHash = "sha256-phBkynLrMrQY76UIMwBIl3ModMSJElu+bTPbPuZ1dHw="; subPkgs = ".";
    check = chk ''"$out/bin/kubefetch" --version'' "0\\.8\\.1"; };
  # kubeprompt (EPL-2.0): kubernetes prompt.
  kubeprompt = pkg { pname = "kubeprompt"; version = "0.4.0"; src = gh "jlesquembre/kubeprompt" "0.4.0" "7518e032de7b617cf0b6fc7e099cce1f57b041f04732ec81e84083eea38e0abb";
    vendorHash = "sha256-kShJ/pBn1zq3RQARBW1tFSNnET53s3wwayQweCTCdzI="; subPkgs = "./cmd/kubeprompt"; ldflags = "-w -s -X github.com/jlesquembre/kubeprompt/pkg/version.Version=0.4.0";
    check = chk ''"$out/bin/kubeprompt" --version'' "0\\.4\\.0"; };
  # kubepug (Apache-2.0): checks a Kubernetes cluster for objects using deprecated API versions.
  kubepug = pkg { pname = "kubepug"; version = "1.7.1"; src = gh "kubepug/kubepug" "v1.7.1" "b134e5f67b6097fb4989d8789bfd06eaecb81528527c8372f935ae56cde63546";
    vendorHash = "sha256-06gmq9s3mv/4R93OK66KoLC0Okc9bYopY+d7ORXWijw="; subPkgs = ". ./generator"; ldflags = "-s -w -X sigs.k8s.io/release-utils/version.gitVersion=1.7.1";
    check = chk ''"$out/bin/kubepug" version'' "1\\.7\\.1"; };
  # kubetrim (MIT): trim your KUBECONFIG automatically.
  kubetrim = pkg { pname = "kubetrim"; version = "0.0.2"; src = gh "alexellis/kubetrim" "refs/tags/v0.0.2" "24455f11699c61760613f630ded0d395cdf5b2d3925a08a730878819f353e00f";
    vendorHash = "sha256-BwZI7cL9rJxUYUVzoCsCbisuRZVFZw/EAAFzPnsw/xk="; subPkgs = "."; ldflags = "-s -w -X github.com/alexellis/kubetrim/pkg.Version=0.0.2";
    check = chk ''"$out/bin/kubetrim" --version'' "0\\.0\\.2"; };
  # kustomize-lint (Apache-2.0): linter for Kustomize configuration files.
  kustomize-lint = pkg { pname = "kustomize-lint"; version = "1.0.0"; src = gh "groq/kustomize-lint" "refs/tags/v1.0.0" "63bf752fb8708439d9730c219f3c6d39ac35d489c2f966d44b91a977c2d0bc1a";
    vendorHash = "sha256-2rQFhc+CQQkWXYuPueU7c5roKusyzbfpLvwKriPVSus="; subPkgs = "./cmd/kustomize-lint"; ldflags = "-s";
    check = chk ''"$out/bin/kustomize-lint" --version'' "1\\.0\\.0"; };
  # ldapnomnom (MIT): tool to anonymously bruteforce usernames from Domain controllers.
  ldapnomnom = pkg { pname = "ldapnomnom"; version = "1.5.1"; src = gh "lkarlslund/ldapnomnom" "refs/tags/v1.5.1" "758828d4bd5c84eb6f5af207ff5fca50ce3b7aec81403eb1131b662b67440033";
    vendorHash = "sha256-QhcM2/U+8Rr1Wn0PVerVcBWqkRNxDZH/HKtpxvtQN4k="; subPkgs = "."; ldflags = "-w -s";
    check = chk ''"$out/bin/ldapnomnom" --help'' "[Uu]sage"; };
  # leetsolv (MIT): spaced repetition CLI for DSA and LeetCode.
  leetsolv = pkg { pname = "leetsolv"; version = "1.2.0"; src = gh "eannchen/leetsolv" "refs/tags/v1.2.0" "430303725aed7340f70d09e2461a82806e9f8ee195a98b8f0af6f0fc09236cd2";
    vendorHash = null; subPkgs = "."; ldflags = "-s -X main.Version=1.2.0 -X main.BuildTime=1970-01-01T00:00:00Z -X main.GitCommit=refs/tags/v1.2.0";
    check = chk ''"$out/bin/leetsolv" version'' "1\\.2\\.0"; };
  # levant (MPL-2.0): open source templating and deployment tool for HashiCorp Nomad jobs.
  levant = pkg { pname = "levant"; version = "0.4.0"; src = gh "hashicorp/levant" "v0.4.0" "8d299e890af5a3c6e9048f930b10cd34276656142358c298497ec5d7d8efa263";
    vendorHash = "sha256-KLWChZ9MeP0LnvBuPVHw6Jcz8vvNloI83whUA/xegCU="; subPkgs = ".";
    check = chk ''"$out/bin/levant" --version'' "0\\.4\\.0"; };
  # parlay (Apache-2.0): enriches SBOMs with data from third party services.
  parlay = pkg { pname = "parlay"; version = "0.11.0"; src = gh "snyk/parlay" "v0.11.0" "c1f9eaa073b6c958a0722b145fcea9fa3579c9b5552f3359d86f91917441253b";
    vendorHash = "sha256-mhL6EWMv1Eh4pM0VFKUtzLGmNQ6zYg3zPIm8uYawrSU="; subPkgs = ".";
    check = chk ''"$out/bin/parlay" --help'' "[Uu]sage"; };
  # passdetective (Apache-2.0): scans command history to detect mistakenly written passwords, API keys, and secrets.
  passdetective = pkg { pname = "passdetective"; version = "1.0.7"; src = gh "aydinnyunus/PassDetective" "1.0.7" "0ae261bcb86644f7dc1aae9fa8b054a20a355c354306b7e0519a1995005caba5";
    vendorHash = "sha256-yZqwi9T9iyP4OMHPPzOEuTUS1ZzM9oxADy9TSWkQAv0="; subPkgs = "."; ldflags = "-s -w -extldflags -static -X=main.build=1.0.7";
    check = chk ''"$out/bin/PassDetective" --help'' "[Uu]sage"; };
  # pbgopy (MIT): copy and paste between devices.
  pbgopy = pkg { pname = "pbgopy"; version = "0.4.0"; src = gh "nakabonne/pbgopy" "v0.4.0" "126ff35e5efbdb20df62594632c3a69190fc3e0f3bd04fa2da9366d6c322b76b";
    vendorHash = "sha256-ggB+NH8aRsaIaLQfIvqHlw/YuIixLkpFcsWFdX/BS94="; subPkgs = ".";
    check = chk ''"$out/bin/pbgopy" --help'' "[Uu]sage"; };
  # pg_flame (Apache-2.0): flamegraph generator for Postgres EXPLAIN ANALYZE output.
  pg_flame = pkg { pname = "pg_flame"; version = "1.2"; src = gh "mgartner/pg_flame" "v1.2" "913c25aa960b5542f94064ee15b77494e7d39adcddacdde31886f1891bb1a30a";
    vendorHash = "sha256-73mSob1wGDxM+SXUXLkQWZG8qnOsUwat3kXOXqCAaIk="; subPkgs = ".";
    check = chk ''"$out/bin/pg_flame" --help'' "[Uu]sage"; };
  # pget (MIT): fast, resumable file download client.
  pget = pkg { pname = "pget"; version = "0.2.1"; src = gh "Code-Hex/pget" "v0.2.1" "fa7646bec975dd3995fb45d6b1f190565d6c4fae03c46c4eda34716c83ede03e";
    vendorHash = "sha256-NOiTXBDpdTMNq9gjlUaxceEAa1JeNDbaA2cFo/l0oBM="; subPkgs = "./cmd/pget"; ldflags = "-w -s -X=main.version=0.2.1";
    check = chk ''"$out/bin/pget" --version'' "0\\.2\\.1"; };
  # pgo-client (Apache-2.0): CLI client for Crunchy PostgreSQL Kubernetes Operator.
  pgo-client = pkg { pname = "pgo-client"; version = "4.7.10"; src = gh "CrunchyData/postgres-operator" "v4.7.10" "2d738b176c1a658841c810f56b1de64be74042f049d1ed9f6e7dc98d477ed29c";
    vendorHash = "sha256-b6qpUDmR3ORbJztfy+JqcRxK4lJmGxWqG/5rR1xOBnM="; subPkgs = "./cmd/pgo";
    check = chk ''"$out/bin/pgo" --help'' "[Uu]sage"; };
  # picoleaf (MIT): A tiny CLI tool for controlling Nanoleaf.
  picoleaf = pkg { pname = "picoleaf"; version = "1.4.0"; src = gh "tessro/picoleaf" "refs/tags/v1.4.0" "bccb0958fbde632311610e65fa4f1a7d2053b955adff29c6ec4653acce6085a3";
    vendorHash = "sha256-ggPHSolXDEq2M8s25kZIGaJmcqQ2ZA0y6HnUMiMltAU="; subPkgs = ".";
    check = chk ''"$out/bin/picoleaf" --help'' "[Uu]sage"; };
  # pingme (MIT): send messages or alerts to multiple messaging platforms & email.
  pingme = pkg { pname = "pingme"; version = "0.2.7"; src = gh "kha7iq/pingme" "v0.2.7" "054750be7085c5dfcaae2cea17119b39041beef4577dfdfaf8011804c0836e9d";
    vendorHash = "sha256-0EdRYR+7sjqMvV+ZwoELIeMQVwDErydI4XUopCmQ6nw="; subPkgs = "."; ldflags = "-s -w -X=main.Version=0.2.7";
    check = chk ''"$out/bin/pingme" --version'' "0\\.2\\.7"; };
  # pipet (MIT): scraping and extracting data from online assets.
  pipet = pkg { pname = "pipet"; version = "0.3.0"; src = gh "bjesus/pipet" "0.3.0" "9fb35bcc4be8b7655a4075c3b2bf7b0368ae7bb97e9e6dbbcf00422c8e18cc6b";
    vendorHash = "sha256-IXu8Y9GPJlRzzCrEEbJaR0CTBAh5ix4aP52U6mFh9sQ="; subPkgs = "./cmd/pipet"; ldflags = "-s -w -X main.version=0.3.0 -X main.currentSha=0.3.0";
    check = chk ''"$out/bin/pipet" --version'' "0\\.3\\.0"; };
  # pj (MIT): fast project directory finder that searches filesystems for git repositories.
  pj = pkg { pname = "pj"; version = "1.14.0"; src = gh "josephschmitt/pj" "refs/tags/v1.14.0" "7c08277c6cae5c5193400c2fbe2f2b87a68c79502278e088285ec45abe2b1bd5";
    vendorHash = "sha256-ciVxwn97aMDKHNTpTYPF97Xc87EkXCusSQ6hRz/O9Jo="; subPkgs = "."; ldflags = "-s -X main.version=1.14.0";
    check = chk ''"$out/bin/pj" --version'' "1\\.14\\.0"; };
  # pkger (MIT): embed static files in Go binaries (replacement for gobuffalo/packr).
  pkger = pkg { pname = "pkger"; version = "0.17.1"; src = gh "markbates/pkger" "v0.17.1" "da775b5ec5675f0db75cf295ff07a4a034ba15eb5cc02d278a5767f387fb8273";
    vendorHash = "sha256-ySB8WsX3HNEjIGZRo4AXWPgZHWYVNZlhSfm+PttWOeQ="; subPkgs = "./cmd/pkger";
    check = chk ''"$out/bin/pkger" --help'' "[Uu]sage"; };
  # plan-exporter (MIT): query plan exporter for psql.
  plan-exporter = pkg { pname = "plan-exporter"; version = "0.0.6"; src = gh "agneum/plan-exporter" "refs/tags/v0.0.6" "f5b30610bd91ef39ed529ac25cf38a672f3808a832ef14c9dafaa0a7dc24bb7f";
    vendorHash = null; subPkgs = ".";
    check = chk ''"$out/bin/plan-exporter" --help'' "[-]auto-confirm"; };
  # play (Apache-2.0): TUI playground for programs like grep, sed and awk.
  play = pkg { pname = "play"; version = "0.4.0"; src = gh "paololazzari/play" "refs/tags/v0.4.0" "7abe1745099e9b4d66e5fc62a1180f2170e8351953d0c6978dfc4719591cd00e";
    vendorHash = "sha256-3/q5VXxfVU1OUmjy/5XVZB7w42MpByopHT4HfKiuZ2s="; subPkgs = ".";
    check = chk ''"$out/bin/play" version'' "0\\.4\\.0"; };
  # pluto (Apache-2.0): find deprecated Kubernetes apiVersions.
  pluto = pkg { pname = "pluto"; version = "5.24.3"; src = gh "FairwindsOps/pluto" "v5.24.3" "0768ca0d76ecafbda4c810ff52dcb3b2739d9472e3f251c6673626e8773dd1db";
    vendorHash = "sha256-TnEhJcrZ8B0iKElslVHxoclbJgcmYoQolNWT+s1c3O0="; subPkgs = "./cmd/pluto"; ldflags = "-w -s -X main.version=v5.24.3";
    check = chk ''"$out/bin/pluto" version'' "5\\.24\\.3"; };
  # powerline-go (GPL-3.0-or-later): powerline like prompt for Bash, ZSH and Fish.
  powerline-go = pkg { pname = "powerline-go"; version = "1.26"; src = gh "justjanne/powerline-go" "refs/tags/v1.26" "65aa911d50f3695b37da92a53ed417b6cf263a9e4091552b77921a6057dbb320";
    vendorHash = "sha256-B0CGHIsICVuE7qusQJD74VKkpxs62+fkMUEgnFyO5ts="; subPkgs = "."; ldflags = "-X github.com/justjanne/powerline-go/powerline.Version=1.26";
    check = chk ''"$out/bin/powerline-go" --version'' "1\\.26"; };
  # pphack (MIT): client-Side Prototype Pollution Scanner.
  pphack = pkg { pname = "pphack"; version = "0.1.6"; src = gh "edoardottt/pphack" "refs/tags/v0.1.6" "cc4da17a45873942a00eb5f499bb8c1c3c1124c084d9eee8d6133c1ba306630d";
    vendorHash = "sha256-8dvAuUxfnt9oMTyAMRTur+tNKEHJUH+5SQ38mwpC9LY="; subPkgs = "./cmd/pphack"; ldflags = "-s -w";
    check = chk ''"$out/bin/pphack" version'' "0\\.1\\.6"; };
  # pql (Apache-2.0): pipelined Query Language.
  pql = pkg { pname = "pql"; version = "0.2.0"; src = gh "runreveal/pql" "refs/tags/v0.2.0" "0414f0f9ada1bb04c4070a8b10374ffba472933213602d5ba574060cdd3b4615";
    vendorHash = "sha256-ih+JI5S1frOHqUWsIQA2ggv+m9QZEO+hznhGTljMR3I="; subPkgs = "./cmd/pql"; ldflags = "-s";
    check = chk ''"$out/bin/pql" --help'' "[Uu]sage"; };
  # prism (MIT): RTMP stream recaster/splitter.
  prism = pkg { pname = "prism"; version = "0.1.1"; src = gh "muesli/prism" "refs/tags/v0.1.1" "da0171dcaa0a544bb32d2ec0ab8a2dd15cc9d36e07c83cbfc4241db6f388e7a4";
    vendorHash = "sha256-4UVhr1zj2pbdxaE7mnV5Mggg8DmJZKF5xw0oIl4gnQY="; subPkgs = ".";
    check = chk ''"$out/bin/prism" --help'' "[Uu]sage"; };
  # prom2json (Apache-2.0): tool to scrape a Prometheus client and dump the result as JSON.
  prom2json = pkg { pname = "prom2json"; version = "1.5.0"; src = gh "prometheus/prom2json" "v1.5.0" "16dfed4e45ed1ee3e31d1c7166bebd803c0bfc4e110e02cad41f7ba7dde8e56f";
    vendorHash = "sha256-Lpp9MZzcIznGHmlODrBVlE//hAiNvWNAd+4b3DOPOAA="; subPkgs = "./cmd/prom2json";
    check = chk ''"$out/bin/prom2json" --help'' "[-]-help-long"; };
  # prometheus-qbittorrent-exporter (MIT): prometheus exporter for qBittorrent.
  prometheus-qbittorrent-exporter = pkg { pname = "prometheus-qbittorrent-exporter"; version = "2.0.2"; src = gh "martabal/qbittorrent-exporter" "refs/tags/v2.0.2" "5de4c5c681b72a70a303980b3e17995ac787b9d5aacd6d957e63f1f4f1f63293";
    vendorHash = "sha256-oyKL29cPoPF+/UlQtZR5vZXsTSNEF0o1VPfgDrdR7Fc="; subPkgs = "."; ldflags = "-s -X 'qbit-exp/app.version=v2.0.2'";
    check = chk ''"$out/bin/qbit-exp" --help'' "[Uu]sage"; };
  # protobuf-language-server (Apache-2.0): language server implementation for Google Protocol Buffers.
  protobuf-language-server = pkg { pname = "protobuf-language-server"; version = "0.1.8"; src = gh "lasorda/protobuf-language-server" "refs/tags/v0.1.8" "9e3e7f6beb51d59644de83e36d9b1c9717f4b1bda5e72d0af8a8516235b01be8";
    vendorHash = "sha256-cslcpNp966o26EHhaI8Od3e0jEY+L8QM8VN9EvEDonQ="; subPkgs = ". ./go-lsp/example";
    check = chk ''"$out/bin/protobuf-language-server" --help'' "[Uu]sage"; };
  # protoc-gen-connect-go (Apache-2.0): simple, reliable, interoperable, better gRPC.
  protoc-gen-connect-go = pkg { pname = "protoc-gen-connect-go"; version = "1.21.0"; src = gh "connectrpc/connect-go" "refs/tags/v1.21.0" "ef9d59c948c5f126292b165f42c23e4fbda4a02284fb2dff045cc51c59cfc122";
    vendorHash = "sha256-c5rZ56nLxbo+gu3srFORLTGOet5hm9HhHI3OYORfgm4="; subPkgs = "./cmd/protoc-gen-connect-go";
    check = chk ''"$out/bin/protoc-gen-connect-go" --version'' "1\\.21\\.0"; };
  # protoc-gen-doc (MIT): documentation generator plugin for Google Protocol Buffers.
  protoc-gen-doc = pkg { pname = "protoc-gen-doc"; version = "1.5.1"; src = gh "pseudomuto/protoc-gen-doc" "v1.5.1" "75667f5e4f9b4fecf5c38f85a046180745fc73f518d85422d9c71cb845cd3d43";
    vendorHash = "sha256-bfaaHvkblSQv6ZVXpYmZFoja5fd4gtNpmYSXkhbHcgo="; subPkgs = "./cmd/protoc-gen-doc";
    check = chk ''"$out/bin/protoc-gen-doc" --version'' "1\\.5\\.1"; };
  # protolint (MIT): pluggable linter and fixer to enforce Protocol Buffer style and conventions.
  protolint = pkg { pname = "protolint"; version = "0.58.0"; src = gh "yoheimuta/protolint" "v0.58.0" "7d5f4650ed23f68c34a6be1ba77fb3661dd4b7b28b64664a479b6835febceb18";
    vendorHash = "sha256-CqsuV72yRhnN2Ai6C2YNZMkxYrV6O5pV/toaQZwMeVs="; subPkgs = "./cmd/pl ./cmd/protoc-gen-protolint ./cmd/protolint"; ldflags = "-X github.com/yoheimuta/protolint/internal/cmd.version=0.58.0 -X github.com/yoheimuta/protolint/internal/cmd.revision=v0.58.0 -X github.com/yoheimuta/protolint/internal/cmd/protocgenprotolint.version=0.58.0 -X github.com/yoheimuta/protolint/internal/cmd/protocgenprotolint.revision=v0.58.0";
    check = chk ''"$out/bin/protolint" --version'' "0\\.58\\.0"; };
  # protoscope (Apache-2.0): simple, human-editable language for representing and emitting the Protobuf wire format.
  protoscope = pkg { pname = "protoscope"; version = "0-unstable-2022-11-09"; src = gh "protocolbuffers/protoscope" "8e7a6aafa2c9958527b1e0747e66e1bfff045819" "5336bb1de8c703421e7f12c9c4e0bf8bc79f472d12448ca8d4e0a1c4fd769ba6";
    vendorHash = "sha256-v7KGkYGgotQdejBZQJDCR1dppvCToQs96t6knCCysqY="; subPkgs = "./cmd/protoscope"; ldflags = "-s -w";
    check = chk ''"$out/bin/protoscope" --help'' "[-]explicit-length-prefixes"; };
  # puffin (MIT): beautiful terminal dashboard for hledger.
  puffin = pkg { pname = "puffin"; version = "2.1.5"; src = gh "siddhantac/puffin" "v2.1.5" "cfcb3306d55b81725808f83b973f08823d3ec74cf56ca42b309da8d661641c26";
    vendorHash = "sha256-K4afyHMCLD+ezHeUXn8bynjV6floUIJX3EYMd4sDzJ8="; subPkgs = ".";
    check = chk ''"$out/bin/puffin" --help'' "[Uu]sage"; };
  # pup (MIT): parsing HTML at the command line.
  pup = pkg { pname = "pup"; version = "0.4.0-unstable-2022-03-06"; src = gh "ericchiang/pup" "5a57cf111366c7c08999a34b2afd7ba36d58a96d" "4a9192d802f006deb8506ca38e0d65d440e73e21dcad81e6e1e144d1e0c8ef9b";
    vendorHash = "sha256-b/90J2o3h2og5c6TfV62ZyqNWq+ZGXKQabMCY6PFHjw="; subPkgs = ".";
    check = chk ''"$out/bin/pup" --help'' "[Uu]sage"; };
  # pwdsafety (GPL-3.0-or-later): command line tool checking password safety.
  pwdsafety = pkg { pname = "pwdsafety"; version = "0.4.2"; src = gh "edoardottt/pwdsafety" "refs/tags/v0.4.2" "6676f7ccc1ad32e8c68b889426b563d69080a69c1f9212b32d79fccc2e70b79f";
    vendorHash = "sha256-huhnMyNkYzSuarE3o125owEim4elaQVO+XPvKSy3qzk="; subPkgs = "./cmd/pwdsafety"; ldflags = "-w -s";
    check = chk ''"$out/bin/pwdsafety" --version'' "0\\.4\\.2"; };
  # px0 (MIT): fast, ultra-light, remote-first IDE for code navigation and review in your browser.
  px0 = pkg { pname = "px0"; version = "0.1.4"; src = gh "px0-ai/px0" "refs/tags/v0.1.4" "a1f5db2c6ed9ef5370bc1e9f88f5401fa19e8e08e14dcb2c9e70c3ec3feefd57";
    vendorHash = "sha256-5CuwxwEsAoFFBv4KTqYZWmtgeK23bMyAIOc3G91DrvI="; subPkgs = ".";
    check = chk ''"$out/bin/px0" --version'' "0\\.1\\.4"; };
  # q (GPL-3.0-only): tiny and feature-rich command line DNS client with support for UDP, TCP, DoT, DoH, DoQ, and ODoH.
  q = pkg { pname = "q"; version = "0.19.12"; src = gh "natesales/q" "refs/tags/v0.19.12" "1f56ebfb93fd380dee734cca9227149de2491c49db7b2c0f21019fd463081e4c";
    vendorHash = "sha256-lUeb7pReohN0mz4G6Sf6myby6qziMh/9OTVT+zI91GE="; subPkgs = "."; ldflags = "-s -w -X main.version=0.19.12";
    check = chk ''"$out/bin/q" --version'' "0\\.19\\.12"; };
  # qbec (Apache-2.0): configure kubernetes objects on multiple clusters using jsonnet https://qbec.io.
  qbec = pkg { pname = "qbec"; version = "0.31.0"; src = gh "splunk/qbec" "v0.31.0" "28f5a7adfc5f5a409613bb2ec10aaf6bb78e49d83403ec8393b3c55d60d0cb46";
    vendorHash = "sha256-OZj/9LZ9Kxlx6e+fyQ7upv07yGNVnDi5ICoAfbizOU0="; subPkgs = ". ./cmd/changelog-extractor ./cmd/gen-qbec-swagger ./cmd/jsonnet-qbec ./cmdtest/qbec-replay-exec"; ldflags = "-s -w -X github.com/splunk/qbec/internal/commands.version=0.31.0 -X github.com/splunk/qbec/internal/commands.commit=v0.31.0 -X github.com/splunk/qbec/internal/commands.goVersion=1.27.3";
    check = chk ''"$out/bin/qbec" version'' "0\\.31\\.0"; };
  # qsreplace (MIT): accept URLs on stdin, replace all query string values with a user-supplied value.
  qsreplace = pkg { pname = "qsreplace"; version = "0.0.3"; src = gh "tomnomnom/qsreplace" "v0.0.3" "42aa588fa25ec1e0c6af7f750bb0e25987702a1dce180c42f86caa8aea1aea38";
    vendorHash = null; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/qsreplace" --help'' "[-]ignore-path"; };
  # r53-ddns (MIT): DIY DynDNS tool based on Route53.
  r53-ddns = pkg { pname = "r53-ddns"; version = "1.3.0"; src = gh "fleaz/r53-ddns" "v1.3.0" "f5ce8789f7ac7671d3300d70d574a8a6d13225c06f166ecf7e9f02b9214201ec";
    vendorHash = "sha256-Zp7fSMQObCJuY1rPW+fbJjJqs+BcE8ns2+LAQZOJwZA="; subPkgs = ".";
    check = chk ''"$out/bin/r53-ddns" --help'' "[-]zone-id"; };
  # rabtap (GPL-3.0-only): rabbitMQ wire tap and swiss army knife.
  rabtap = pkg { pname = "rabtap"; version = "1.45.0"; src = gh "jandelgado/rabtap" "v1.45.0" "cc9d00ea13136fb9e1ca7fc2cba6b7d6024906d3fedb405215eedd4fca677194";
    vendorHash = "sha256-BdK7BUc1IVrVgs9sucv0EtApfmLCpTP/6lZ3SuxqLFg="; subPkgs = "./cmd/rabtap ./cmd/testgen"; ldflags = "-X main.BuildVersion=v1.45.0";
    check = chk ''"$out/bin/rabtap" --version'' "1\\.45\\.0"; };
  # rakkess (Apache-2.0): review Access - kubectl plugin to show an access matrix for k8s server resources.
  rakkess = pkg { pname = "rakkess"; version = "0.5.1"; src = gh "corneliusweig/rakkess" "v0.5.1" "16b76999b407da4dd5a9b8d9b9d8fa048078504e1a393e633b6854b31a74dc9f";
    vendorHash = "sha256-ahDwUoq+YEkEbG8UrFn1tix2E/U9AJ6ixlZZNhC/I6Q="; subPkgs = "."; ldflags = "-s -w -X github.com/corneliusweig/rakkess/internal/version.version=v0.5.1";
    check = chk ''"$out/bin/rakkess" version'' "0\\.5\\.1"; };
  # rcon-cli (Apache-2.0): little RCON cli based on james4k's RCON library for golang.
  rcon-cli = pkg { pname = "rcon-cli"; version = "1.7.7"; src = gh "itzg/rcon-cli" "refs/tags/1.7.7" "e19d0acd3427fbbb8942bc63a6aca1d2c407791fe041b9e8d7923ec85b64958a";
    vendorHash = "sha256-zcnk7Ry+oixGMt3AMlVl7/nHlpJv64MTlHCICZ2IkVw="; subPkgs = ".";
    check = chk ''"$out/bin/rcon-cli" --help'' "[Uu]sage"; };
  # rdap (MIT): command line client for the Registration Data Access Protocol (RDAP).
  rdap = pkg { pname = "rdap"; version = "0.10.0"; src = gh "openrdap/rdap" "refs/tags/v0.10.0" "19a6b1fe6c3335fa8bb48fb4c33ce56082e0ffdd24dd649745793613ab6c85cb";
    vendorHash = "sha256-AunR6Jxvob95AlDwaSsIRXocXyiC8S5/kKgt1oQA2Yk="; subPkgs = "./cmd/rdap"; ldflags = "-s -X=github.com/openrdap/rdap.version=0.10.0";
    check = chk ''"$out/bin/rdap" --version'' "0\\.10\\.0"; };
  # reddit-tui (MIT): terminal UI for reddit.
  reddit-tui = pkg { pname = "reddit-tui"; version = "0.3.9"; src = gh "tonymajestro/reddit-tui" "refs/tags/v0.3.9" "4f5dad492b776e67f9ed94fdc7bbcccabaa921ffdba7eb184619a830d05b5a33";
    vendorHash = "sha256-6f0d/iXQtyL/YvWXI58YoHEzuXP3cJumO61IxE0/7+I="; subPkgs = ".";
    check = chk ''"$out/bin/reddittui" --help'' "[Uu]sage"; };
  # redis-dump-go (MIT): dump Redis keys to a file in RESP format using multiple connections.
  redis-dump-go = pkg { pname = "redis-dump-go"; version = "0.8.2"; src = gh "yannh/redis-dump-go" "refs/tags/v0.8.2" "104821a5521c22a222433729a42e73a672d9c36e775c0daa84fc35d4cac508fe";
    vendorHash = null; subPkgs = ". ./utils/generator";
    check = chk ''"$out/bin/redis-dump-go" --help'' "[Uu]sage"; };
  # redli (Apache-2.0): humane alternative to the Redis-cli and TLS.
  redli = pkg { pname = "redli"; version = "0.18.0"; src = gh "IBM-Cloud/redli" "refs/tags/v0.18.0" "a75de85b90466a088e39885b67c38cb3e7ceeee6f1ec82df3d1d88aee5a17a20";
    vendorHash = "sha256-9GxXySVw5bL2aZw+uacBhKsTRTfCRvio8Lj82j9/pQE="; subPkgs = ".";
    check = chk ''"$out/bin/redli" --version'' "0\\.18\\.0"; };
  # reflex (MIT): small tool to watch a directory and rerun a command when certain files change.
  reflex = pkg { pname = "reflex"; version = "0.3.2"; src = gh "cespare/reflex" "v0.3.2" "62603db35a51fddf8a3ae9b1f4d9a8372ebec2a4523be16e3261bc8f9cfba3e5";
    vendorHash = "sha256-ksRXfcNHWg096xB6Fng72h4nQojIMooh7SKUJm3rgxY="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/reflex" --help'' "[-]-inverse-regex"; };
  # refmt (AGPL-3.0-only): reformat HCL <-> JSON <-> YAML.
  refmt = pkg { pname = "refmt"; version = "1.6.1"; src = gh "rjeczalik/refmt" "v1.6.1" "2a5950b7a1f624882ebd151d253b1406fe7d60b7646a59b4841361ebe52762be";
    vendorHash = "sha256-MfULOHGJXIygggKuZ2o15MHWlS+kbslhp9sPxuMtpGM="; subPkgs = ".";
    check = chk ''"$out/bin/refmt" --help'' "[Uu]sage"; };
  # reftools (BSD-2-Clause): refactoring tools for Go.
  reftools = pkg { pname = "reftools"; version = "0-unstable-2021-02-13"; src = gh "davidrjenni/reftools" "40322ffdc2e46fd7920d1f8250051bbd2f3bd34d" "f49f71a2d1be3c2e476162475a43fa6dbe5cac00ccdda7ed8dffc26190edfadb";
    vendorHash = null; subPkgs = "./cmd/fillstruct ./cmd/fillswitch ./cmd/fixplurals";
    check = chk ''"$out/bin/fillstruct" --help'' "[Uu]sage"; };
  # regal (Apache-2.0): linter and language server for Rego.
  regal = pkg { pname = "regal"; version = "0.43.0"; src = gh "open-policy-agent/regal" "refs/tags/v0.43.0" "0b1d03ef26a0d4282facaba811362d2784c7bc0aed0a5b4df270b413cc0dc6be";
    vendorHash = "sha256-qGL1RF39SbRA6k54xsKdWvTvaAeCCRllcveMP5flYls="; subPkgs = "."; ldflags = "-s -w -X github.com/open-policy-agent/regal/pkg/version.Version=0.43.0 -X github.com/open-policy-agent/regal/pkg/version.Commit=0.43.0";
    check = chk ''"$out/bin/regal" version'' "0\\.43\\.0"; };
  # regolith (MIT): add-on Compiler for the Bedrock Edition of Minecraft.
  regolith = pkg { pname = "regolith"; version = "1.8.0"; src = gh "Bedrock-OSS/regolith" "refs/tags/1.8.0" "e5eda4c9f6179987ed1a233780d7506c19a193506bb13817fdecec846d6200d0";
    vendorHash = "sha256-RZrgEhq+7zK6Z2Vib9ZrsoQRTc4r8y5qdH166QzOOlQ="; subPkgs = "."; ldflags = "-X main.buildSource=nix -X main.version=1.8.0";
    check = chk ''"$out/bin/regolith" --version'' "1\\.8\\.0"; };
  # resgate (MIT): realtime API Gateway used with NATS to build REST, real time, and RPC APIs.
  resgate = pkg { pname = "resgate"; version = "1.8.0"; src = gh "resgateio/resgate" "v1.8.0" "22900781b4943173d77ea4e9ded588fd39d74baf7aeb1941eea13977ea5cc2b7";
    vendorHash = "sha256-7Mo/D3eUtmlfNxB+IQykX6MxNFNAxe0vnPtJCGmkMvA="; subPkgs = ".";
    check = chk ''"$out/bin/resgate" --version'' "1\\.8\\.0"; };
  # reviewdog (MIT): automated code review tool integrated with any code analysis tools regardless of programming language.
  reviewdog = pkg { pname = "reviewdog"; version = "0.21.2"; src = gh "reviewdog/reviewdog" "v0.21.2" "a575127f03b85506f17d55ab1d66ea40df7d5b7d7530fbe2c725263c32ccb0c3";
    vendorHash = "sha256-PtpHxk9mOdiTpnEx6QSDfLGiBz+OjkegLTEQTuBWisU="; subPkgs = "./cmd/reviewdog"; ldflags = "-s -w -X github.com/reviewdog/reviewdog/commands.Version=0.21.2";
    check = chk ''"$out/bin/reviewdog" --version'' "0\\.21\\.2"; };
  # rime-cli (Apache-2.0): command line tool to add customized vocabulary for Rime IME.
  rime-cli = pkg { pname = "rime-cli"; version = "0.0.3"; src = gh "puddinging/rime-cli" "v0.0.3" "75b866f251ff098d360b070d9dd93faa20cc5e1ad17f254a47e06197b74a9d30";
    vendorHash = null; subPkgs = ".";
    check = chk ''"$out/bin/rime-cli" --help'' "[Uu]sage"; };
  # rkmon (MIT): real-time hardware monitor TUI for Rockchip RK3588 SBCs. Like htop, but for the GPU, NPU, VPU, RGA, and thermal zones of your Rock 5B+ / RK3588 board.
  rkmon = pkg { pname = "rkmon"; version = "0.3.1"; src = gh "isac322/rkmon" "refs/tags/v0.3.1" "5437f3012ac38ef3807d4363999b293b01b74a79d93ae9264a59ee30af359bd1";
    vendorHash = "sha256-MZ93tPwlFHTlAywu9aFjXIh/XQcPyVp3pxQxjIUhy8k="; subPkgs = "./cmd/rkmon"; ldflags = "-s -w -extldflags -static -X=main.Version=0.3.1 -X=main.GitSHA=refs/tags/v0.3.1";
    check = chk ''"$out/bin/rkmon" --version'' "0\\.3\\.1"; };
  # round (MIT): CLI tool for rounding images.
  round = pkg { pname = "round"; version = "0.0.2"; src = gh "mingrammer/round" "v0.0.2" "95aa622d62a4842a664a5dd67ed9e4a8eb930e6cbd70b06c2903aa07a3cc412f";
    vendorHash = null; subPkgs = ".";
    check = chk ''"$out/bin/round" --help'' "[Uu]sage"; };
  # routedns (BSD-3-Clause): DNS stub resolver, proxy and router.
  routedns = pkg { pname = "routedns"; version = "0.1.237"; src = gh "folbricht/routedns" "v0.1.237" "40b5f13e3924db514e9fac24c50ac36bce104ebfb4add6a9be1511e0f0b934ac";
    vendorHash = "sha256-Qo0RhT4SuInhdsqx3wA2CITHkoCsvHoBPmTZ/j8nYy8="; subPkgs = "./cmd/routedns"; ldflags = "-s -w";
    check = chk ''"$out/bin/routedns" --version'' "0\\.1\\.237"; };
  # run (MIT): easily manage and invoke small scripts and wrappers.
  run = pkg { pname = "run"; version = "0.11.2"; src = gh "TekWizely/run" "v0.11.2" "942427701caa99a9a3a6458a121b5c80b424752ea8701b26083841de5ae43ff6";
    vendorHash = "sha256-MN3QkE0Vm/7E14uZ0VCS1LuodupCVQA65GVXhpWzy9o="; subPkgs = ".";
    check = chk ''"$out/bin/run" version'' "0\\.11\\.2"; };
  # runitor (0BSD): command runner with healthchecks.io integration.
  runitor = pkg { pname = "runitor"; version = "1.4.1"; src = gh "bdd/runitor" "refs/tags/v1.4.1" "192665c623bc96ed77f122510510c017197e1673ab92bb84546d652afe4416c0";
    vendorHash = "sha256-dwQ5V7ZWrgsxX+WLDnv9j37KViM1Z8+f5dNBAanWwrA="; subPkgs = "./cmd/runitor"; ldflags = "-s -X main.Version=v1.4.1";
    check = chk ''"$out/bin/runitor" --version'' "1\\.4\\.1"; };
  # rush-parallel (MIT): cross-platform command-line tool for executing jobs in parallel.
  rush-parallel = pkg { pname = "rush-parallel"; version = "0.9.0"; src = gh "shenwei356/rush" "v0.9.0" "43ccc98c3c53b3995ee98fb1195ae3cdb7615c7fb8e4b2a6410c100733c764dc";
    vendorHash = "sha256-S2MjBw8KmDcilY9D5jGg4PkcmPNsl8SZwvlU6XRhSbI="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/rush" --version'' "0\\.9\\.0"; };
  # s3scanner (MIT): scan for misconfigured S3 buckets across S3-compatible APIs.
  s3scanner = pkg { pname = "s3scanner"; version = "3.1.1"; src = gh "sa7mon/s3scanner" "v3.1.1" "2d333c31909baa21e024d11db1b03647fff3d210d73fa7fa47f598d3d459a20c";
    vendorHash = "sha256-FPr5+CugtA6dZVNPqdqWzibNZdttb4JWJl9dTccw80s="; subPkgs = ". ./cmd/mqingest ./cmd/regioncheck"; ldflags = "-s -w";
    check = chk ''"$out/bin/s3scanner" --help'' "[-]bucket-file"; };
  # sbb-tui (MIT): TUI client for Switzerland's public transport timetables, inspired by SBB/CFF/FFS app.
  sbb-tui = pkg { pname = "sbb-tui"; version = "1.15.0"; src = gh "Necrom4/sbb-tui" "refs/tags/v1.15.0" "8e4e84f6358c6798e4b69ebb4c079d0c886bc189b839eb818dc31eec0c53b15b";
    vendorHash = "sha256-dk3x9arqoLq9y7ye/fxnUy+znqu8Xm+ErDx1cAvGbyY="; subPkgs = "."; ldflags = "-s -w -X main.version=1.15.0";
    check = chk ''"$out/bin/sbb-tui" --version'' "1\\.15\\.0"; };
  # sbomit (Apache-2.0): tool to generate SBOMs.
  sbomit = pkg { pname = "sbomit"; version = "0.2.1"; src = gh "SBOMit/sbomit" "refs/tags/v0.2.1" "24e276e0ab57bc297e5f6022bab9b55e6540ca936aa4410dc31dae5af25d93f8";
    vendorHash = "sha256-z44IXcS1oHq0keG98VDyeQWhRzRFjNfMzI5s/C5MV9M="; subPkgs = "."; ldflags = "-s";
    check = chk ''"$out/bin/sbomit" --help'' "[Uu]sage"; };
  # scilla (GPL-3.0-or-later): information gathering tool for DNS, ports and more.
  scilla = pkg { pname = "scilla"; version = "1.3.4"; src = gh "edoardottt/scilla" "refs/tags/v1.3.4" "f1a738745a2b45aa1dd37e1754a186bc08fb186f01e241257c7ae5a176eb7d44";
    vendorHash = "sha256-n3+FWntPQNwL5WytdRyOe3kGrFLMvDXqt7TehpkMqnc="; subPkgs = "./cmd/scilla"; ldflags = "-w -s";
    check = chk ''"$out/bin/scilla" --version'' "1\\.3\\.4"; };
  # scout (Unlicense): lightweight URL fuzzer and spider: Discover a web server's undisclosed files, directories and VHOSTs.
  scout = pkg { pname = "scout"; version = "0.15.1"; src = gh "liamg/scout" "v0.15.1" "3e28f860754e8bf3cdf1733e64a622349eee01f1453a11f9505b9ea31a5d7e16";
    vendorHash = "sha256-LLjc8xgQfkyi8LkxJdZVQzAAxuZwczKjNXaPEpQveS4="; subPkgs = "./cmd/scout";
    check = chk ''"$out/bin/scout" --help'' "[-]-skip-ssl-verify"; };
  # sd-local (BSD-3-Clause): screwdriver.cd local mode.
  sd-local = pkg { pname = "sd-local"; version = "1.0.59"; src = gh "screwdriver-cd/sd-local" "v1.0.59" "b51d61588893800e716abade6aaaf79efc8c1845a743a245a2c60018723ba525";
    vendorHash = "sha256-lc3mtAtoACHUs1J6+eSnB9J/Q9i3cj0stPGWkgksTdI="; subPkgs = ".";
    check = chk ''"$out/bin/sd-local" --help'' "[Uu]sage"; };
  # sdlookup (MIT): IP lookups for open ports and vulnerabilities from internetdb.shodan.io.
  sdlookup = pkg { pname = "sdlookup"; version = "0-unstable-2022-03-10"; src = gh "j3ssie/sdlookup" "8554bfa27284c4764401dbd8da23800d4ae968a2" "c4c0e3c9206766e2c5748fe18f1cb095d0551042409601484532a0fed0cb83b6";
    vendorHash = "sha256-Z0p4l2U6pEeaMHt4qfLMrikL+bPLZo7R9xgcDE/25mE="; subPkgs = ".";
    check = chk ''"$out/bin/sdlookup" --help'' "[Uu]sage"; };
  # secrethound (MIT): CLI tool designed to find secrets in JavaScript files, web pages, and other text sources.
  secrethound = pkg { pname = "secrethound"; version = "1.3.0"; src = gh "rafabd1/SecretHound" "refs/tags/v1.3.0" "e998f0744ec81380baead0606e195a5ff5cb54bfa64ec5824ced89dce8d76f96";
    vendorHash = "sha256-u7a+UFQjNcqcL+POS2/m75OFHQLVVfIpayAENH2ZI+Y="; subPkgs = "./cmd/secrethound"; ldflags = "-s -w";
    check = chk ''"$out/bin/secrethound" version'' "1\\.3\\.0"; };
  # senv (MIT): friends don't let friends leak secrets on their terminal window.
  senv = pkg { pname = "senv"; version = "0.7.0"; src = gh "SpectralOps/senv" "v0.7.0" "9bf87f6865ba20a00dcb0c8203b742e9979786e653e96ec90e2bea257bdba187";
    vendorHash = "sha256-jxW2RsSIHsl8n/hZw6fI+7JvpTAgsmbuFMPTymLYxoo="; subPkgs = ".";
    check = chk ''"$out/bin/senv" --help'' "[Uu]sage"; };
  # seqkit (MIT): cross-platform and ultrafast toolkit for FASTA/Q file manipulation.
  seqkit = pkg { pname = "seqkit"; version = "2.14.0"; src = gh "shenwei356/seqkit" "v2.14.0" "7df95904ce438c1a1a7b1fc06f20479a169e69209ac59abae8e80c60a1e65d60";
    vendorHash = "sha256-g+joEbyKloo9JLXgK6KjbZbN7J5EdLeIk5UvfTlklXY="; subPkgs = "./benchmark ./seqkit";
    check = chk ''"$out/bin/seqkit" version'' "2\\.14\\.0"; };
  # sequin (MIT): human-readable ANSI sequences.
  sequin = pkg { pname = "sequin"; version = "0.3.1"; src = gh "charmbracelet/sequin" "refs/tags/v0.3.1" "52f4d704a6e019df05dfc0ee3808fdf6c7d3245dcaa6262db8ca33c9de303da9";
    vendorHash = "sha256-htZnRYDHbBwRNCfTb+IDY6D1tne25dslPjk+44VQTrA="; subPkgs = "."; ldflags = "-X main.Version=0.3.1";
    check = chk ''"$out/bin/sequin" --version'' "0\\.3\\.1"; };
  # sessionprobe (MIT): tool for evaluating user privileges in web applications.
  sessionprobe = pkg { pname = "sessionprobe"; version = "1.0.0"; src = gh "dub-flow/sessionprobe" "refs/tags/v1.0.0" "8385b6784b1f32feb00a777ef6a1d8493eff2f200e277462e6e0043f56439f33";
    vendorHash = "sha256-rcxY2DzoKctSDYo4bwUZ55llzEfQZYHsI+UTMiAtjhc="; subPkgs = "."; ldflags = "-s -X=main.AppVersion=1.0.0";
    check = chk ''"$out/bin/sessionprobe" version'' "1\\.0\\.0"; };
  # sftpgo-plugin-auth (AGPL-3.0-only): LDAP/Active Directory authentication for SFTPGo.
  sftpgo-plugin-auth = pkg { pname = "sftpgo-plugin-auth"; version = "1.0.17"; src = gh "sftpgo/sftpgo-plugin-auth" "refs/tags/v1.0.17" "8575a5c06dfdb08aa666d64c59afbeb47ae46c07ae1282c1377ffdf8441de238";
    vendorHash = "sha256-hWsZInzH9Ic7XmSXW7zlg+KLkEynmQ+cT2QL1Bud+1Q="; subPkgs = "."; ldflags = "-s -X github.com/sftpgo/sftpgo-plugin-auth/cmd.commitHash=refs/tags/v1.0.17";
    check = chk ''"$out/bin/sftpgo-plugin-auth" --version'' "1\\.0\\.17"; };
  # shadowsocks-v2ray-plugin (MIT): yet another SIP003 plugin for shadowsocks, based on v2ray.
  shadowsocks-v2ray-plugin = pkg { pname = "shadowsocks-v2ray-plugin"; version = "1.3.2-unstable-2025-09-05"; src = gh "shadowsocks/v2ray-plugin" "e9af1cdd2549d528deb20a4ab8d61c5fbe51f306" "c7470b688492028bda5548607061acbbfc3067960266235eaf837240f5f89718";
    vendorHash = "sha256-jjuODH6WgXOFb7BRcBlKUR2YQfkEYXgf6g3UwqSvIm8="; subPkgs = ".";
    check = chk ''"$out/bin/v2ray-plugin" --help'' "[-]fast-open"; };
  # shellz (GPL-3.0-only): utility to manage your SSH, telnet, kubernetes, winrm, web or any custom shell.
  shellz = pkg { pname = "shellz"; version = "1.6.0"; src = gh "evilsocket/shellz" "v1.6.0" "3a89e3d573563a0c2ccb1831ff41fc0204c8b4efb011c10108ab98451a309b1c";
    vendorHash = "sha256-+U98meofmjukS2FlkjIilJ3hk6AQPUIMmmK3uQzyLwo="; subPkgs = "./cmd/shellz"; ldflags = "-s -w";
    check = chk ''"$out/bin/shellz" --help'' "[-]connection-timeout"; };
  # shortscan (MIT): IIS short filename enumeration tool.
  shortscan = pkg { pname = "shortscan"; version = "0.9.2"; src = gh "bitquark/shortscan" "refs/tags/v0.9.2" "8e5018f73e2dc1d4da9efe63c02dcc047662efe2c80058896eff03474396ff3e";
    vendorHash = "sha256-bhJX7PhTNmmL0Qub3guEu9462L4OjNg8jgxSz5n0On8="; subPkgs = "./cmd/shortscan ./cmd/shortutil"; ldflags = "-s -w";
    check = chk ''"$out/bin/shortscan" --version'' "0\\.9\\.2"; };
  # shoutrrr (MIT): notification library for gophers and their furry friends.
  shoutrrr = pkg { pname = "shoutrrr"; version = "0.8.0"; src = gh "containrrr/shoutrrr" "refs/tags/v0.8.0" "141c233631f51450f1015f32f7acd831d8585f0ebbd53e3b32675f46199d4248";
    vendorHash = "sha256-q9oFWdsq17H0Jfv95ivw2QWVbU2iCn3kee1wRmfvYi4="; subPkgs = "./shoutrrr";
    check = chk ''"$out/bin/shoutrrr" --version'' "0\\.8\\.0"; };
  # shuffledns (GPL-3.0-or-later): massDNS wrapper to bruteforce and resolve the subdomains with wildcard handling support.
  shuffledns = pkg { pname = "shuffledns"; version = "1.2.1"; src = gh "projectdiscovery/shuffledns" "v1.2.1" "f1a067b81980c57c9c024aab5988c78cb93159312d6fcf5c2ba0fd6b46d6f4e0";
    vendorHash = "sha256-nc1rnK5VjgRZh+GcOfnUd7vVBS7Y5tk8a03FjMMvyGw="; subPkgs = "./cmd/shuffledns"; ldflags = "-s -w";
    check = chk ''"$out/bin/shuffledns" --version'' "1\\.2\\.1"; };
  # sipexer (GPL-3.0-only): modern and flexible SIP CLI tool.
  sipexer = pkg { pname = "sipexer"; version = "2.0.0"; src = gh "miconda/sipexer" "v2.0.0" "848ad498dd73bc6e223cd9806b4bb675783c7c27d66e105414725f7f118808af";
    vendorHash = "sha256-hP391sneZY9sh9No8637Bp1KXn6Fcac78IdeTpzdrfk="; subPkgs = ".";
    check = chk ''"$out/bin/sipexer" --version'' "2\\.0\\.0"; };
  # smap (AGPL-3.0-only): drop-in replacement for Nmap powered by shodan.io.
  smap = pkg { pname = "smap"; version = "0.1.12"; src = gh "s0md3v/Smap" "refs/tags/0.1.12" "870838dc01cbf2a018db8bbdee2ac439e4666e131d1f014843fc5b6994c33049";
    vendorHash = "sha256-dk31IqOoG5yYCXV0kd9HBnCNli07+etnyvD7S7KtMW0="; subPkgs = "./cmd/smap"; ldflags = "-s -w";
    check = chk ''"$out/bin/smap" -h'' "[Uu]sage"; };
  # smtprelay (MIT): simple Golang SMTP relay/proxy server.
  smtprelay = pkg { pname = "smtprelay"; version = "1.14.0"; src = gh "decke/smtprelay" "refs/tags/v1.14.0" "c5a615c7d6391bf3cd2f4f83845ced60c92cd804119e1d6c1f7b2c8511306d76";
    vendorHash = "sha256-S+dgfoFz78xT4xf8BnE07brKXhIuNKCvHq+5ZusFJLU="; subPkgs = "."; ldflags = "-s -w -X=main.appVersion=v1.14.0";
    check = chk ''"$out/bin/smtprelay" --version'' "1\\.14\\.0"; };
  # snowcat (Apache-2.0): tool to audit the istio service mesh.
  snowcat = pkg { pname = "snowcat"; version = "0.1.3"; src = gh "praetorian-inc/snowcat" "v0.1.3" "ea489cf5e90d51587ab3bd51e0f73787025eb15a417a3fafa8d979c013234ac7";
    vendorHash = "sha256-41bMlbV3MEU0Ey3wZPPDhj40/mVP8Xssr42cEx5Mqsk="; subPkgs = "./cmd/snowcat"; ldflags = "-s -w";
    check = chk ''"$out/bin/snowcat" --help'' "[-]-discovery-address"; };
  # sourcemapper (BSD-3-Clause): extract JavaScript source trees from Sourcemap files.
  sourcemapper = pkg { pname = "sourcemapper"; version = "0-unstable-2024-03-22"; src = gh "denandz/sourcemapper" "467916e59f9f28f2df3c2fb209db32dabd057c92" "be9be08bcc7205f253df2fd1ff0e8e720ded87e0fb093a98b8dd67289863e569";
    vendorHash = null; subPkgs = ".";
    check = chk ''"$out/bin/sourcemapper" --help'' "[Uu]sage"; };
  # speedtest-go (MIT): CLI and Go API to Test Internet Speed using speedtest.net.
  speedtest-go = pkg { pname = "speedtest-go"; version = "1.8.3"; src = gh "showwin/speedtest-go" "refs/tags/v1.8.3" "48d01137468da9d419a3940a652803dafd8a6820abcd985b85c9d0c86b417ba3";
    vendorHash = "sha256-WR04n07ONSVgUdlBTgI3gRLQXaDz4zfn1npTswwx7fA="; subPkgs = ".";
    check = chk ''"$out/bin/speedtest-go" --version'' "1\\.8\\.3"; };
  # spicy (MIT): nintendo 64 segment assembler.
  spicy = pkg { pname = "spicy"; version = "0.6.2"; src = gh "trhodeos/spicy" "v0.6.2" "115e53a03949073025196519ae46842da59da23ed9034d84a2c7f25b7279cb62";
    vendorHash = "sha256-KTyQsUjEndkAy/EmyTkKBNRt5sZ2KVDnFiD8RAIqx7o="; subPkgs = "./cmd/print_elf ./cmd/spicy"; ldflags = "-s -w";
    check = chk ''"$out/bin/spicy" --help'' "[Uu]sage"; };
  # ssh-key-confirmer (MIT): test ssh login key acceptance without having the private key.
  ssh-key-confirmer = pkg { pname = "ssh-key-confirmer"; version = "0.1"; src = gh "benjojo/ssh-key-confirmer" "v0.1" "4cbae943dff900662231cb2c04fd06a8d5cede0c0f2c31b2722e9597cc3a7aff";
    vendorHash = "sha256-toUU26VZxAtKbi7+m/tf24KzPnQVwW86eqWt0zbd2N0="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/ssh-key-confirmer" --help'' "[Uu]sage"; };
  # ssh-to-age (MIT): convert ssh private keys in ed25519 format to age keys.
  ssh-to-age = pkg { pname = "ssh-to-age"; version = "1.3.0"; src = gh "Mic92/ssh-to-age" "refs/tags/v1.3.0" "5c1734a59f398779c6a4ce3b09602c0ce942f850997651efa4a14c80e666fdd3";
    vendorHash = "sha256-gZPDfoifYMt1CRbAtDeuk2htBr1ByhgloPchKrD4i48="; subPkgs = "./cmd/ssh-to-age"; ldflags = "-s -X main.version=1.3.0";
    check = chk ''"$out/bin/ssh-to-age" --version'' "1\\.3\\.0"; };
  # sshchecker (MIT): dedicated SSH brute-forcing tool.
  sshchecker = pkg { pname = "sshchecker"; version = "1.0"; src = gh "lazytools/sshchecker" "v1.0" "4c2546bf307cab201b03c137a2c1badd83fea7edeedc0ef6d89bd0a1e47c0097";
    vendorHash = "sha256-jaRmOsk75iRRtAjWflLuzLctkhH+NtVSVT99tQ2CcTs="; subPkgs = "./cmd/sshchecker";
    check = chk ''"$out/bin/sshchecker" --version'' "1\\.0"; };
  # sshm (MIT): terminal UI to manage and connect to SSH hosts.
  sshm = pkg { pname = "sshm"; version = "1.11.0"; src = gh "Gu1llaum-3/sshm" "refs/tags/v1.11.0" "9474fc4439773ed52b1f14ee7277a0ea0928a045234e20a2f334aa0efd0bc5a0";
    vendorHash = "sha256-ESq/RTJR3+B8uk6dhbzfPDbTN2dyJ3uqy6c/mepZ47o="; subPkgs = "."; ldflags = "-s -w -X=github.com/Gu1llaum-3/sshm/cmd.AppVersion=1.11.0";
    check = chk ''"$out/bin/sshm" --version'' "1\\.11\\.0"; };
  # sshocker (Apache-2.0): tool for SSH, reverse sshfs and port forwarder.
  sshocker = pkg { pname = "sshocker"; version = "0.3.11"; src = gh "lima-vm/sshocker" "refs/tags/v0.3.11" "1f1fe344a96f82ef459521e98bf05745491db0273b77c856d7c313ca9cd1d65e";
    vendorHash = "sha256-SHjmBaaPCeX+8jA0oEahI4XdEKn59CX2kIogD8iMlF8="; subPkgs = "./cmd/sshocker"; ldflags = "-s -w -X=github.com/lima-vm/sshocker/pkg/version.Version=0.3.11";
    check = chk ''"$out/bin/sshocker" --version'' "0\\.3\\.11"; };
  # stackblur-go (MIT): fast, almost Gaussian Blur implementation in Go.
  stackblur-go = pkg { pname = "stackblur-go"; version = "1.1.1"; src = gh "esimov/stackblur-go" "v1.1.1" "92978b07a3a72f81e5ab87c732e75c8713cfaa73e1f1b9dd78f8f7fdaa6c14d5";
    vendorHash = null; subPkgs = "./cmd/stackblur"; ldflags = "-s -w";
    check = chk ''"$out/bin/stackblur" --help'' "[Uu]sage"; };
  # stave (Apache-2.0): tool to find compound attack paths that single-resource scanners miss.
  stave = pkg { pname = "stave"; version = "0.0.3"; src = gh "sufield/stave" "refs/tags/v0.0.3" "671dd1df6e4ad4f1539148c5730b78086007b26e4b892dd22386f01ad6e32b90";
    vendorHash = null; subPkgs = "./cmd/stave"; ldflags = "-s -X=github.com/sufield/stave/internal/version.Version=v0.0.3 -X=github.com/sufield/stave/internal/version.Commit=refs/tags/v0.0.3 -X=github.com/sufield/stave/internal/version.Date=1970-01-01T00:00:00Z -X=github.com/sufield/stave/internal/version.BuiltBy=nixpkgs";
    check = chk ''"$out/bin/stave" --version'' "0\\.0\\.3"; };
  # stock-tui (MIT): terminal-based stock and cryptocurrency price tracker.
  stock-tui = pkg { pname = "stock-tui"; version = "0.1.0"; src = gh "ni5arga/stock-tui" "refs/tags/v0.1.0" "a6b1d74d2534613ede6230c0a2f23d05cdb5b07b597618307b98ef074d471762";
    vendorHash = "sha256-XN8BgfjYEo/Lmo+6YqS229mwXnxvG6y7dCv7YruK1RE="; subPkgs = "./cmd/stock-tui";
    check = chk ''"$out/bin/stock-tui" --help'' "[Uu]sage"; };
  # subjs (MIT): fetcher for JavaScript files.
  subjs = pkg { pname = "subjs"; version = "1.0.1"; src = gh "lc/subjs" "v1.0.1" "a1772a7cc9a46befd4465616041ff52b3375033f0ec13c48212b776fea37aa24";
    vendorHash = "sha256-Tw0RaBh3ZRBkjgTP0KROdlqZvCXGAFASswv9xwz1zkU="; subPkgs = "."; ldflags = "-s -w -X main.AppVersion=1.0.1";
    check = chk ''"$out/bin/subjs" --version'' "1\\.0\\.1"; };
  # swaynag-battery (MIT): shows a message when your battery is discharging.
  swaynag-battery = pkg { pname = "swaynag-battery"; version = "0.2.0"; src = gh "m00qek/swaynag-battery" "v0.2.0" "8d78aa19f11fdde26da40ec5769c42709c828eface56784e4fc4f4ca963cca0e";
    vendorHash = "sha256-d5MF5eRQ7RudBGnNq4IVis08YyIS2Ah7LnB93kp5zCo="; subPkgs = ".";
    check = chk ''"$out/bin/swaynag-battery" --help'' "[Uu]sage"; };
  # tailsnitch (MIT): security auditor for Tailscale configurations. Scans your tailnet for misconfigurations, overly permissive access controls, and security best practice violations.
  tailsnitch = pkg { pname = "tailsnitch"; version = "1.6"; src = gh "Adversis/tailsnitch" "refs/tags/v1.6" "cdf0a3ffac93e491520fd785e6f1b90bfd14ebc0d28ee94370caabc3574f3b3a";
    vendorHash = "sha256-gG/9fUzf7VqFMDT/Fz+aQu/8H5Ej9m//JNydYTYM8JQ="; subPkgs = "."; ldflags = "-w -s -X=github.com/Adversis/tailsnitch/cmd.Version=1.6 -X=github.com/Adversis/tailsnitch/cmd.BuildID=1.6 -X=github.com/Adversis/tailsnitch/cmd.BuildDate=1970-01-01T00:00:00Z";
    check = chk ''"$out/bin/tailsnitch" --version'' "1\\.6"; };
  # tcping-go (MIT): ping over TCP instead of ICMP, written in Go.
  tcping-go = pkg { pname = "tcping-go"; version = "0.1.1-unstable-2022-05-28"; src = gh "cloverstd/tcping" "83f644c761819f7c4386f0645cd0a337eccfc62e" "288cfc122d25a0f14da35e0085c075d58e39061519c7fa7723fce4fc34ee8ae1";
    vendorHash = "sha256-xfAgH8sT/o6BTozv9x5j0ty1fR2KBU3V45EHoi1bgJ8="; subPkgs = ".";
    check = chk ''"$out/bin/tcping" --help'' "[-]-dns-server"; };
  # terminal-space-program (MIT): terminal-native orbital-mechanics rocket simulator.
  terminal-space-program = pkg { pname = "terminal-space-program"; version = "0.51.2"; src = gh "jasonfen/terminal-space-program" "refs/tags/v0.51.2" "1bf2427fcc5f6b4f1803cdcadc296c26e2041ac634aad9ee75cdbd076937e70a";
    vendorHash = "sha256-TRIMJ9haf2G9HzkGwa6x/hF3mz/V9IiCKvf+s1rI3MY="; subPkgs = "./cmd/terminal-space-program"; ldflags = "-X github.com/jasonfen/terminal-space-program/internal/version.Version=0.51.2";
    check = chk ''"$out/bin/terminal-space-program" --version'' "0\\.51\\.2"; };
  # termshot (MIT): creates screenshots based on terminal command output.
  termshot = pkg { pname = "termshot"; version = "0.6.1"; src = gh "homeport/termshot" "refs/tags/v0.6.1" "40abea3c9ae604f3c2cdc7e2a623bf6063c6b1c504a70c5e3a1b8457dbdd2fbc";
    vendorHash = "sha256-6onueUGEu0MVLkZNHMfAhQQSAQZE1gJMY2ECPvloh80="; subPkgs = "./cmd/termshot"; ldflags = "-s -w -X github.com/homeport/termshot/internal/cmd.version=0.6.1";
    check = chk ''"$out/bin/termshot" --version'' "0\\.6\\.1"; };
  # terraform-config-inspect (MPL-2.0): CLI for shallow inspection of Terraform configurations.
  terraform-config-inspect = pkg { pname = "terraform-config-inspect"; version = "0-unstable-2026-09-04"; src = gh "hashicorp/terraform-config-inspect" "75d64de68c31445dbe4ee8308350e0b6dda1571d" "9a58feabb915cfb3e5340ce196ab64a73257a7197de5c939bdacd8e16c9220ea";
    vendorHash = "sha256-JWsyY6qld2MAmCVv98D98KJHXvu/ChqXAMZQfU/vhZo="; subPkgs = ".";
    check = chk ''"$out/bin/terraform-config-inspect" --help'' "[-]-after-init"; };
  # terrapin-scanner (Apache-2.0): vulnerability scanner for the Terrapin attack.
  terrapin-scanner = pkg { pname = "terrapin-scanner"; version = "1.1.3"; src = gh "RUB-NDS/Terrapin-Scanner" "refs/tags/v1.1.3" "3dde1f19e9228a2a284d73c63b193fdf775cb993945fb328cd01e3a6cc834bf1";
    vendorHash = "sha256-znsRE+bBvdHS5fRPq1JzDvmXoAxsQInAimONNGq14Lg="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/Terrapin-Scanner" --version'' "1\\.1\\.3"; };
  # tfautomv (Apache-2.0): when refactoring a Terraform codebase, you often need to write moved blocks. This can be tedious. Let tfautomv do it for you.
  tfautomv = pkg { pname = "tfautomv"; version = "0.7.0"; src = gh "busser/tfautomv" "v0.7.0" "0a00bfb9b4a236640cc4ad0efd9d1982c14f93d5379a5adcd35b1691e0846044";
    vendorHash = "sha256-up03VoaXPNbF7S/yOvYv+AUnhUae/aXObTVdGD51WVM="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/tfautomv" --version'' "0\\.7\\.0"; };
  # tfk8s (MIT): utility to convert Kubernetes YAML manifests to Terraform's HCL format.
  tfk8s = pkg { pname = "tfk8s"; version = "0.1.10"; src = gh "jrhouston/tfk8s" "v0.1.10" "be2680e76311ac7dd814a1bb0dceb486e3511d8d68845421338f9fcf5a92d5f9";
    vendorHash = "sha256-Zkt+fFObamPFGuzkb/34ZdkZZTyXIGuj9UXvhx5GFbc="; subPkgs = "."; ldflags = "-s -w -X main.toolVersion=v0.1.10 -X main.builtBy=nixpkgs";
    check = chk ''"$out/bin/tfk8s" --version'' "0\\.1\\.10"; };
  # tfproviderdocs (MPL-2.0): terraform Provider Documentation Tool.
  tfproviderdocs = pkg { pname = "tfproviderdocs"; version = "0.12.1"; src = gh "bflad/tfproviderdocs" "refs/tags/v0.12.1" "7381ef9a697b26b81ac5e2a57dcf339b8fde06891f8affe67f4703cc41e705b9";
    vendorHash = "sha256-7wdbfMf8WYy3Z46srGu/Avk+GKvmTFUNW7N3EmdlBsY="; subPkgs = "."; ldflags = "-s -w -X github.com/bflad/tfproviderdocs/version.Version=0.12.1 -X github.com/bflad/tfproviderdocs/version.VersionPrerelease=";
    check = chk ''"$out/bin/tfproviderdocs" --version'' "0\\.12\\.1"; };
  # tfupdate (MIT): update version constraints in your Terraform configurations.
  tfupdate = pkg { pname = "tfupdate"; version = "0.10.3"; src = gh "minamijoyo/tfupdate" "v0.10.3" "66d0aebdbd41c82d39edb6f2b241bb194fe7a03c162a555c6baa8f8ab7c794f6";
    vendorHash = "sha256-1Hf8yAXcCvCQevb3VxD/tTG6lkJP6AfrTiCnSDzRluI="; subPkgs = ".";
    check = chk ''"$out/bin/tfupdate" --version'' "0\\.10\\.3"; };
  # tgswitch (MIT): command line tool to switch between different versions of terragrunt.
  tgswitch = pkg { pname = "tgswitch"; version = "0.6.0"; src = gh "warrensbox/tgswitch" "0.6.0" "7a92abe68459b61857fc5f945ceef155d72c64954aa9deb409be47550ccd36e2";
    vendorHash = "sha256-+0r1M1F/kMGMFm+TfRkSJ5YL8W4MuvQx81QH/ztOJms="; subPkgs = "."; ldflags = "-s -w";
    check = chk ''"$out/bin/tgswitch" --help'' "[Uu]sage"; };
}
