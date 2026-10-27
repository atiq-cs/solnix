# cli/rust.nix -- the Rust CLI tier on rust199 (../cargo.nix cargoPkg). One attr each;
# vendorHash pins the `cargo vendor --locked` FOD. `check` runs the brief's --version check.
{ cargoPkg, chk, extra ? { } }:
let
  gh = repo: tag: sha256: { url = "https://codeload.github.com/${repo}/tar.gz/refs/tags/${tag}"; inherit sha256; };
  fake = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  pkg = a: cargoPkg ({ vendorHash = fake; } // a // (extra.${a.pname} or { }));
in {
  ripgrep = pkg { pname = "ripgrep"; vendorHash = "sha256-+BtD5H3YX3n72yfvaW1Yz/qxFvKLrQS1QMgSiy7CrQU="; version = "15.2.0"; src = gh "BurntSushi/ripgrep" "15.2.0" "7605249d3eb0d5f170e3414498e3344e26b1e7a147aec518b57090b80036a562";
    bins = "rg"; check = chk ''"$out/bin/rg" --version'' "^ripgrep 15\\.2\\.0"; };
  fd = pkg { pname = "fd"; vendorHash = "sha256-Q1AM30C1JGL+Wf8joaNSBewecs6MyzEOtNQv8BpYC58="; version = "10.5.0"; src = gh "sharkdp/fd" "v10.5.0" "e6d9e90730bf316101691e49d59cc02565278dc3779d33a77423801569484851";
    bins = "fd"; check = chk ''"$out/bin/fd" --version'' "^fd 10\\.5\\.0"; };
  bat = pkg { pname = "bat"; vendorHash = "sha256-HmA7PBWn/Be2FED2y5KoCiSoTw6DCCcIZz2OiG4+gZs="; version = "0.26.1"; src = gh "sharkdp/bat" "v0.26.1" "4474de87e084953eefc1120cf905a79f72bbbf85091e30cf37c9214eafcaa9c9";
    bins = "bat"; check = chk ''"$out/bin/bat" --version'' "^bat 0\\.26\\.1"; };
  eza = pkg { pname = "eza"; vendorHash = "sha256-0p9vK9G/qT/gVOC3GIyFLj4CfqI5y871oAnQp5efRG8="; version = "0.23.5"; src = gh "eza-community/eza" "v0.23.5" "bbf179f2611c904014431740b559e8055276c12fcf978a7e31c271663548337f";
    bins = "eza"; check = chk ''"$out/bin/eza" --version'' "v0\\.23\\.5"; };
  du-dust = pkg { pname = "du-dust"; vendorHash = "sha256-/bBhSzHn7v82vhFdN5k0qp3WAdXLLDQjV9mf3Rej72Y="; version = "1.2.6"; src = gh "bootandy/dust" "v1.2.6" "9dd1ec7576d43574e6f48342cb96a5087338b4c308460a848f5895f72ddc3bc9";
    bins = "dust"; check = chk ''"$out/bin/dust" --version'' "^Dust 1\\.2\\.6"; };
  dua = pkg { pname = "dua"; vendorHash = "sha256-n46Or1SQzPC4rcS//gjIPAfT/vd0DZSFvW6dbGZhYCA="; version = "2.46.0"; src = gh "Byron/dua-cli" "v2.46.0" "321e06440a8ba5dd05ecfd78904a127c9ffa556a40d886ab5862a9fe9aa9bd21";
    bins = "dua"; check = chk ''"$out/bin/dua" --version'' "^dua 2\\.46\\.0"; };
  hexyl = pkg { pname = "hexyl"; vendorHash = "sha256-WyfUxqgxcBLQwq5CU8YCYaXDgT/KdAS5X06+nUoxQ1g="; version = "0.17.0"; src = gh "sharkdp/hexyl" "v0.17.0" "72fa17397ad187eec6b295d02c7caabbb209a6e0d5706187b8a599bd5df8615e";
    bins = "hexyl"; check = chk ''"$out/bin/hexyl" --version'' "^hexyl 0\\.17\\.0"; };
  hyperfine = pkg { pname = "hyperfine"; vendorHash = "sha256-ClUuXLXVMqObpCdC8aMvaLRIoZW3pdfjbSNVKnEDmvs="; version = "2.0.0"; src = gh "sharkdp/hyperfine" "v2.0.0" "f4b71df3c78e4cf752ca6fb6ebc4b025f7ea6a5ca5c48fea75f8a1fdb4c7d721";
    bins = "hyperfine"; check = chk ''"$out/bin/hyperfine" --version'' "^hyperfine 2\\.0\\.0"; };
  tokei = pkg { pname = "tokei"; vendorHash = "sha256-wLy8TISNr7VXkb1AfSbonnQkwRguq0hakpOV/7ZCWFE="; version = "15.0.0"; src = gh "XAMPPRocky/tokei" "v15.0.0" "966da7b9a81ac6cb777b9f159f4c02e5b83a8b8bd30ebf5991007839926b600c";
    bins = "tokei"; check = chk ''"$out/bin/tokei" --version'' "^tokei 15\\.0\\.0"; };
  zoxide = pkg { pname = "zoxide"; vendorHash = "sha256-dOVxm17IaX476z6lRxucpR7nMHG0NdzX5SCpj3Exadg="; version = "0.10.0"; src = gh "ajeetdsouza/zoxide" "v0.10.0" "4fcd4272b013a10b637dbcc299c58a9924b94470a9042677ca1a204cc2e9150e";
    bins = "zoxide"; check = chk ''"$out/bin/zoxide" --version'' "^zoxide 0\\.10\\.0"; };
  # procs: NOT BUILT -- its process backend is Linux/macOS/FreeBSD/Windows only (src/process/*.rs;
  # 'unresolved import crate::process::ProcessInfo' on illumos, measured). prstat/ps are the tools here.
  bottom = pkg { pname = "bottom"; vendorHash = "sha256-hijel5yGMt2zxioly0a7Htr1VvODAxZAQfB7Pfv8J+Y="; version = "0.14.9"; src = gh "ClementTsang/bottom" "0.14.9" "1dbb940c763fb583b7e1c7dfa165b73ed9a0ba712e72cc97311c5b1c098d5b72";
    bins = "btm"; check = chk ''"$out/bin/btm" --version'' "^bottom 0\\.14\\.9"; };
  difftastic = pkg { pname = "difftastic"; vendorHash = "sha256-ol2He396GJJ9tE0dm6OaSGe7OLiM6oe58qbdnELSslA="; version = "0.71.0"; src = gh "Wilfred/difftastic" "0.71.0" "d6afd26103c6492a91307dc6779c7dd0ca4d4c85499f81d7dc53fdfa5107331d";
    bins = "difft"; check = chk ''"$out/bin/difft" --version'' "^Difftastic 0\\.71\\.0"; };
  atuin = pkg { pname = "atuin"; vendorHash = "sha256-buZX2s1yC+WroYId+0LhkZmDbNBcQVJ7MvpZBcV50zc="; version = "18.24.2"; src = gh "atuinsh/atuin" "v18.24.2" "dcea434c66185bc6c1359c2f719e2aa89a68c6d1e31ca7a8749e1b593313f93f";
    bins = "atuin"; check = chk ''"$out/bin/atuin" --version'' "^atuin 18\\.24\\.2"; };
  ast-grep = pkg { pname = "ast-grep"; vendorHash = "sha256-WD72XdT6rONvXLCNFz1uuQJSA21B2mLg7COjrNIyoLI="; version = "0.51.0"; src = gh "ast-grep/ast-grep" "0.51.0" "aade9c7059f1588d322dcedc058372325758211bfaa46f7170c097ee9da4b0c7";
    bins = "ast-grep sg"; pkg = "ast-grep"; check = chk ''"$out/bin/ast-grep" --version'' "^ast-grep 0\\.51\\.0"; };
  just = pkg { pname = "just"; vendorHash = "sha256-zl+PJx4OFHgiRbtwYPoLnCGIDDSDInJQc14pQfGLcSU="; version = "1.59.0"; src = gh "casey/just" "1.59.0" "20f876880851f1cc67fc7eb7589c7f7ccaa7612d827feac75797cf4a6ed729aa";
    bins = "just"; check = chk ''"$out/bin/just" --version'' "^just 1\\.59\\.0"; };
  # watchexec: NOT BUILT -- watchexec-supervisor uses nix::sys::wait::waitid + WSTOPPED/WNOWAIT, which the nix crate
  # does not expose for illumos (E0432, measured); needs a nix-crate illumos arm.
  sd = pkg { pname = "sd"; vendorHash = "sha256-RXkYrGnv+6Gh3icK7vDjtFD2cJJWtJR8N2943XEuT9k="; version = "1.1.0"; src = gh "chmln/sd" "v1.1.0" "defdce484f8c92f265e1282490572575028967c2c55d356111d1e49a3ea9a88e";
    bins = "sd"; check = chk ''echo foo-bar | "$out/bin/sd" -- "-bar" "-baz"'' "^foo-baz$"; };  # v1.1.0 tag reports "sd 1.0.0"
  git-delta = pkg { pname = "git-delta"; vendorHash = "sha256-9o0b3FaqheefW+Kiup5H27qIVx1vahEDR1H6pGFlkE4="; version = "0.20.1"; src = gh "dandavison/delta" "0.20.1" "d9d502396e3595ee8fd926f1ed2e54ac9935baabd3569a3753efab36304f90fa";
    bins = "delta"; check = chk ''"$out/bin/delta" --version'' "^delta 0\\.20\\.1"; };
  alejandra = pkg { pname = "alejandra"; vendorHash = "sha256-J5E251bhql0iV3izSkVXLyqmbt1t40/FpfNJff2GDWg="; version = "4.1.0"; src = gh "kamadorueda/alejandra" "4.1.0" "cf74acd0bbbaa166abed6d155f3a6206392d715336e74f9bb5fe05d874de183b";
    bins = "alejandra"; check = chk ''"$out/bin/alejandra" --version'' "^Alejandra 4\\.1\\.0"; };
  statix = pkg { pname = "statix"; vendorHash = "sha256-qg0bwgWRttTymKMWK5fZc/PJcOkfe8yn/hCGawugzro="; version = "0.5.8"; src = gh "oppiliappan/statix" "v0.5.8" "547ee83df5814c18f8577b5ca25a1f12a416900b6eaa95821386a28090e8a89d";
    bins = "statix"; check = chk ''"$out/bin/statix" --version'' "^statix 0\\.5\\.8"; };
  deadnix = pkg { pname = "deadnix"; vendorHash = "sha256-Cjt3Fn/a9U4r9tjiTuX2zbu/jcvMxpnUv+vb2YnIvZs="; version = "1.3.2"; src = gh "astro/deadnix" "v1.3.2" "9706c5e49a36233e0131ed5e1584d4f532aa0d2b27ac4a3ae4187634f3487898";
    bins = "deadnix"; check = chk ''"$out/bin/deadnix" --version'' "^deadnix 1\\.3\\.2"; };
  ruff = pkg { pname = "ruff"; vendorHash = "sha256-mhuxnLVuKRn4RoraXZDfUZ/pwoLRqT9Z3Yqs6OSaUQY="; version = "0.17.3"; src = gh "astral-sh/ruff" "0.17.3" "7281befde89b669bd92231064ceb3d3211d9094e20e6983bb3b92e641b305860";
    bins = "ruff"; pkg = "ruff"; check = chk ''"$out/bin/ruff" --version'' "^ruff 0\\.17\\.3"; };
  uv = pkg { pname = "uv"; vendorHash = "sha256-NtQPhru6KMgFr/TvmudPb9Cpkd0qem+wbYVtdBN8kHk="; version = "0.13.6"; src = gh "astral-sh/uv" "0.13.6" "c2e01687fbbcb109277698ec97baca46e1547656ad580abf6d993f9c459af1c7";
    bins = "uv uvx"; pkg = "uv"; check = chk ''"$out/bin/uv" --version'' "^uv 0\\.13\\.6"; };
  cargo-nextest = pkg { pname = "cargo-nextest"; vendorHash = "sha256-FKHrNK31xkpKGf4IQEt9I8uPL1sqsq20Pr3OtVnddl0="; version = "0.9.150"; src = gh "nextest-rs/nextest" "cargo-nextest-0.9.150" "52daf837e45bf08815f1fa92202adb28d835c04b3e8f1fc9a2d1b47e2b6537c6";
    bins = "cargo-nextest"; pkg = "cargo-nextest"; check = chk ''"$out/bin/cargo-nextest" nextest --version'' "^cargo-nextest 0\\.9\\.150"; };
  # cargo-watch: NOT BUILT -- hard-depends on notify-rust -> zbus, whose unix peer-credentials code has no illumos arm
  # (zbus 4.4 socket/unix.rs E0308, measured). Upstream archived it for watchexec (above).
}
