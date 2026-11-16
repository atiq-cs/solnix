# cli/rust-nc1.nix -- Rust tools the maintainer's nix-config uses that the x86 build queue has jobs for (nc1 lane, 2026-11-15),
# as ./rust-rl2.nix: on cargoPkg (../cargo.nix), pname and version the queue job's, each source pinned by its tarball sha256, its
# `cargo vendor --locked` by our FOD's NAR hash (nixpkgs' cargoHash is for its own fetcher). Build flags nixpkgs f4a03c0's.
# A new file: no served drv moves. Binaries only: nixpkgs' postInstall (completions, man pages) is not ported.
{ cargoPkg, chk, openssl }:
let
  gh = repo: ref: sha256: { url = "https://codeload.github.com/${repo}/tar.gz/${ref}"; inherit sha256; };
  crate = n: v: sha256: { url = "https://static.crates.io/crates/${n}/${v}/download"; inherit sha256; };
  fake = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  pkg = a: cargoPkg ({ vendorHash = fake; } // a);
  # `<bin> --version` must print the version (the in-build check)
  ver = bin: re: chk ''"$out/bin/${bin}" --version'' re;
  # openssl-sys: the store openssl (lib/amd64), not a probe of the host (as rust-extra.nix's atuin)
  sslEnv = ''export CFLAGS="-D__illumos__" OPENSSL_DIR=${openssl} OPENSSL_LIB_DIR=${openssl}/lib/amd64 OPENSSL_INCLUDE_DIR=${openssl}/include'';
in {
  # cargo-flamegraph (MIT OR Apache-2.0): flame graphs from perf/dtrace samples, plus the cargo subcommand.
  cargo-flamegraph = pkg { vendorHash = "sha256-BlMcvwWmDWMqSR3oWEOITCfTs/RQaybm32XMXT/1jf0="; pname = "cargo-flamegraph"; version = "0.6.14"; src = gh "flamegraph-rs/flamegraph" "v0.6.14" "c379e26dfacd4c7439456e488457b7f1cb651687c0eb596f4acd1964c6ffbd82";
    bins = "cargo-flamegraph flamegraph"; check = ver "flamegraph" "0\\.6\\.14"; };
  # cargo-llvm-cov (Apache-2.0 OR MIT): source-based code coverage for cargo. The crates.io tarball: the git tag has no Cargo.lock.
  cargo-llvm-cov = pkg { vendorHash = "sha256-4i+3QK8MMCG8JG13+44NpSfK23fv1VF2ST2xw1oscM0="; pname = "cargo-llvm-cov"; version = "0.9.0"; src = crate "cargo-llvm-cov" "0.9.0" "cc4d894e2ff02b503a59b14c17bf1e9939a8a9a8f9dae38245f9acfccb12b7d5";
    bins = "cargo-llvm-cov"; check = chk ''"$out/bin/cargo-llvm-cov" llvm-cov --version'' "0\\.9\\.0"; };
  # comma (MIT): run a program from nixpkgs without installing it.
  comma = pkg { vendorHash = "sha256-EUTO/W2+LdAlRF6oQoVQDDzCuYlUxuIWjyKTONZtN/c="; pname = "comma"; version = "2.4.2"; src = gh "nix-community/comma" "refs/tags/v2.4.2" "e1e185671c34f5361320dcf881dc01ad51714d6d776e20d08fa41bd0fd5d5707";
    bins = "comma"; check = ver "comma" "2\\.4\\.2"; };
  # diffsitter (MIT): a tree-sitter based AST diff. nixpkgs' features: dynamic-grammar-libs only (grammars loaded at run time).
  diffsitter = pkg { vendorHash = "sha256-kPoKwW9HoUjf9oJOTinJ/mad/10KYQa/3GrrHC2f4bo="; pname = "diffsitter"; version = "0.8.4"; src = gh "afnanenayet/diffsitter" "v0.8.4" "3440e9e1c4e2e359092ec1cc35812d53efe9e56535148af140bbb131c59b500c";
    noDefault = true; features = "dynamic-grammar-libs";
    bins = "diffsitter diffsitter-utils diffsitter_completions"; check = ver "diffsitter" "0\\.8\\.4"; };
  # dust (Apache-2.0): du with a tree view (crate du-dust).
  dust = pkg { vendorHash = "sha256-/bBhSzHn7v82vhFdN5k0qp3WAdXLLDQjV9mf3Rej72Y="; pname = "dust"; version = "1.2.6"; src = gh "bootandy/dust" "refs/tags/v1.2.6" "9dd1ec7576d43574e6f48342cb96a5087338b4c308460a848f5895f72ddc3bc9";
    bins = "dust"; check = ver "dust" "1\\.2\\.6"; };
  # git-absorb (BSD-3-Clause): git commit --fixup for the right commits, automatically.
  git-absorb = pkg { vendorHash = "sha256-T+XJ1SabeeNhIZFZ5ZWfSr2346JR4EOesvSBfB0jUu0="; pname = "git-absorb"; version = "0.9.0"; src = gh "tummychow/git-absorb" "refs/tags/0.9.0" "a0f74e6306d7fbd746d2b4a6856621d46a7f82e3e88b6bb8b6fc0480cf811f53";
    bins = "git-absorb"; check = ver "git-absorb" "0\\.9\\.0"; };
  # hyfetch (MIT): neofetch with pride flags.
  hyfetch = pkg { vendorHash = "sha256-8gaHzYQr7sAgUfKk152K52xVMkwm0QVy7PCuqdqJ0Ew="; pname = "hyfetch"; version = "2.1.0"; src = gh "hykilpikonna/hyfetch" "refs/tags/2.1.0" "23e3600093de3daa60dbbfd1edff258504f41f0fcfcb5537ddff78711b0d2eb2";
    bins = "hyfetch"; check = ver "hyfetch" "2\\.1\\.0"; };
  # nurl (MPL-2.0): generate Nix fetcher calls from repository URLs.
  nurl = pkg { vendorHash = "sha256-/Udk8hvOo0eVhEPEPMX6dCqgBIMK2sPsHGL8sIBbNz8="; pname = "nurl"; version = "0.4.1"; src = gh "nix-community/nurl" "refs/tags/v0.4.1" "e20eb33363aff598e4a485b0b32e1c527a6ad5a1abf78405509f84ae536610be";
    bins = "nurl"; check = ver "nurl" "0\\.4\\.1"; };
  # rust-analyzer (MIT OR Apache-2.0): the Rust language server. nixpkgs: the two bins, CFG_RELEASE = the version.
  rust-analyzer = pkg { vendorHash = "sha256-x/DP61juaJhJue52AMUNghuRrrRxFZL5mpJ3vmkn7+A="; pname = "rust-analyzer"; version = "2026-10-26"; src = gh "rust-lang/rust-analyzer" "2026-10-26" "de34f04868d5814b77964f380f21585915786ba46e15cf8606c7f60ab5f63204";
    env = "export CFG_RELEASE=2026-10-26";
    bins = "rust-analyzer rust-analyzer-proc-macro-srv"; check = ver "rust-analyzer" "2026-10-26"; };
  # stylua (MPL-2.0): a Lua code formatter. nixpkgs' features: lua54 luajit luau.
  stylua = pkg { vendorHash = "sha256-vxEUfEVhReEbneewdMoSWo4VqRsTSwwZu3y+HR5NRWs="; pname = "stylua"; version = "2.6.0"; src = gh "johnnymorganz/stylua" "v2.6.0" "d58083b5d453df38b5c78c6839e80b256b434eb7d4aca3f529a1972b6c9115ac";
    features = "lua54,luajit,luau"; bins = "stylua"; check = ver "stylua" "2\\.6\\.0"; };
  # taplo (MIT): a TOML toolkit (cli, formatter, lsp). nixpkgs: crates/taplo-cli, no default features + completions lint native-tls toml-test lsp.
  taplo = pkg { vendorHash = "sha256-eLXQVvca1Q4/fnQFKI0uNq6sPhXKfP2s9JlpZajIQ/E="; pname = "taplo"; version = "0.10.0"; src = gh "tamasfe/taplo" "refs/tags/release-taplo-cli-0.10.0" "eaec8435bfb5ccd89f7b4dd09385b6be25c2ff00aa25417cb82c88a59d4ccde0";
    pkg = "taplo-cli"; noDefault = true; features = "completions,lint,native-tls,toml-test,lsp"; env = sslEnv; libs = [ openssl ];
    bins = "taplo"; check = ver "taplo" "0\\.10\\.0"; };
}
