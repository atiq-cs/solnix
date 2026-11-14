# cli/rust-rl2.nix -- more Rust leaves the x86 build queue has jobs for (rl2 lane, 2026-11-14), as ./rust-rl1.nix: nixpkgs f4a03c0
# by-name attrs whose only missing input was rustPlatform (idle1 byname.tsv). On cargoPkg (../cargo.nix): pname and version are the
# queue job's, each source pinned by its tarball sha256 (its unpacked tree's NAR hash = nixpkgs' src hash, checked), its `cargo vendor
# --locked` by our FOD's NAR hash (nixpkgs' cargoHash is for its own fetcher). Build flags nixpkgs'. A new file: no served drv moves.
{ cargoPkg, chk }:
let
  gh = repo: ref: sha256: { url = "https://codeload.github.com/${repo}/tar.gz/${ref}"; inherit sha256; };
  cb = repo: ref: sha256: { url = "https://codeberg.org/${repo}/archive/${ref}.tar.gz"; inherit sha256; };
  crate = n: v: sha256: { url = "https://static.crates.io/crates/${n}/${v}/download"; inherit sha256; };
  fake = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  pkg = a: cargoPkg ({ vendorHash = fake; } // a);
  # `<bin> --version` must print the version (the in-build check)
  ver = bin: re: chk ''"$out/bin/${bin}" --version'' re;
in {
  # cargo-careful (MIT OR Apache-2.0): run Rust code with extra checking (a debug-assertions std).
  cargo-careful = pkg { vendorHash = "sha256-BoCd+aTiVozCQs5EKs2q49fcLeNtBOW0i9nahZMUOO4="; pname = "cargo-careful"; version = "0.4.10"; src = gh "RalfJung/cargo-careful" "v0.4.10" "494e913f8c99b6d247a9a52aef0bbd9af0e9cf9c3a4144a15769d88c31509579";
    bins = "cargo-careful"; check = chk ''"$out/bin/cargo-careful" careful'' "needs to be called with a subcommand"; };
  # cargo-feature (MIT): add, remove and list a dependency's features.
  cargo-feature = pkg { vendorHash = "sha256-aDYIq8zERPX2Zb+KsKA0YdtParePz2p7buUW9c5tD3w="; pname = "cargo-feature"; version = "0.7.0"; src = gh "Riey/cargo-feature" "v0.7.0" "5b88c1380f1bd6f3d7168137f08a6a534194d21254435a520c39a616398721f8";
    bins = "cargo-feature"; check = chk ''"$out/bin/cargo-feature" feature --version'' "0\\.7\\.0"; };
  # mdbook-open-on-gh (MPL-2.0): an mdbook preprocessor adding an open-on-GitHub link to every page.
  mdbook-open-on-gh = pkg { vendorHash = "sha256-EfZAcv+zzGzlhGtk24ZLpu2ouznbpH8Jn+alYdoplnw="; pname = "mdbook-open-on-gh"; version = "3.0.0"; src = gh "badboy/mdbook-open-on-gh" "3.0.0" "0d3f245873c98512c33900de96de04771df68bbbadf92a1c28d806e947770eb5";
    bins = "mdbook-open-on-gh"; check = ver "mdbook-open-on-gh" "3\\.0\\.0"; };
  # mdbook-yml-header (MPL-2.0): an mdbook preprocessor removing a page's YAML front matter.
  mdbook-yml-header = pkg { vendorHash = "sha256-WRviehjlZnSqHoCK/4G4eVRBYRJZJKIEev76g7ZoIH8="; pname = "mdbook-yml-header"; version = "0.1.5"; src = crate "mdbook-yml-header" "0.1.5" "1b05b19005d835f8fa7de12d88254ada515b9df06f9aceb3ede9bf37a772f7ea";
    bins = "mdbook-yml-header"; check = chk ''"$out/bin/mdbook-yml-header" --help'' "^USAGE:"; };
  # rmatrix (MIT): digital rain for terminals.
  rmatrix = pkg { vendorHash = "sha256-de3RKrh5/5t7VBofRKYzikt+cB883j+fJKzlp+EJUOU="; pname = "rmatrix"; version = "0.4.0"; src = gh "Tripstack-Corp/rmatrix" "refs/tags/v0.4.0" "3aae5ac09e3c31bf426894df39f4d3368d68290458917e12f103e41d7a2a4aaf";
    bins = "rmatrix"; check = ver "rmatrix" "0\\.4\\.0"; };
  # piday25 (MIT): Pi by the Chudnovsky algorithm, multithreaded (its Cargo.toml says 0.1.0 at this rev).
  piday25 = pkg { vendorHash = "sha256-+jicznGEhbxaPBpwM+nFXXzVLa9ekdjO51IAMvPCvxk="; pname = "piday25"; version = "0-unstable-2026-03-19"; src = gh "elkasztano/piday25" "c5220bba1b22468d4ce3b93343132731c4138115" "48abda366ddcc2a76878e2e49a3140d857e59a7b7fbc3907faf483877651d3b0";
    bins = "piday25"; check = ver "piday25" "0\\.1\\.0"; };
  # csv-tui (MIT): a terminal CSV editor (its Cargo.toml says 0.1.0 at the v1.2 tag).
  csv-tui = pkg { vendorHash = "sha256-9evX7d7/7z3C4zU83FTGIXe97JyHMXoVhcLLDsq+l48="; pname = "csv-tui"; version = "1.2"; src = gh "nathangavin/csv-tui" "v1.2" "ef62b2ff5d327a05a8717cd8ead6f426f13de3e2c7b98d98916ec0a7aff9b0f5";
    bins = "csv_tui"; check = ver "csv_tui" "1\\.2|0\\.1\\.0"; };
  # commit-formatter (MIT OR Apache-2.0): write a conventional git commit message interactively (git cf).
  commit-formatter = pkg { vendorHash = "sha256-RLeUBhtNzHRnaAU75aUC0OST4V9x62589aupNJRsiT4="; pname = "commit-formatter"; version = "0.3.0"; src = gh "Eliot00/commit-formatter" "v0.3.0" "2a96c5efbb9e89b0e47eb31773873c8fcb795eb4682da86117941096dd8ce4b3";
    bins = "git-cf"; check = chk ''"$out/bin/git-cf" < /dev/null'' "not a terminal"; };   # its prompt needs a tty: it runs to it
  # re-derq (MIT): an open reimplementation of Apple's derq.
  re-derq = pkg { vendorHash = "sha256-w9tbgloiReafWKQ+AjXW7+qV6cCraXni10DJ+qFfbDY="; pname = "re-derq"; version = "1.0.1"; src = cb "viraptor/re-derq" "refs/tags/1.0.1" "1d10c3ff3dd5acc2501ec76878a99a69927dcb22b46d2b166289a846d7322e8e";
    bins = "derq"; check = chk ''"$out/bin/derq" --help'' "^Usage: derq"; };
  # jot (MIT): note management in the terminal (jt).
  jot = pkg { vendorHash = "sha256-CIsX7fFFqxn6dkD0/uL4qhTTH+itIlS1A24XlmcYNCs="; pname = "jot"; version = "0.1.2"; src = gh "shashwatah/jot" "v0.1.2" "d7da3220c29102ee7c51e2a5656ceb6672ae3b85be22c5ddcd176b330c6029c9";
    bins = "jt"; check = chk ''"$out/bin/jt" --bogus'' "Found argument .--bogus. which wasn.t expected"; };
  # dirstat-rs (MIT): disk usage by directory (ds).
  dirstat-rs = pkg { vendorHash = "sha256-byaGed0g6qWMeFyBlLy3wBtf2C2B0opR3fBGSuyA8Xg="; pname = "dirstat-rs"; version = "0.3.7"; src = gh "scullionw/dirstat-rs" "refs/tags/v0.3.7" "27260a53770bc8cbe8f24d2d9612361ebf9fca10c40f57921cbeb6c4a5956e32";
    bins = "ds"; check = ver "ds" "0\\.3\\.7"; };
  # cargo-binutils (MIT OR Apache-2.0): cargo nm/objdump/size/strip/... and rust-* wrappers around the llvm-tools rustup component.
  cargo-binutils = pkg { vendorHash = "sha256-yYhngdP6tYcjazk2FAyj2zYh18Wh8TSXNX6aNT64U8M="; pname = "cargo-binutils"; version = "0.4.0"; src = crate "cargo-binutils" "0.4.0" "1656b16634e00e0b9f55bebc83f2c6f021cead99cb08aec52a7b9395563674b8";
    bins = "cargo-cov cargo-nm cargo-objcopy cargo-objdump cargo-profdata cargo-readobj cargo-size cargo-strip rust-ar rust-as rust-cov rust-ld rust-lld rust-nm rust-objcopy rust-objdump rust-profdata rust-readobj rust-size rust-strip"; check = chk ''"$out/bin/cargo-cov" cov --version; "$out/bin/cargo-cov" --version'' "0\\.4\\.0"; };
  # smux (MIT): tmux session manager with fzf-powered project and template selection.
  smux = pkg { vendorHash = "sha256-Pp3ppruL5JTgUorxmR8AS1ALHfFAMzIV4nsIKMIunRc="; pname = "smux"; version = "0.6.0"; src = gh "Aietes/smux" "refs/tags/v0.6.0" "1020f9aa275f71e66d4024f3d11a94c76b337c850a7ffc32d071d786af29d39f";
    bins = "smux"; check = ver "smux" "0\\.6\\.0"; };
  # cfonts (GPL-3.0-or-later): large ANSI-art fonts in the console.
  cfonts = pkg { vendorHash = "sha256-1LbK/EMHAwgXhkPBB5C+5myYc/8Rzh2fiy/MwFnglYk="; pname = "cfonts"; version = "1.3.0"; src = crate "cfonts" "1.3.0" "5b8f9b961805729ae5f1e19cb7e364c8e6b77434cc02f0938a77ac150e97c161";
    bins = "cfonts"; check = ver "cfonts" "1\\.3\\.0"; };
  # hexdino (MIT): hex editor with vim like keybindings written in Rust.
  hexdino = pkg { vendorHash = "sha256-q+GrMuMU5hqfpvr2XM2mMaFC2IIZvk0CJykrwEnefz4="; pname = "hexdino"; version = "0.1.4"; src = gh "Luz/hexdino" "0.1.4" "08d32ba56302ca2ebc15b25b7eb9342e430d70389310a9a50cb4a414a3ae5e98";
    bins = "hexdino"; check = ver "hexdino" "0\\.1\\.4"; };
  # vivid (MIT OR Apache-2.0): generator for LS_COLORS with support for multiple color themes.
  vivid = pkg { vendorHash = "sha256-5SpCCNdOqOofPcEarLo6z+PT5VKxDwGHCudK+8NezzM="; pname = "vivid"; version = "0.11.1"; src = gh "sharkdp/vivid" "v0.11.1" "a43ccfbc6554055181a08f2740664f9280fa2d0e57c4641850c60dd0e5323720";
    bins = "vivid"; check = ver "vivid" "0\\.11\\.1"; };
  # fre (MIT): CLI tool for tracking your most-used directories and files.
  fre = pkg { vendorHash = "sha256-vC35YpD2cFqga5oe1VdvfokDDtI6uCDStU1EWYPwnZw="; pname = "fre"; version = "0.4.1"; src = gh "camdencheek/fre" "v0.4.1" "dab1da46e8e2dc581c0812c6160893a962fb677dfebe773ba333fd28b98e818b";
    bins = "fre"; check = ver "fre" "0\\.4\\.1"; };
  # twiggy (Apache-2.0 OR MIT): code size profiler for Wasm.
  twiggy = pkg { vendorHash = "sha256-P31a0yheiEhW+9rnGuX9xJq1EoZxtI/tKfA5HXdmn8c="; pname = "twiggy"; version = "0.8.0"; src = crate "twiggy" "0.8.0" "0b2428af4556b542446239d67b1c21f2d4e51dc148b61e7b5c34e4b0f0e8128c";
    bins = "twiggy"; check = ver "twiggy" "0\\.8\\.0"; };
  # wambo (MIT): all-in-one tool to convert decimal/bin/oct/hex and interpret bits as integers.
  wambo = pkg { vendorHash = "sha256-C82vYXFRL4Al0ZC0zEKbdgh5WKMKVwJX6gr9wS2f4vY="; pname = "wambo"; version = "0.4.0"; src = crate "wambo" "0.4.0" "5aea2134469828c3207c88c7aac0a0a416730acdf4bfe665962782ae935f202b";
    bins = "wambo"; check = chk ''"$out/bin/wambo" zz'' "^Illegal input: Invalid format"; };
  # cargo-wipe (MIT): find and optionally remove every target/ or node_modules/ under a directory (cargo wipe).
  cargo-wipe = pkg { vendorHash = "sha256-29ekW+kFFF2RbPjqEeeOa0Thh6Of8DVCkPWSq6vaZpQ="; pname = "cargo-wipe"; version = "0.4.0"; src = gh "mihai-dinculescu/cargo-wipe" "v0.4.0" "7f74a5084f89a17e7f682671c5b43558b1197bf3fa07e80db5bac1455bebd389";
    bins = "cargo-wipe"; check = chk ''"$out/bin/cargo-wipe" wipe --version; "$out/bin/cargo-wipe" --version'' "0\\.4\\.0"; };
  # ccase (MIT): command line interface to convert strings into any case.
  ccase = pkg { vendorHash = "sha256-1sKNpe5+ae0MDnvlp6iUHvMsvf0ZXMTcTA5yIlX+3DM="; pname = "ccase"; version = "0.5.1"; src = gh "stringcase/ccase" "refs/tags/0.5.1" "3ec9ba72aa8697bbf4ff2a03c57be0ce6236902959f799bc561e482ed50b91a3";
    bins = "ccase"; check = ver "ccase" "0\\.5\\.1"; };
  # jf (MIT): small utility to safely format and print JSON objects in the commandline.
  jf = pkg { vendorHash = "sha256-qMkfN5DzGuNVh2u0zqu4gS2zDWYzEVCHv2zjZpsmuAg="; pname = "jf"; version = "1.0.0"; src = gh "sayanarijit/jf" "v1.0.0" "fa7acd5cbe06513227a7a4ac5968cf159b742d2d89f9c90416681ce1d7ad04b3";
    bins = "jf"; noDefault = true; man = ''mkdir -p "$out/share/man/man1" && cp assets/jf.1 "$out/share/man/man1/"''; check = ver "jf" "1\\.0\\.0"; };
  # mdq (MIT OR Apache-2.0): like jq but for Markdown: find specific elements in a md doc.
  mdq = pkg { vendorHash = "sha256-ksLpZdrLQjC1PYUPvxQ/LKXyWj6By1ydyeboAxn4WeE="; pname = "mdq"; version = "0.10.0"; src = gh "yshavit/mdq" "refs/tags/v0.10.0" "81d6ecb8602930483c234cc3a4242f8c66e82d93010114062b394d46f7c464ef";
    bins = "mdq"; check = ver "mdq" "0\\.10\\.0"; };
  # uwc (MPL-2.0): like wc, but unicode-aware, and with per-line mode.
  uwc = pkg { vendorHash = "sha256-Bnqtu0iEiJvxrKI33UcAfGXhiMCzCjFPrwtRtPmpOjc="; pname = "uwc"; version = "1.0.7"; src = gh "dead10ck/uwc" "refs/tags/v1.0.7" "255a5484f43c8ab12e92c196b4fd6d58b751842ee00f3f052dfc76d5b2793ab1";
    bins = "uwc"; check = ver "uwc" "1\\.0\\.7"; };
  # cargo-temp (MIT OR Apache-2.0): a temporary Rust project with chosen dependencies.
  cargo-temp = pkg { vendorHash = "sha256-6dtpAxbK85euhHBpraFFzY5vxZRs9vdYB0fsgz3faQg="; pname = "cargo-temp"; version = "0.4.2"; src = gh "yozhgoor/cargo-temp" "v0.4.2" "d6dfa2b4d946b1800afcc02575afa547722a2911217cb24c28c9a997acaa49cb";
    bins = "cargo-temp"; check = chk ''"$out/bin/cargo-temp" temp --version; "$out/bin/cargo-temp" --version'' "0\\.4\\.2"; };
  # mini-redis (MIT): Tokio's learning Redis client and server (incomplete by design).
  mini-redis = pkg { vendorHash = "sha256-T1bpYsP1q/lV/Ua0BxEyygb+F+z7mjXm3Z7SEPyyocg="; pname = "mini-redis"; version = "0.4.1"; src = crate "mini-redis" "0.4.1" "528890a6b63c88c9bda173867128abe62c0f5050dd959f067aeea09e90439f33";
    bins = "mini-redis-cli mini-redis-server"; check = ver "mini-redis-cli" "0\\.4\\.1"; };
  # cargo-autoinherit (Apache-2.0 OR MIT): automatically DRY up your Rust dependencies.
  cargo-autoinherit = pkg { vendorHash = "sha256-5s75wBx65288oIhwDxtRplMeXbYlgJ2i56g1Y7oRb9U="; pname = "cargo-autoinherit"; version = "0.1.6"; src = gh "mainmatter/cargo-autoinherit" "v0.1.6" "38c6cd90c3295ad8ca87a6f7291c71ffca09d49fc38f0dc101d8766bd6d05e64";
    bins = "cargo-autoinherit"; check = chk ''"$out/bin/cargo-autoinherit" autoinherit --help'' "Usage: cargo autoinherit"; };
  # code-minimap (Apache-2.0 OR MIT): high performance code minimap render.
  code-minimap = pkg { vendorHash = "sha256-ft5vb0T4mDboHj2DB1bUF1jgg6tfk9/dV2/dCTTYBKo="; pname = "code-minimap"; version = "0.6.8"; src = gh "wfxr/code-minimap" "v0.6.8" "c68d4387bd0b86684a1b7c643d6281b79e018da318657254f2502ad032d52355";
    bins = "code-minimap"; check = ver "code-minimap" "0\\.6\\.8"; };
  # clog-cli (MIT): generate changelogs from local git metadata.
  clog-cli = pkg { vendorHash = "sha256-RuXWbqWVgzPtziVNO/8ZDdk4cOtI+bvHu8hbc323xVA="; pname = "clog-cli"; version = "0.10.0"; src = gh "clog-tool/clog-cli" "7066cba2bcbaea0f62ea22c320d48dac20f36a38" "32e241a3fdcf4f08f5d4dfe215b994590847a5bbe863e2075909ce5e867ef89b";
    bins = "clog"; check = ver "clog" "0\\.10\\.0"; };
  # hadolint-sarif (MIT): CLI tool to convert hadolint diagnostics into SARIF.
  hadolint-sarif = pkg { vendorHash = "sha256-ehr9tqhOoX5UkSW01tKfNtw3IqXyOr2E96iUenae1Yw="; pname = "hadolint-sarif"; version = "0.8.0"; src = crate "hadolint-sarif" "0.8.0" "4fc4729dd0ba21e9ef1c960c582aeb272d2ba26e9ebb3e4473069bda4d3247f0";
    bins = "hadolint-sarif"; check = ver "hadolint-sarif" "0\\.8\\.0"; };
  # manix (Apache-2.0): a fast documentation searcher for Nix (its Cargo.toml says 0.8.0-dev).
  manix = pkg { vendorHash = "sha256-l3Ks9vl+k5gVGPqR+2GTS/Q68Ega+KMPCZWmDSMnv0o="; pname = "manix"; version = "0.9.0"; src = gh "nix-community/manix" "v0.9.0" "de6a42e0123e43447b3ee827607bb5a2aad2206e6f4cfcc28db04c24f9cc7014";
    bins = "manix"; check = chk ''"$out/bin/manix" --help'' "^Usage: manix"; };
  # markdown-code-runner (EUPL-1.2): run a Markdown file's code blocks by external commands and optionally splice their output in (mdcr).
  markdown-code-runner = pkg { vendorHash = "sha256-hJUKb/krHIiqBNawOcVU7ezLcZDt3Qko3okYtWfZ3L4="; pname = "markdown-code-runner"; version = "0.5.2"; src = gh "drupol/markdown-code-runner" "refs/tags/0.5.2" "e607161c9173b4fe2f598cc897c62b66bf42182e64620451785498e3c08c3b92";
    bins = "mdcr"; check = ver "mdcr" "0\\.5\\.2"; };
  # shellcheck-sarif (MIT): CLI tool to convert shellcheck diagnostics into SARIF.
  shellcheck-sarif = pkg { vendorHash = "sha256-BBUAnK2HdLsWFsIh/f1zhn64KFU+18OD0VPrri2fsdc="; pname = "shellcheck-sarif"; version = "0.8.0"; src = crate "shellcheck-sarif" "0.8.0" "3eee74bd651e1a7708d5f1f7a7902974e2933a274995ddc4f78498eb67c70fd3";
    bins = "shellcheck-sarif"; check = ver "shellcheck-sarif" "0\\.8\\.0"; };
  # cargo-all-features (MIT OR Apache-2.0): cargo subcommand to build and test all feature flag combinations.
  cargo-all-features = pkg { vendorHash = "sha256-ociaf35+4NC9fzoYosMdCKgTM6u8/+ztdNS91QS8lBQ="; pname = "cargo-all-features"; version = "1.12.0"; src = crate "cargo-all-features" "1.12.0" "fa18ad33ab82f8c7681deaf3439b6a3e2fa17823e3b6d07d1e6d8b582a2c34d8";
    bins = "cargo-all-features cargo-build-all-features cargo-check-all-features cargo-test-all-features"; check = chk ''"$out/bin/cargo-all-features" all-features --version; "$out/bin/cargo-all-features" --version'' "1\\.12\\.0"; };
  # nix-sweep (MIT): utility to clean up old Nix profile generations and left-over garbage collection roots.
  nix-sweep = pkg { vendorHash = "sha256-ZDNzGlDD8gUXPPpTicC/HN/V2N+o2wAcoIbSHvR+DHg="; pname = "nix-sweep"; version = "0.8.0"; src = gh "jzbor/nix-sweep" "refs/tags/v0.8.0" "8a6ac95343f55098e7ec6f619d159c2a82c4fca3b78036d36f2923766ec00024";
    bins = "nix-sweep"; check = ver "nix-sweep" "0\\.8\\.0"; };
  # cargo-apk (MIT OR Apache-2.0): tool for creating Android packages.
  cargo-apk = pkg { vendorHash = "sha256-J8FfnVlwSyFhRhn36IQOI4YsJYMRxdgyK+l3uIGu2Eo="; pname = "cargo-apk"; version = "0.10.0"; src = crate "cargo-apk" "0.10.0" "eacab379c4d1c432e9338eda2372cac40f9aa71deefc4574ac75362f932fb7a3";
    bins = "cargo-apk"; check = chk ''"$out/bin/cargo-apk" apk --help'' "Usage: cargo-apk apk"; };
  # uair (MIT): extensible pomodoro timer.
  uair = pkg { vendorHash = "sha256-SizSo/gUHemifNRPzWyS8sEMs81Gr1F6VQ2eSMYlLSo="; pname = "uair"; version = "0.6.3"; src = gh "metent/uair" "v0.6.3" "732c7aa469fb406e8dee814d76b57045016ace3a18b0e764a8a6a69716f29a55";
    bins = "uair uairctl"; check = ver "uair" "0\\.6\\.3"; };
  # cargo-criterion (Apache-2.0 OR MIT): run Criterion.rs benchmarks (cargo criterion).
  cargo-criterion = pkg { vendorHash = "sha256-AvdHzHs6qAbSfmBhKjEAuDQ7G54Ha12W4O0C27eyNQ0="; pname = "cargo-criterion"; version = "1.1.0"; src = gh "bheisler/cargo-criterion" "refs/tags/1.1.0" "fe156bf7b360874419f7a97349c9f2fa94ab5fd6dc2c06b0070053f9d5596445";
    bins = "cargo-criterion"; check = chk ''"$out/bin/cargo-criterion" criterion --version; "$out/bin/cargo-criterion" --version'' "1\\.1\\.0"; };
  # rsign2 (MIT): command-line tool to sign files and verify signatures.
  rsign2 = pkg { vendorHash = "sha256-vlTVTIpw+ahf38OZdhiD7GbdGNEusoebIGdUfPNScl8="; pname = "rsign2"; version = "0.6.5"; src = crate "rsign2" "0.6.5" "1fd796b2662ab718e125565c6664ffb34b48bb5de6ee19578282e82e50875046";
    bins = "rsign"; check = ver "rsign" "0\\.6\\.5"; };
  # termsnap (MIT OR Apache-2.0): create SVGs from terminal output.
  termsnap = pkg { vendorHash = "sha256-DP7WvA3kQgoTNBA25IZ3I6XokMYyPjHWaAk/boUsybI="; pname = "termsnap"; version = "0.4.0"; src = gh "tomcur/termsnap" "termsnap-v0.4.0" "43b394d628507db83c36d837ceb2817e4b55b7e7332daf3f6c2b132d369bd71a";
    bins = "termsnap"; check = ver "termsnap" "0\\.4\\.0"; };
  # cargo-sort-derives (MIT): cargo subcommand to sort derive attributes.
  cargo-sort-derives = pkg { vendorHash = "sha256-l6xNtfFcsrswnMOfk63utvAfFViZkyqZVx1MBOP6W0o="; pname = "cargo-sort-derives"; version = "0.14.1"; src = gh "lusingander/cargo-sort-derives" "refs/tags/v0.14.1" "0dcd26e3b46d2416f819b63667a0467facb71f26a6aaa1e0447f9ef6624757e1";
    bins = "cargo-sort-derives"; check = chk ''"$out/bin/cargo-sort-derives" sort-derives --version; "$out/bin/cargo-sort-derives" --version'' "0\\.14\\.1"; };
  # cargo-run-bin (MIT): build, cache and run the binaries a Cargo.toml pins, rather than installing them globally (cargo bin).modrun, and allows your teams to always be running the same tooling versions.
  cargo-run-bin = pkg { vendorHash = "sha256-42BrJgGnbibJXLVXvM8qq8mdDi5/Xk6zjZ0p0kLLBqE="; pname = "cargo-run-bin"; version = "1.7.5"; src = crate "cargo-run-bin" "1.7.5" "1ba4ea665f68a2042470ec6e27a36755783ebd3367b90bec2fb100f9d5012fd8";
    bins = "cargo-bin"; check = chk ''"$out/bin/cargo-bin" bin --version; "$out/bin/cargo-bin" --version'' "1\\.7\\.5"; };
  # krabby (GPL-3.0): print pokemon sprites in your terminal.
  krabby = pkg { vendorHash = "sha256-GMobdgQDTOl7XYLIs73CpT7MJgnJsbI/+hqc9BDCBpU="; pname = "krabby"; version = "0.3.0"; src = crate "krabby" "0.3.0" "b4453736d55a3fd2f8121fd4ebe38fb53d9b2a2ccc4c19c76c801ccb04af961b";
    bins = "krabby"; check = ver "krabby" "0\\.3\\.0"; };
  # clang-tidy-sarif (MIT): CLI tool to convert clang-tidy diagnostics into SARIF.
  clang-tidy-sarif = pkg { vendorHash = "sha256-AHb8OU1XjiDCu55sDOJvQcW3td58+YSxByCDISNFCyA="; pname = "clang-tidy-sarif"; version = "0.8.0"; src = crate "clang-tidy-sarif" "0.8.0" "4a9fd2d1f9ba37e767283228fef33d53c136e81a570800f0531da1986e595079";
    bins = "clang-tidy-sarif"; check = ver "clang-tidy-sarif" "0\\.8\\.0"; };
  # github-distributed-owners (MIT): generate GitHub CODEOWNERS files from OWNERS files distributed through the file tree.
  github-distributed-owners = pkg { vendorHash = "sha256-QcqE5R69wGhLB2vpyReIgVssvf4IDopzKxGopA95jOA="; pname = "github-distributed-owners"; version = "0.1.12"; src = gh "andrewring/github-distributed-owners" "refs/tags/v0.1.12" "d8d89361d30372231a372353903dd9c876fd0f6519dc6c985cb044aaa86fbebf";
    bins = "github-distributed-owners"; check = ver "github-distributed-owners" "0\\.1\\.12"; };
  # rpg-cli (MIT): your filesystem as a dungeon.
  rpg-cli = pkg { vendorHash = "sha256-gx0/Nl5M1xM4yzQVYQwhMQz5n0jJBY6uN37I5nlnaWA="; pname = "rpg-cli"; version = "1.2.0"; src = gh "facundoolano/rpg-cli" "1.2.0" "f3993abe7b73666bc3707760dcc650aa9190cd3e7f06be846a0b6adcbbc46663";
    bins = "rpg-cli"; check = ver "rpg-cli" "1\\.2\\.0"; };
  # bingrep (MIT): grep through ELF, Mach-O and PE binaries, in colour.
  bingrep = pkg { vendorHash = "sha256-v02dFKdBEM6/y/SkU6nvrg0N+hYbJekMd3hkWjozNCY="; pname = "bingrep"; version = "0.12.1"; src = gh "m4b/bingrep" "v0.12.1" "8bf096df68736561b40f56cd1feb4834014cd11c0a28b33e74e818618c62e100";
    bins = "bingrep"; check = ver "bingrep" "0\\.12\\.1"; };
  # basilk (MIT OR Apache-2.0): a terminal kanban task manager.
  basilk = pkg { vendorHash = "sha256-juz4TAPJdQqzCORjPWeDc3b672gktRSc/LjXKtiA29E="; pname = "basilk"; version = "0.2.1"; src = gh "gabalpha/basilk" "refs/tags/0.2.1" "d82fd61004c806359d79b0acd4e38943e505d27e666cec1cc6bbe82de08c0ccd";
    bins = "basilk"; check = ver "basilk" "0\\.2\\.1"; };
  # xre (MIT OR Apache-2.0): fast regex extraction tool with pattern matching, replacement, and configurable sorting.
  xre = pkg { vendorHash = "sha256-9kIEWLZdIVzEEo+wZ4ZBIkTIDLx1Gs4evrGUHJIjEtg="; pname = "xre"; version = "0.1.1"; src = gh "wfxr/xre" "refs/tags/v0.1.1" "8b5c2c1f136e191bdae81d0828f9ebe5bc9d863f88264783f4df56ca4e253534";
    bins = "xre"; check = ver "xre" "0\\.1\\.1"; };
  # sarif-fmt (MIT): CLI tool to pretty print SARIF diagnostics.
  sarif-fmt = pkg { vendorHash = "sha256-iEm67wsceIx7yG6b7mEzhBKw9BWDxXKYzQwEMPCAbw0="; pname = "sarif-fmt"; version = "0.8.0"; src = crate "sarif-fmt" "0.8.0" "6b321c640131597cc816b62d334b79dd86753e5a0145dfac50dae430b2834a64";
    bins = "sarif-fmt"; check = ver "sarif-fmt" "0\\.8\\.0"; };
  # uesave (MIT): reading and writing Unreal Engine save files (commonly referred to as GVAS).
  uesave = pkg { vendorHash = "sha256-SjygQWkJuy7yiWDmvCxL7yLXru73Js3ROeofAl2e9y4="; pname = "uesave"; version = "0.7.1"; src = gh "trumank/uesave" "v0.7.1" "400793de0601075c964c73f699d14c6be6ec249c9f6758c75f286a7f5b33ade9";
    bins = "uesave"; check = ver "uesave" "0\\.7\\.1"; };
  # mdbook-mermaid (MPL-2.0): preprocessor for mdbook to add mermaid.js support.
  mdbook-mermaid = pkg { vendorHash = "sha256-JZf/RkqUdGFndJaMPpj35LBUn0qU2X6xCtO00ex8rTk="; pname = "mdbook-mermaid"; version = "0.17.1"; src = gh "badboy/mdbook-mermaid" "refs/tags/v0.17.1" "5b0242092325a383c46ad9fcd15f2f6972ccc549b640fcb74bc02cf3d2cf45d4";
    bins = "mdbook-mermaid"; check = ver "mdbook-mermaid" "0\\.17\\.1"; };
  # ren-find (MIT): command-line utility that takes find-formatted lines and batch renames them.
  ren-find = pkg { vendorHash = "sha256-O3N/teGxDVbEVLqj5v23HCf6DjrkHe/b4fUzG2BsG6Q="; pname = "ren-find"; version = "0.0.4"; src = gh "robenkleene/ren-find" "refs/tags/0.0.4" "9f1d7e20773985a3dbdd707a409585ea686d95949b0a02bffda2000207e21267";
    bins = "ren"; check = ver "ren" "0\\.0\\.4"; };
  # when-cli (Apache-2.0): command line tool for converting between timezones.
  when-cli = pkg { vendorHash = "sha256-ltg9uoKQgAjjdGGaeI6m2+8aaW4A2BnJOKpfIdfeya4="; pname = "when-cli"; version = "0.4.0"; src = crate "when-cli" "0.4.0" "c4dee7f535c2a00583e134f2cb54f97ace2d860dce238a50551024e201e5426e";
    bins = "when"; check = ver "when" "0\\.4\\.0"; };
  # zet (MIT OR Apache-2.0): CLI utility to find the union, intersection, set difference, etc of files considered as sets of lines.
  zet = pkg { vendorHash = "sha256-JY/LrE55TBgW/gvUj0YkOsguEwjTTE7SzBsy+3tAVoE="; pname = "zet"; version = "2.0.1"; src = gh "yarrow/zet" "refs/tags/v2.0.1" "a6f431927c16b22516e78a9ec7864d99e2676abae3acb46101df1c287e16f267";
    env = ''export RUSTFLAGS="$RUSTFLAGS -Amismatched_lifetime_syntaxes"'';   # as nixpkgs: its deny(warnings) meets rustc 1.99's new lint
    bins = "zet"; check = ver "zet" "2\\.0\\.1"; };
  # ngrrram (GPL-3.0-only): TUI tool to help you type faster and learn new layouts. Includes a free cat (its Cargo.toml says 0.1.0).
  ngrrram = pkg { vendorHash = "sha256-Qehef8yIWv6he+1CcgyNwVR7l9TyUt26wJo/1W8BcLI="; pname = "ngrrram"; version = "1.0.3"; src = gh "wintermute-cell/ngrrram" "v1.0.3" "6979fe829e773489cc22e45e37784565f2b8e514047e48e64909fa5ff93696af";
    bins = "ngrrram"; check = chk ''"$out/bin/ngrrram" --version'' "^Usage: ngrrram"; };
  # bagr (Apache-2.0): command line utility for interacting with BagIt bags (RFC 8493).
  bagr = pkg { vendorHash = "sha256-MImRo6GcGP6lucXeY7kOsNb+YVjGu3z8JrPHp1Hh0GA="; pname = "bagr"; version = "0.3.0"; src = gh "pwinckles/bagr" "refs/tags/v0.3.0" "2c35784582277523efcfde0699b9303321c79eee640b19f9d3620b0c8108f7c3";
    bins = "bagr"; check = ver "bagr" "0\\.3\\.0"; };
  # confy-tui (GPL-3.0-or-later): config manager tui for linux/unix systems (its Cargo.toml says 3.1.0).
  confy-tui = pkg { vendorHash = "sha256-sNv1Ub+AkhMBEbirlxSITVVAwOvaBPFt4UIOOVvFPrI="; pname = "confy-tui"; version = "3.1.1"; src = gh "phluxjr/confy" "v3.1.1" "ec717f749715d90290976aa371f54b43588403a2e9ea9fe6a6c3a43ac89c0787";
    bins = "confy"; man = ''mkdir -p "$out/share/man/man1" && cp confy.1 "$out/share/man/man1/"''; check = chk ''"$out/bin/confy" --version'' "No such device or address"; };
  # nomino (MIT OR Apache-2.0): batch rename utility for developers.
  nomino = pkg { vendorHash = "sha256-fMmx5jpIxbP6nBitGu8+JeVxZg3NekYwUiM36fn9NtU="; pname = "nomino"; version = "1.6.4"; src = gh "yaa110/nomino" "1.6.4" "e83d9a62163f9faaff4c6650284de3dbe92e546ac09e3717c0bb9cde8352d005";
    bins = "nomino"; check = ver "nomino" "1\\.6\\.4"; };
  # psleep (Apache-2.0): like sleep but shows a live progress bar.
  psleep = pkg { vendorHash = "sha256-bxaZ9iBNR2KkBu5IWpU9x8KMgxShTB5ABcXyn2tNkAw="; pname = "psleep"; version = "0.3.0"; src = gh "Yesh-02/psleep" "refs/tags/v0.3.0" "c154df5855155698013976d5dd623df668352930bc6874cac44eef06bdc268fc";
    bins = "psleep"; check = ver "psleep" "0\\.3\\.0"; };
  # cargo-fuzz (MIT OR Apache-2.0): command line helpers for fuzzing.
  cargo-fuzz = pkg { vendorHash = "sha256-Crhp7zXW1ZjCqsKwcqNqp4etgq5IKRPDzqS43RPvTF4="; pname = "cargo-fuzz"; version = "0.13.2"; src = gh "rust-fuzz/cargo-fuzz" "refs/tags/0.13.2" "88e179805e4fe4c9903720a004ef6903b0f28b27a22e74660cd72f58612f6b46";
    bins = "cargo-fuzz"; check = chk ''"$out/bin/cargo-fuzz" fuzz --version; "$out/bin/cargo-fuzz" --version'' "0\\.13\\.2"; };
  # cargo-license (MIT): cargo subcommand to see license of dependencies.
  cargo-license = pkg { vendorHash = "sha256-azc/FAs3Yg6VWjNycdYJbmM74kszYosANh3czccsrMo="; pname = "cargo-license"; version = "0.7.0"; src = crate "cargo-license" "0.7.0" "662dc8581a263e6330eefdfff955851edcbffcd6d6d96e79384f6fe7a31a1d80";
    bins = "cargo-license"; check = chk ''"$out/bin/cargo-license" --version'' "^Usage: cargo license"; };
  # arwen (MIT): cross-platform patching of shared libraries in Rust (its Cargo.toml says 0.1.0).
  arwen = pkg { vendorHash = "sha256-mfb9NgtZvPQdjAW0eOfQZ8EGhsZDj15hT9zUkfl4tFU="; pname = "arwen"; version = "0.0.5-unstable-2026-04-07"; src = gh "nichmor/arwen" "696351a8c208315b0dfd4a1e5c37288a689ccd2e" "4acc2f2eec5ac57086886032099ba0b3a5df1b248d15ce4d2eb2171792cef3f8";
    bins = "arwen"; check = chk ''"$out/bin/arwen" --version'' "^Usage: arwen <COMMAND>"; };
  # rep-grep (MIT): command-line utility that takes grep-formatted lines and performs a find-and-replace on them.
  rep-grep = pkg { vendorHash = "sha256-mnEi2DOqJgAbuQ/rhCj6SMMMKvzPwtoxJ8VEOO00uzo="; pname = "rep-grep"; version = "0.0.8"; src = gh "robenkleene/rep-grep" "refs/tags/0.0.8" "929be5ef42384b68931978056104d1be429df38dea1487987de4da9f5045565d";
    bins = "rep"; check = ver "rep" "0\\.0\\.8"; };
  # hayagriva (MIT OR Apache-2.0): work with references: Literature database management, storage, and citation formatting.
  hayagriva = pkg { vendorHash = "sha256-A08EtDlbaaQkiE7iv0crS7dnyVN+F0B1Ya8GKsIYfOA="; pname = "hayagriva"; version = "0.10.1"; src = crate "hayagriva" "0.10.1" "7b6c185c5c72546d50b25b70187f01ab9a1a2fa21c4db8691e2426fa5fce805c";
    features = "cli"; bins = "hayagriva"; check = ver "hayagriva" "0\\.10\\.1"; };
  # koto-ls (MIT): language server for Koto.
  koto-ls = pkg { vendorHash = "sha256-HtZ2opI4uv+2N0vbiCKNILdPrem31wKjFzLlCYQIIr0="; pname = "koto-ls"; version = "0.16.1"; src = gh "koto-lang/koto-ls" "refs/tags/v0.16.1" "8571abfd3058473a3bd9ca54bb02f38bf47fe42e3cd304d8e6cd6227aeb7bcf6";
    bins = "koto-ls"; check = chk ''"$out/bin/koto-ls" --version < /dev/null; echo "rc=$?"'' "^rc=0$"; };
  # melody (MIT OR Apache-2.0): language that compiles to regular expressions.
  melody = pkg { vendorHash = "sha256-bsP9EzQzmB53s6wf7ech/Hh876iCCFoI4p6teOlYYUo="; pname = "melody"; version = "0.20.0"; src = crate "melody_cli" "0.20.0" "eb2d46e086975982cc62cc84ca9a2c891f486a2a909ae8ffa86530896f945a7b";
    bins = "melody"; check = ver "melody" "0\\.20\\.0"; };
  # minefair (MIT): fair and infinite implementation of Minesweeper.
  minefair = pkg { vendorHash = "sha256-on9cSyu1zlMSKF8fvtE8nIVLleGoZ+sK74T6T1aUTVg="; pname = "minefair"; version = "1.5.0"; src = gh "LyricLy/minefair" "refs/tags/1.5.0" "62ebaa9d6e7a9a7e3915785b421da044a9291d85855daccf3f703370a5096132";
    bins = "minefair"; check = ver "minefair" "1\\.5\\.0"; };
  # obsidian-export (BSD-2-Clause-Patent): export an Obsidian vault to regular Markdown.
  obsidian-export = pkg { vendorHash = "sha256-LhQ0N0yyvllA15a6gxDSJBfXU+VIxH7FsY51Mfg7Igs="; pname = "obsidian-export"; version = "25.3.0"; src = gh "zoni/obsidian-export" "v25.3.0" "1649e066741c2a9fa009799d2635bf6867646f34f5ed402b7909b432b11cca70";
    bins = "obsidian-export"; check = ver "obsidian-export" "25\\.3\\.0"; };
  # tex-fmt (MIT): a LaTeX formatter.
  tex-fmt = pkg { vendorHash = "sha256-T1CokFaug9P7rcbhMyEgDK+CIj4q+qTwBEFIcaYo1XY="; pname = "tex-fmt"; version = "0.5.7"; src = gh "WGUNDERWOOD/tex-fmt" "refs/tags/v0.5.7" "fee9ccd8f13be00cf437ce73928892eb0b55349bd4c81e226bc3fd3cb9de644c";
    bins = "tex-fmt"; man = ''mkdir -p "$out/share/man/man1" && cp man/tex-fmt.1 "$out/share/man/man1/"''; check = ver "tex-fmt" "0\\.5\\.7"; };
  # fastmod (Apache-2.0): utility that makes sweeping changes to large, shared code bases.
  fastmod = pkg { vendorHash = "sha256-v+QWpaYrSUGl5Jwksy8Mey6QEgxKdPJ1a9dc3rYbr88="; pname = "fastmod"; version = "0.4.4"; src = gh "facebookincubator/fastmod" "v0.4.4" "b438cc7564ef34d01f27cdd3cd50ee66a9915b9c50939ca021c6bee2e9c1f069";
    bins = "fastmod"; check = ver "fastmod" "0\\.4\\.4"; };
  # rust-script (MIT OR Apache-2.0): run Rust files and expressions as scripts without any setup or compilation step.
  rust-script = pkg { vendorHash = "sha256-YHPh53v+mIq9AQbvuIwW1JxfY2dJcP0aZxNnUV/64ZM="; pname = "rust-script"; version = "0.36.0"; src = gh "fornwall/rust-script" "0.36.0" "9b6d04ad4dd34838c1b55a8ec4b69e8d7f3008a67d85ef1c35b49502c359b6d8";
    bins = "rust-script"; check = ver "rust-script" "0\\.36\\.0"; };
  # svgbob (Apache-2.0): convert your ascii diagram scribbles into happy little SVG.
  svgbob = pkg { vendorHash = "sha256-90orEsaRNL7ge0peHvMU6TMJhbpjiqMEWy5Iv7t1vtM="; pname = "svgbob"; version = "0.7.6"; src = crate "svgbob_cli" "0.7.6" "6470b0303c95dbc84977e65e976ad730b27aaea2d1318b6f9add12c1c1da1f30";
    bins = "svgbob_cli"; man = ''mv "$out/bin/svgbob_cli" "$out/bin/svgbob"''; check = ver "svgbob" "0\\.7\\.6"; };
  # lspmux (EUPL-1.2): share one language server instance between multiple LSP clients to save resources.
  lspmux = pkg { vendorHash = "sha256-xEXaceX+0Uw+dytBJ6ud0bJlFVQkh3Z/xBk+E4LgWSc="; pname = "lspmux"; version = "0.3.0"; src = cb "p2502/lspmux" "v0.3.0" "28caab4a2f74dc4b8117ac5eed3af2b30258eab1affb47f47363afece0982243";
    bins = "lspmux"; check = ver "lspmux" "0\\.3\\.0"; };
  # chirpstack-packet-multiplexer (MIT): forward Semtech packet-forwarder data to multiple servers.
  chirpstack-packet-multiplexer = pkg { vendorHash = "sha256-m6knKJRyFk76PZdncJyPDarPbZ5FFjVhMEiTs7wB4sQ="; pname = "chirpstack-packet-multiplexer"; version = "4.0.1"; src = gh "chirpstack/chirpstack-packet-multiplexer" "refs/tags/v4.0.1" "709903b039e7aa28a854b97e3a590970e38d450b842440f72e37843133dbe0a4";
    bins = "chirpstack-packet-multiplexer"; check = ver "chirpstack-packet-multiplexer" "4\\.0\\.1"; };
  # svd2rust (MIT OR Apache-2.0): generate Rust register maps (`struct`s) from SVD files.
  svd2rust = pkg { vendorHash = "sha256-QPhJi2xDMZcbDWVgCHT6c0I6av0ONeXLLDYno7l5I9o="; pname = "svd2rust"; version = "0.37.1"; src = crate "svd2rust" "0.37.1" "1eaf6a040bfbc04e7b946a6a373b24aab09e1feb875bb0e20c929946c4b7bfc4";
    bins = "svd2rust"; check = ver "svd2rust" "0\\.37\\.1"; };
  # bttf (Unlicense OR MIT): command line tool for datetime arithmetic, parsing, formatting and more. Replacement for biff.
  bttf = pkg { vendorHash = "sha256-9Iiuy2i0ezkDeLwMCxhmjXea9aaVFfBmW3xo2sRWFnI="; pname = "bttf"; version = "0.1.4"; src = gh "BurntSushi/bttf" "refs/tags/0.1.4" "21b265959403c02406137adac1012f676a25ad67d6fbf29a553b9e459c7bbc73";
    bins = "bttf"; check = ver "bttf" "0\\.1\\.4"; };
  # changelogging (MIT): CLI tool for building changelogs from fragments.
  changelogging = pkg { vendorHash = "sha256-VivT2h/bP6twSKsTS8N/6pGMhFRKoo8ii291UvnBLOQ="; pname = "changelogging"; version = "0.7.0"; src = crate "changelogging" "0.7.0" "6fcfa4129ca45df8051b9db1f025d2c2062bf1ff5c6b8b0808235da707fce729";
    bins = "changelogging"; check = ver "changelogging" "0\\.7\\.0"; };
  # cargo-pretty (MIT): cargo build wrapper with a live, animated status view.
  cargo-pretty = pkg { vendorHash = "sha256-LZ1bVTnRJRHr3bdQNBM7CLxnnriiXdPFVIrDdIO0rQM="; pname = "cargo-pretty"; version = "0.3.1"; src = gh "romancitodev/cargo-pretty" "refs/tags/v0.3.1" "06670be4226531feb0f0fb7c77b65d9a0e853309cea3f21132f0eff2fd56fb75";
    bins = "cargo-pretty"; check = chk ''"$out/bin/cargo-pretty" --version'' "No such device or address"; };
  # flavours (MIT): easy to use base16 scheme manager/builder that integrates with any workflow.
  flavours = pkg { vendorHash = "sha256-8bDD3VAy3pVtKBVIIsmYSLTCk1IDlcefDZosece/nhQ="; pname = "flavours"; version = "0.7.1"; src = gh "Misterio77/flavours" "v0.7.1" "207002728cc270d92f4cd437384925e767c611d30520ec8a29816dfe600d7f61";
    bins = "flavours"; check = ver "flavours" "0\\.7\\.1"; };
  # precious (MIT OR Apache-2.0): one code quality tool to rule them all.
  precious = pkg { vendorHash = "sha256-fq1kJdHF+mhZr0GkJHWI2sio7+m9Z0dmX4dE7HBBL4c="; pname = "precious"; version = "1.0.0"; src = gh "houseabsolute/precious" "refs/tags/v1.0.0" "2de1f5ed8d9013065577d51e6ec3762e6cb1db7aff20e0495f312416728e2e07";
    bins = "precious"; check = ver "precious" "1\\.0\\.0"; };
  # t-lang (MIT): text processing language and utility (its Cargo.toml says 0.1.0).
  t-lang = pkg { vendorHash = "sha256-bJUV8K3hTgvgeh34D6swAFDuvb92jAfuw2pnkaBk1As="; pname = "t-lang"; version = "0.3.1"; src = gh "alecthomas/t" "refs/tags/v0.3.1" "e7b357b358e910171d0e273ae4fd2d34abb29a2a326c33dad076b607ac0f5f91";
    bins = "t"; check = chk ''"$out/bin/t" --version'' "^parse error: unexpected character"; };
  # ttyper (MIT): terminal-based typing test.
  ttyper = pkg { vendorHash = "sha256-mUzAZn5JKDRLE7kiEk57AqmLZq+ka1u5oaWDI7GpLm0="; pname = "ttyper"; version = "1.6.0"; src = gh "max-niederman/ttyper" "v1.6.0" "f7e4ff2f803483b17f35aa0c02977326a0546a95f5b465b4dd34ff17e45b4021";
    bins = "ttyper"; check = ver "ttyper" "1\\.6\\.0"; };
  # uwu-colors (Unlicense): simple LSP server made to display colors via textDocument/documentColor.
  uwu-colors = pkg { vendorHash = "sha256-yeVIX3sT5Ana0yRzZ8tCMPNrQgS/h3wUHWa0gMm6JfI="; pname = "uwu-colors"; version = "0.4.0"; src = cb "q60/uwu_colors" "refs/tags/0.4.0" "54fd1298af43e5665957eed4dec69df3bc8c5908591bbea4cb6501070c838d42";
    bins = "uwu_colors"; check = ver "uwu_colors" "0\\.4\\.0"; };
  # git-upstream (MIT): shortcut for `git push --set-upstream`.
  git-upstream = pkg { vendorHash = "sha256-1kJYCJ9yPoKZwUhf1tn0/fHSKNr8b8evZ++QlvK1Pmo="; pname = "git-upstream"; version = "1.6.0"; src = gh "9999years/git-upstream" "refs/tags/v1.6.0" "9a0867fbdbdc80a1c7c0a0c3462994137a930207b2d92b55e39d864a727cc8c5";
    bins = "git-upstream"; check = ver "git-upstream" "1\\.6\\.0"; };
  # kdlfmt (MIT): formatter for kdl documents.
  kdlfmt = pkg { vendorHash = "sha256-RUanUCOlcjclwEYCw9WaWfJkFud8TGGLT+O6dzVuXyo="; pname = "kdlfmt"; version = "0.1.7"; src = gh "hougesen/kdlfmt" "refs/tags/v0.1.7" "a3d3487d382af8b7372bec21a67e54f92f4674c31f9f781093d3c0ad3f08fc80";
    bins = "kdlfmt"; check = ver "kdlfmt" "0\\.1\\.7"; };
  # md-lsp (MIT): language server implementation for markdown files made in Rust.
  md-lsp = pkg { vendorHash = "sha256-DFLA4rkeePV2qopfp9hjkEmxhr6HjR+6c65m1jZba1c="; pname = "md-lsp"; version = "0.1.1"; src = gh "matkrin/md-lsp" "refs/tags/v0.1.1" "a103a2a98f6e4951ab8b3aa65ecec5b76bac1838c301fe96bcef8d0a7faa37ec";
    bins = "md-lsp"; check = ver "md-lsp" "0\\.1\\.1"; };
  # pastel (MIT OR Apache-2.0): command-line tool to generate, analyze, convert and manipulate colors.
  pastel = pkg { vendorHash = "sha256-/zuC1Z4ETlvikEqlUOvAaIidoTla7y8Xo+q+dh8krVE="; pname = "pastel"; version = "0.12.0"; src = gh "sharkdp/pastel" "v0.12.0" "2903853f24d742fe955edd9bea17947eb8f3f44000a8ac528d16f2ea1e52b78b";
    bins = "pastel"; check = ver "pastel" "0\\.12\\.0"; };
  # microserver (MIT): simple ad-hoc server with SPA support.
  microserver = pkg { vendorHash = "sha256-QAx6D9J0IhcgTW3IZ4p8w9qUybFW2ZebysznzNG1j+g="; pname = "microserver"; version = "0.2.1"; src = gh "robertohuertasm/microserver" "v0.2.1" "9a2b4acf0db61717f1c57376a9f660c27ac485d3d47effc6febda2af67be6ac7";
    bins = "microserver"; check = ver "microserver" "0\\.2\\.1"; };
  # deff (MIT): side-by-side review of git diffs in the terminalnting.
  deff = pkg { vendorHash = "sha256-zLYooFE22FrEDD1SX6Gd1SrqE6HD+J5x0fp8ZvWSN8Q="; pname = "deff"; version = "0.4.2"; src = gh "flamestro/deff" "refs/tags/v0.4.2" "bc85896b93ecec2afe9fbe3cddb8d9f8e520b07fededa80b437dca58caec6f3b";
    bins = "deff"; check = chk ''"$out/bin/deff" --version'' "^Usage: deff"; };
  # sizelint (MIT): lint your file tree based on file sizes.
  sizelint = pkg { vendorHash = "sha256-uJDbjwDfWEFugprdjrshK4micTlmFO8Rwrrrl5hazsM="; pname = "sizelint"; version = "0.1.6"; src = gh "a-kenji/sizelint" "refs/tags/v0.1.6" "742710d5540230e553cb3288e62aecdfabc89916ba1d9bae71787fb9a214928b";
    bins = "sizelint"; check = ver "sizelint" "0\\.1\\.6"; };
  # volt (MIT): ergonomic terminal settings editor for the Amp coding agent (its Cargo.toml says 0.1.0).
  volt = pkg { vendorHash = "sha256-QR447RSpMqV7tJKBRiQm8LuDyK1/LGjlC55Rl2mtKxY="; pname = "volt"; version = "1.5.1"; src = gh "hqnna/volt" "refs/tags/v1.5.1" "b0acea190f6a28b1902cd4a38864305df69fc8ca82c5ec1aef37ec57b42f3573";
    bins = "volt"; check = ver "volt" "0\\.1\\.0"; };
  # tomlq (MIT): tool for getting data from TOML files on the command line.
  tomlq = pkg { vendorHash = "sha256-QVPbvJhII0H1jvxIFTKle8lKcMajcPTjjjeurJTNIyY="; pname = "tomlq"; version = "0.2.2"; src = gh "cryptaliagy/tomlq" "refs/tags/0.2.2" "2a9cff8827dd0d3213470e9a333645492c4d8fe0a733439cc42db4c7b1fc6292";
    bins = "tq"; check = ver "tq" "0\\.2\\.2"; };
  # shellclear (Apache-2.0): secure shell history commands by finding sensitive data.
  shellclear = pkg { vendorHash = "sha256-ZrJerL+C9p7TwZp3xAVZQMyTrg3seZjV7w8w2pjgS7c="; pname = "shellclear"; version = "0.4.8"; src = gh "rusty-ferris-club/shellclear" "refs/tags/v0.4.8" "423cbaf41c5071d41e72a168fcd542f86310e61e061b81b6c0a0be7f136c56e3";
    pkg = "shellclear"; bins = "shellclear"; check = ver "shellclear" "0\\.4\\.8"; };
  # tuckr (GPL-3.0-or-later): super powered replacement for GNU Stow.
  tuckr = pkg { vendorHash = "sha256-kHA61MSwry55pQYKEJE5dMJVlexii3Q/WxTjsA9+nQc="; pname = "tuckr"; version = "0.13.1"; src = gh "RaphGL/Tuckr" "0.13.1" "4b3bdc51e5de5961d89021f28e5aa1ae976fe37330ffafaa5042ed7d6ee2c7c7";
    bins = "tuckr"; check = ver "tuckr" "0\\.13\\.1"; };
  # newdoc (GPL-3.0-or-later): generate pre-populated module files formatted with AsciiDoc.
  newdoc = pkg { vendorHash = "sha256-Pb7/JX215a6/Eh3JCgLLiplsmkto5ZIt+FIN1wF7R4E="; pname = "newdoc"; version = "2.18.7"; src = gh "redhat-documentation/newdoc" "refs/tags/v2.18.7" "cf67e8eb3c5496e4611f795e7134110e9f634852218192627f1d9620200d8783";
    bins = "newdoc"; check = ver "newdoc" "2\\.18\\.7"; };
  # sig (MIT): interactive grep (for streaming).
  sig = pkg { vendorHash = "sha256-WI6wnPk8GqxVIdU5pHDQzjnbt9+sDcecUYGc+q5BxaY="; pname = "sig"; version = "0.3.0"; src = gh "ynqa/sig" "v0.3.0" "dddd088437bed79432642d88782126ea23062ad52752eabb7724d32686db2d8b";
    bins = "sig"; check = ver "sig" "0\\.3\\.0"; };
  # color-lsp (MIT): a document colour language server supporting HEX, RGB, HSL, and named colors.
  color-lsp = pkg { vendorHash = "sha256-1ieJ3H+ADijL3nRtxWmlMe4vS4G2zAvevaOdNsUe5KE="; pname = "color-lsp"; version = "0.3.0"; src = gh "huacnlee/color-lsp" "v0.3.0" "20ba8dd970d6d1dd15b96d31670a6202a42e76fedb2f390080dae686421a11b7";
    pkg = "color-lsp"; bins = "color-lsp"; check = ver "color-lsp" "0\\.3\\.0"; };
  # nbping (MIT): ping with live charts in the terminal.
  nbping = pkg { vendorHash = "sha256-tS8W69AmfWTdQ/ZsDFNeL9f0jNALND691CC7X9UogEw="; pname = "nbping"; version = "0.7.1"; src = gh "hanshuaikang/NBping" "refs/tags/v0.7.1" "1a73f125601cac5ddc456b15d58b5145b859c46da24ce2024288fe4343050e5d";
    bins = "nbping"; check = ver "nbping" "0\\.7\\.1"; };
  # strace-tui (MIT OR Apache-2.0): explore strace output in a TUI.
  strace-tui = pkg { vendorHash = "sha256-GjU7/co740Ehwd5TbTowJCTx9ATP3U1wMJR+MwZ18QE="; pname = "strace-tui"; version = "1.0.1"; src = gh "Rodrigodd/strace-tui" "refs/tags/v1.0.1" "da3ee283c3e293392ddba9a8608c5fe045537ae700c34b4582fedefa5bd808dd";
    bins = "strace-tui"; check = chk ''"$out/bin/strace-tui" --version'' "^Usage: strace-tui <COMMAND>"; };
  # ginko (MIT): device-tree source parser, analyzer and language server.
  ginko = pkg { vendorHash = "sha256-WzfdK0mIq09GvdHUlRgrOkHyPKoeOet8M6KZQyldq9E="; pname = "ginko"; version = "0.0.8"; src = gh "Schottkyc137/ginko" "refs/tags/v0.0.8" "cf70dce67a0e3d4f759eb29952096bb9b0a4e46d3438059ba425eca2fc7a2d47";
    bins = "ginko ginko_ls"; check = ver "ginko" "0\\.0\\.8"; };
  # cargo-chef (Apache-2.0 OR MIT): cargo-subcommand to speed up Rust Docker builds using Docker layer caching.
  cargo-chef = pkg { vendorHash = "sha256-o1VW7A+W+bnsaLg4/Pvz1ShKMR0cNpalC1Tib0vImzw="; pname = "cargo-chef"; version = "0.1.78"; src = crate "cargo-chef" "0.1.78" "ada7988681f22918824509059546e0f7bc937eef4f857e30e23d871fa2ef76fc";
    bins = "cargo-chef"; check = chk ''"$out/bin/cargo-chef" chef --version; "$out/bin/cargo-chef" --version'' "0\\.1\\.78"; };
  # envoluntary (MIT): automatic Nix development environments for your shell.
  envoluntary = pkg { vendorHash = "sha256-9dKtdp6f46oNDKVjE1igdisl89u30EKtDKHUcItmOX8="; pname = "envoluntary"; version = "0.1.4"; src = gh "dfrankland/envoluntary" "refs/tags/envoluntary-v0.1.4" "c21fe4efeabcaa4bad4653fb74cb4fe75f279144b081c5b25dede46c502ea401";
    bins = "envoluntary"; check = ver "envoluntary" "0\\.1\\.4"; };
  # tukai (MIT): terminal-based touch typing application.
  tukai = pkg { vendorHash = "sha256-YdkH/VzUgJ1mTVk7weaJOl+AHxVuNfntpTAn0JTKbZY="; pname = "tukai"; version = "0.2.3"; src = gh "hlsxx/tukai" "refs/tags/v0.2.3" "d14ab87bfdfb8312cd12c6f671486ae0afde0036441cf0d1df0f425f7278d9bd";
    bins = "tukai"; check = chk ''"$out/bin/tukai" --version'' "failed to initialize terminal"; };
  # turtle-build (MIT OR Apache-2.0): ninja-compatible build system for high-level programming languages written in Rust.
  turtle-build = pkg { vendorHash = "sha256-k0JZJUaV4LBP8BdMJYaNuVqhRlgus/A4Htt4+ejil6U="; pname = "turtle-build"; version = "0.5.15"; src = gh "raviqqe/turtle-build" "v0.5.15" "62965afe8c17d7bf3fe6122e1f023635c6316f3acd87a3949c6411c9cce10831";
    bins = "turtle"; check = ver "turtle" "0\\.5\\.15"; };
  # sfz (MIT OR Apache-2.0): simple static file serving command-line tool written in Rust.
  sfz = pkg { vendorHash = "sha256-OD6aeoSX3Zg3Z3fGc00AmIfemEEtQXsp7VjCnVhNGnE="; pname = "sfz"; version = "0.7.1"; src = gh "weihanglo/sfz" "v0.7.1" "b9c7f280e08d1c6f4c103ca35ed289bdc004a9773e0af44f39bf7530d2f46602";
    bins = "sfz"; check = ver "sfz" "0\\.7\\.1"; };
  # metapac (GPL-3.0-or-later): multi-backend declarative package manager.
  metapac = pkg { vendorHash = "sha256-t4JxQ07YTwZ9+8mAE+/2D528DyN4joZXMSBgT/qjbfs="; pname = "metapac"; version = "0.10.2"; src = gh "ripytide/metapac" "refs/tags/v0.10.2" "066736aaa87988d833a01ecbe285c12f647b1a222731cdb7c739279aecc80546";
    bins = "metapac"; check = ver "metapac" "0\\.10\\.2"; };
  # git-gone (EUPL-1.2): cleanup stale Git branches of merge requests.
  git-gone = pkg { vendorHash = "sha256-2nleedX9eycbIvdnnddBl/VdtHal0tIcNLUOsCS8+a4="; pname = "git-gone"; version = "1.3.1"; src = cb "swsnr/git-gone" "refs/tags/v1.3.1" "7db6465c4b4026d57fd1507ed48346f837a8cd92db01746b63470c8efbf9a68f";
    bins = "git-gone"; check = ver "git-gone" "1\\.3\\.1"; };
  # egglog (MIT): a fixpoint reasoning system unifying Datalog and equality saturation (its bin needs the default "bin" feature).
  egglog = pkg { vendorHash = "sha256-iO98AEC8oje1hseCinC+Z0M0bbRnOpLKr/q0IKtVCrs="; pname = "egglog"; version = "0.4.0"; src = gh "egraphs-good/egglog" "v0.4.0" "9cbce5886daf770a1e2d699701dad3d61c8e5b3b0d6b9707e9e7080234d6a761";
    bins = "egglog"; check = ver "egglog" "0\\.4\\.0"; };
  # nerdfix (MIT OR Apache-2.0): helps you to find/fix obsolete nerd font icons in your project.
  nerdfix = pkg { vendorHash = "sha256-Hh9sEb+mJ/gf/uNaVA+xXTxCpu9hCFlYUM38LdIVwdY="; pname = "nerdfix"; version = "0.4.2"; src = gh "loichyan/nerdfix" "v0.4.2" "e56f648db6bfa9a08d4b2adbf3862362ff66010f32c80dc076c0c674b36efd3c";
    bins = "nerdfix"; check = ver "nerdfix" "0\\.4\\.2"; };
  # pest-ide-tools (Apache-2.0): IDE support for Pest, via the LSP (its Cargo.toml says 0.3.12).
  pest-ide-tools = pkg { vendorHash = "sha256-ARBAz7hZDzgHqMQrf6li+4aI4euAmo9YafzC4kCdP+Q="; pname = "pest-ide-tools"; version = "0.13.2"; src = gh "pest-parser/pest-ide-tools" "v0.13.2" "e46ecd38eba90ea575738a7bd82420ca951894c80dc02e1059e68e4d78199c3a";
    bins = "pest-language-server"; check = ver "pest-language-server" "0\\.3\\.12"; };
  # cargo-rdme (MIT): cargo command to create the README.md from your crate's documentation.
  cargo-rdme = pkg { vendorHash = "sha256-DKj7JkyoOjEVqOB7UsHaUEAM4hajopxDLQwaJQL+LmY="; pname = "cargo-rdme"; version = "2.2.3"; src = crate "cargo-rdme" "2.2.3" "012f23c1c1631027df4500fd0ba02622b25706629029afa6eb30c8779fe27452";
    bins = "cargo-rdme"; check = chk ''"$out/bin/cargo-rdme" rdme --version; "$out/bin/cargo-rdme" --version'' "2\\.2\\.3"; };
  # fsel (BSD-2-Clause): fast TUI app launcher and fuzzy finder for GNU/Linux and *BSD (its Cargo.toml says 3.6.0-kiwicrab).
  fsel = pkg { vendorHash = "sha256-xsqW/n0pIVayF4ysPQJYWPjLPwVNN1bNV5+rBR5kz7A="; pname = "fsel"; version = "3.6.0"; src = gh "Mjoyufull/fsel" "refs/tags/3.6.0" "04e17dd71a16a51c5927e1473f741d1539bfcbd8c47d9fb513d6e453e296068f";
    bins = "fsel"; man = ''mkdir -p "$out/share/man/man1" && cp fsel.1 "$out/share/man/man1/"''; check = ver "fsel" "3\\.6\\.0\\-kiwicrab"; };
  # sneakerweb (MIT OR Apache-2.0): a parallel web carried on physical media.
  sneakerweb = pkg { vendorHash = "sha256-R157kh077dQyVfs87f+ICdKULpKxpj8wevRBMfE38W4="; pname = "sneakerweb"; version = "1.0.1"; src = cb "worm-blossom/sneakerweb" "5b26074b7db7bd5c5200b2ad5263cd79b29134e6" "16c389cd1b76f61284c4be3ba552e69b647a7a8348b177763600953fef72b0fb";
    bins = "sneakerweb"; check = ver "sneakerweb" "1\\.0\\.1"; };
  # cargo-bazel (Apache-2.0): part of the `crate_universe` collection of tools which use Cargo to generate build targets for Bazel.
  cargo-bazel = pkg { vendorHash = "sha256-RgSzc8jaLQ4dfslSDW8ncFMOAxh9+noVh5+np3kLl8U="; pname = "cargo-bazel"; version = "0.17.0"; src = crate "cargo-bazel" "0.17.0" "e2f5d8136d5b223dae2908fb7dfe55b383271bac4ec9fd043426dbd8dd7997ba";
    bins = "cargo-bazel"; check = chk ''"$out/bin/cargo-bazel" bazel --version; "$out/bin/cargo-bazel" --version'' "0\\.17\\.0"; };
  # cargo-cyclonedx (Apache-2.0): creates CycloneDX Software Bill of Materials (SBOM) from Rust (Cargo) projects.
  cargo-cyclonedx = pkg { vendorHash = "sha256-7si19eHD9XP9PY+mFk4bPU+RCfWHZyxEmUGaB4P+H54="; pname = "cargo-cyclonedx"; version = "0.5.9"; src = gh "CycloneDX/cyclonedx-rust-cargo" "cargo-cyclonedx-0.5.9" "36f0dbdd203424cdcb2d73d71093a2795494c776ca5ff9039d5002e4b7785da7";
    bins = "cargo-cyclonedx"; check = chk ''"$out/bin/cargo-cyclonedx" cyclonedx --version; "$out/bin/cargo-cyclonedx" --version'' "0\\.5\\.9"; };
  # wit-bindgen (Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT): language binding generator for WebAssembly interface types.
  wit-bindgen = pkg { vendorHash = "sha256-H/Z30zJYhs6QhPmJ3sYS5JpjxJ5ZSVSqnkfcfDn0q8A="; pname = "wit-bindgen"; version = "0.63.0"; src = gh "bytecodealliance/wit-bindgen" "v0.63.0" "077478a50147c75a75fa91bd6a6f3648234679fba44026f6ed4740f3d81d247c";
    bins = "wit-bindgen"; check = ver "wit-bindgen" "0\\.63\\.0"; };
}
