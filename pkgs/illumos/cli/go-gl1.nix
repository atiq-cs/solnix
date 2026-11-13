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
}
