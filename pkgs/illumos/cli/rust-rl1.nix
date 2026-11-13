# cli/rust-rl1.nix -- Rust leaves the x86 build queue has jobs for (rl1 lane, 2026-11-13): nixpkgs f4a03c0 by-name attrs whose only
# missing input was rustPlatform (idle1 byname.tsv). On cargoPkg (../cargo.nix) as ./rust.nix: pname and version are the queue job's,
# each source pinned by its tarball sha256 (its unpacked tree's NAR hash = nixpkgs' src hash, checked), its `cargo vendor --locked`
# by our FOD's NAR hash (nixpkgs' cargoHash is for its own fetcher). Build flags nixpkgs'. A new file: no served drv moves.
{ cargoPkg, chk }:
let
  gh = repo: ref: sha256: { url = "https://codeload.github.com/${repo}/tar.gz/${ref}"; inherit sha256; };
  cb = repo: ref: sha256: { url = "https://codeberg.org/${repo}/archive/${ref}.tar.gz"; inherit sha256; };
  crate = n: v: sha256: { url = "https://static.crates.io/crates/${n}/${v}/download"; inherit sha256; };
  fake = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  pkg = a: cargoPkg ({ vendorHash = fake; } // a);
  # onig_sys (oniguruma, C) calls alloca() without <alloca.h>, which illumos does not pull in (as rust-extra.nix's bat).
  alloca = ''export CFLAGS="-include alloca.h"'';
  # font-awesome-as-a-crate 0.3.1's build.rs writes one match arm per SVG in read_dir order (on ZFS a fresh unpack lists a directory
  # in another order) and walks a std HashMap (per-process random): mdbook's --check DIFFERED in fontawesome_svg's .text and its
  # .rodata (rl1, measured). Sort the entries and use a BTreeMap: the same source then generates the same code.
  faFix = ''
    vfix font-awesome-as-a-crate build.rs "'    collections::HashMap,'" "'    collections::BTreeMap as HashMap,'"
    vfix font-awesome-as-a-crate build.rs "'        let dir = read_dir(Path::new(\"fontawesome-free-6.2.0-desktop/svgs\").join(dirname)).unwrap();'" "'        let mut dir: Vec<_> = read_dir(Path::new(\"fontawesome-free-6.2.0-desktop/svgs\").join(dirname)).unwrap().collect();\n        dir.sort_by_key(|e| e.as_ref().map(|e| e.file_name()).ok());'"
  '';
in {
  # mdbook (MPL-2.0): books from Markdown (the Rust book's tool).
  mdbook = pkg { vendorHash = "sha256-eG1yULnAulYrgaKA6t2UndYk4yOugISOu5XXRKwH5QE="; pname = "mdbook"; version = "0.5.4"; src = gh "rust-lang/mdBook" "refs/tags/v0.5.4" "107614330c35c77d53b6f6ce7826c50eed087650efe5646a4d0a16ca6bf5544b";
    bins = "mdbook"; prep = faFix; check = chk ''"$out/bin/mdbook" --version'' "^mdbook v0\\.5\\.4"; };
  # uutils-findutils (MIT): find, xargs, locate, updatedb in Rust (nixpkgs drops the testing-commandline helper: not built here).
  uutils-findutils = pkg { vendorHash = "sha256-wylAAEcMHApujpgenZ6bcfeyaC5LuITPW2dg0T01gEc="; pname = "uutils-findutils"; version = "0.10.0"; src = gh "uutils/findutils" "refs/tags/0.10.0" "e36ae3937f889bc59cfbd65820a642baa695c58d7fa1e387e41857e710f40419";
    bins = "find locate updatedb xargs"; env = alloca;
    check = chk ''cd "$W" && mkdir -p fchk/sub && : > fchk/sub/x && "$out/bin/find" fchk -name x && "$out/bin/find" --version'' "^fchk/sub/x$"; };
  # uutils-sed (MIT): sed in Rust.
  uutils-sed = pkg { vendorHash = "sha256-39ukvMYzBcSiRZicstlHUwaiDLxVNSQAVMuTHD9ReEQ="; pname = "uutils-sed"; version = "0.3.0"; src = gh "uutils/sed" "refs/tags/0.3.0" "d879d292ff93f4f769f299fb183be69d3ea6bcedeb2a698d944595ebc3a8dd6c";
    bins = "sed"; check = chk ''echo foo-bar | "$out/bin/sed" s/bar/baz/'' "^foo-baz$"; };
  # faketty (MIT OR Apache-2.0): run a command in a pty even when its output is redirected.
  faketty = pkg { vendorHash = "sha256-OA+qJKt3H29SaS9ATl8qC8FbeXeXy1OgsNxZQ1o6WpY="; pname = "faketty"; version = "1.0.20"; src = crate "faketty" "1.0.20" "c7784ee4aa634644743b5d83f93cc43a49286fe118842ba1ff5efa404a5b30b1";
    bins = "faketty"; check = chk ''"$out/bin/faketty" /usr/bin/sh -c "test -t 1 && echo on-a-tty"'' "^on-a-tty"; };
  # mandown (MIT OR Apache-2.0): Markdown to groff man pages.
  mandown = pkg { vendorHash = "sha256-zWMZ0B/Si27qTApfc4biH6ewMpVo4tMoXjh8MI9qU1c="; pname = "mandown"; version = "1.1.0"; src = crate "mandown" "1.1.0" "9edef1e8731732e8977534921abcef085c2308096092e7294b1bb2629589908f";
    bins = "mandown"; check = chk ''printf "# NAME\n\nhello\n" > "$W/t.md" && "$out/bin/mandown" "$W/t.md" T 1'' "^\\.TH "; };
  # rtss (MIT): relative timestamps on a command's stdout/stderr lines.
  rtss = pkg { vendorHash = "sha256-wLa02bHt8UREYh2/mtaMxepgg75Wva4/UiyLaPnoFzM="; pname = "rtss"; version = "0.6.2"; src = gh "Freaky/rtss" "v0.6.2" "2e526d77eb3cd1d691dbcec937992c297aab4bc369b121620ee4903cfbd1525e";
    bins = "rtss"; check = chk ''"$out/bin/rtss" --version'' "^rtss version 0\\.6\\.2"; };
  # as-tree (BlueOak-1.0.0): print a list of paths as a tree.
  as-tree = pkg { vendorHash = "sha256-hECWli+DchyAzkwUmkJoYPLgMu0W5d/UA3paLyZku5c="; pname = "as-tree"; version = "0.12.0-unstable-2021-03-09"; src = gh "jez/as-tree" "0036c20f66795774eb9cda3ccbae6ca1e1c19444" "ea03c07f8faf787db80297cbb48bdeda4cb19b282b274e892c4fd5b076391672";
    bins = "as-tree"; check = chk ''printf "dir/one\ndir/two\n" | "$out/bin/as-tree" --color never'' "two$"; };
  # cargo-bloat (MIT): what takes the space in a Rust executable.
  cargo-bloat = pkg { vendorHash = "sha256-sRtOdczt84AHFn8+0yes6N9a+oKhe73nPhkXUl2UWqI="; pname = "cargo-bloat"; version = "0.12.1"; src = gh "RazrFalcon/cargo-bloat" "v0.12.1" "8195cebb94a740cd3b89611ae79d7d3e2d8fd8ec297f5a0f07efa7069ef05be7";
    bins = "cargo-bloat"; check = chk ''"$out/bin/cargo-bloat" bloat --version'' "^0\\.12\\.1$"; };
  # choose (GPL-3.0-or-later): a human-friendly cut/awk field selector.
  choose = pkg { vendorHash = "sha256-DLlwjzqE3glMyIzWPw8nnYXGdJQ0Q06IqxIMd7+i/+s="; pname = "choose"; version = "1.3.7"; src = gh "theryangeary/choose" "v1.3.7" "8f51a315fbbe0688c4a2078ba8bc8446d36943b6cce6ed9bbd6a11f33bd1a134";
    bins = "choose"; check = chk ''echo "one two three" | "$out/bin/choose" 1'' "^two$"; };
  # huniq (BSD-3-Clause): sort | uniq without the sort, by hashing.
  huniq = pkg { vendorHash = "sha256-2JWKxWVi+G+L2EQBFiSQBUZljB+VzYulvHbQlfmJ1JI="; pname = "huniq"; version = "2.7.0"; src = crate "huniq" "2.7.0" "893e6f77c7f0fc03b40977fe80d09a05e80096b3858c51472c9f954b85a3938f";
    bins = "huniq"; check = chk ''printf "b\na\nb\nb\n" | "$out/bin/huniq" | tr "\n" ,'' "^b,a,$"; };
  # tuc (GPL-3.0-or-later): cut with more features (negative indexes, ranges, regex delimiters).
  tuc = pkg { vendorHash = "sha256-oAUfM8Bj47c06BZrb7++903ECMEZ2vSevbPhNN3ZrFU="; pname = "tuc"; version = "1.2.0"; src = gh "riquito/tuc" "v1.2.0" "bb6d16772ed0728f396d32066d391206420497a4f902071b0229790a8c844307";
    bins = "tuc"; check = chk ''echo "a:b:c" | "$out/bin/tuc" -d : -f -1'' "^c$"; };
  # regex-cli (MIT OR Apache-2.0): the regex crate's command line (debug, search, serialize DFAs).
  regex-cli = pkg { vendorHash = "sha256-kQn7aacN3tYMvQF6vR07bP0uDqQPPS+3u79FZK2vFY8="; pname = "regex-cli"; version = "0.2.3"; src = crate "regex-cli" "0.2.3" "9b4c3097cd99068e0fa4b3e0556186873abe67c954f68624338b5a19531de29b";
    bins = "regex-cli"; check = chk ''"$out/bin/regex-cli" debug hir "a|b"'' "Class|Alternation"; };
  # critcmp (MIT OR Unlicense): compare criterion benchmark runs.
  critcmp = pkg { vendorHash = "sha256-qZgRd7XuQaGXYs4Fmz5N+CYcCeBuZO3HybueksD7gEQ="; pname = "critcmp"; version = "0.1.8"; src = gh "BurntSushi/critcmp" "0.1.8" "b89a2a0a1140dcf11aa66de670c62854212bfd57f674eea6da942b87b267ae9c";
    bins = "critcmp"; check = chk ''"$out/bin/critcmp" --version'' "^critcmp 0\\.1\\.8"; };
  # txm (MIT OR Apache-2.0): a tmux-like terminal multiplexer.
  txm = pkg { vendorHash = "sha256-7BCZg4tArDAOiMEGVQ9ZfN/nsHvhDXnu12zsJMxp3f8="; pname = "txm"; version = "0.1.6"; src = gh "thatmagicalcat/txm" "refs/tags/v0.1.6" "563a31c78867393663505347e20dee42f24b9c6af5506cb844488765048e4caf";
    bins = "txm"; check = chk ''"$out/bin/txm" --version'' "^txm 0\\.1\\.6"; };
  # tombl (GPL-3.0-only): TOML to shell variables.
  tombl = pkg { vendorHash = "sha256-HPHunKCvofZMJ9+wKvnaxTe05YhZ/K3ZXzzoRM3A/Pg="; pname = "tombl"; version = "0.2.3"; src = gh "snyball/tombl" "refs/tags/v0.2.3" "dd793a211c99293ee9f73157d0a1cdd48dc2b0df7cdd5be30a8a13ad242bf3b2";
    bins = "tombl"; check = chk ''"$out/bin/tombl" --version'' "^tombl 0\\.2\\.3"; };
  # mdsh (MIT): run shell blocks in Markdown and splice their output in.
  mdsh = pkg { vendorHash = "sha256-KTYFwWeedrvwm1F84OkYU2FH8U6njOKnDlINEpyjhhM="; pname = "mdsh"; version = "0.9.2"; src = gh "zimbatm/mdsh" "v0.9.2" "4e6aea8fb398f52ec1c2a2bcd2d8238c885aa9bc4b3739a158e64dcc4826dad4";
    bins = "mdsh"; check = chk ''"$out/bin/mdsh" --version'' "^mdsh 0\\.9\\.2"; };
  # urlencode (MIT): URL-encode or -decode stdin or an argument.
  urlencode = pkg { vendorHash = "sha256-GXzFuvk0ZMJ62G3ExoXfchZF9C2rH5omviPaZAdrSj4="; pname = "urlencode"; version = "1.0.1"; src = gh "dead10ck/urlencode" "v1.0.1" "72aff484baa3ebddb272fa4439f2a0e770bc62aa76b9cdc0930644ac22e69a94";
    bins = "urlencode"; check = chk ''"$out/bin/urlencode" "a b&c"'' "^a%20b%26c$"; };
  # didu (LGPL-3.0-only): duration conversion between units.
  didu = pkg { vendorHash = "sha256-XBYOowtZIXYekQCRGNpt2HqgspgMI8G3FPl9qjqjNZU="; pname = "didu"; version = "2.5.2"; src = cb "annaaurora/didu" "v2.5.2" "5de55e845aae95534fb54fe76e83dfb6396bf02989cb08e7ba4b5b7cb20a3981";
    bins = "didu"; check = chk ''"$out/bin/didu" --version'' "^didu 2\\.5\\.2"; };
  # sanctity (LGPL-3.0-only): a 16-colour ANSI terminal test.
  sanctity = pkg { vendorHash = "sha256-i0I+KPoKRT0O+aJX6wEJRPlsh31JtdgXJPa7YmEqkeo="; pname = "sanctity"; version = "1.3.1"; src = cb "annaaurora/sanctity" "v1.3.1" "6b1595cf7cac170e843f8b79fa8d0ffbf848e49582a3429d97b9e75a1328d47f";
    bins = "sanctity"; check = chk ''"$out/bin/sanctity" -t XYZ -b red'' "XYZ"; };   # the v1.3.1 tag's Cargo.toml says 1.2.1 (--version), as sd
  # colorpanes (LGPL-3.0-only): panes in the 8 bright terminal colours; colp, and the colorpanes link nixpkgs adds.
  colorpanes = pkg { vendorHash = "sha256-oKoFGo3QWNDhDok+jLt/Ry+VXcZtSyC0l+hlMixxxzQ="; pname = "colorpanes"; version = "3.0.1"; src = cb "annaaurora/colorpanes" "v3.0.1" "9e5d37f9a848de7f12738ad857642b0fd2e118fa23836fbcba71857d72c188f0";
    bins = "colp"; man = ''ln -s colp "$out/bin/colorpanes"''; check = chk ''"$out/bin/colorpanes" --version'' "^colorpanes 3\\.0\\.1"; };
}
