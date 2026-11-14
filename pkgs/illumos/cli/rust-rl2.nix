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
}
