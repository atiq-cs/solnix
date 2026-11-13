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
  # --- batch 2
  # b3sum (CC0-1.0 OR Apache-2.0): the BLAKE3 hash command line.
  b3sum = pkg { vendorHash = "sha256-xwiZdW95TCMxmOPRQHnQlIugwbxR2mP0HvyF8YJsoLA="; pname = "b3sum"; version = "1.8.7"; src = crate "b3sum" "1.8.7" "d12cbf49ea673482c08f7a2cbede6388e698bdae001e9e1536c314cf2741ea5d";
    bins = "b3sum"; check = chk ''printf abc | "$out/bin/b3sum" --no-names'' "^6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85$"; };
  # toml2json (MIT): TOML on stdin to JSON.
  toml2json = pkg { vendorHash = "sha256-P+KAtBpd6FjHQnum6JCzZJyb4i8eVDFs79BhGFQbtL4="; pname = "toml2json"; version = "1.4.0"; src = crate "toml2json" "1.4.0" "98a71987bd789bb49ebee6336a2c5ca8954b4b8574798525efb5651e436cd186";
    bins = "toml2json"; check = chk ''printf "a = 1\n" | "$out/bin/toml2json"'' "\"a\": ?1"; };
  # eva (MIT): a calculator REPL (and one-shot expressions).
  eva = pkg { vendorHash = "sha256-tdfL7Z9Asp/XdpoHr9Q/zoCpa+EjSeMi8EYv56rVXrg="; pname = "eva"; version = "0.3.1"; src = crate "eva" "0.3.1" "20121fb4994610215aebb9d0b82bb31f7988d0309e7a4272cec96b044bd18c47";
    bins = "eva"; check = chk ''"$out/bin/eva" "6*7"'' "^42(\\.0+)?$"; };
  # diskus (MIT OR Apache-2.0): a fast du -sh.
  diskus = pkg { vendorHash = "sha256-anJdss4D7UnW41WSArNF6zlhKiiFyN3oyBw5LvRcOYg="; pname = "diskus"; version = "0.9.0"; src = gh "sharkdp/diskus" "v0.9.0" "c4c9e4cd3cda25f55172130e3d6a58b389f0113fcefa96c73e4c80565547d1bf";
    bins = "diskus"; check = chk ''"$out/bin/diskus" --version'' "^diskus 0\\.9\\.0"; };
  # lscolors (MIT OR Apache-2.0): colourise paths by LS_COLORS (nixpkgs' nu-ansi-term feature, the crate's default).
  lscolors = pkg { vendorHash = "sha256-JrAvkeQYEyHUcm8IywneBaBaprl7nNbfqOlqTkb/5Cg="; pname = "lscolors"; version = "0.21.0"; src = crate "lscolors" "0.21.0" "d60e266dfb1426eb2d24792602e041131fdc0236bb7007abc0e589acafd60929";
    bins = "lscolors"; features = "nu-ansi-term"; check = chk ''echo /tmp | LS_COLORS="di=01;34" "$out/bin/lscolors"'' "34m"; };
  # fst (MIT OR Unlicense): the fst-bin command line for finite-state-transducer sets and maps.
  fst = pkg { vendorHash = "sha256-RPa9dmLxoO4EvQ3vZAEgixTzSD1cYssS/BapevTL24Q="; pname = "fst"; version = "0.4.3"; src = crate "fst-bin" "0.4.3" "b3bc3f5b1becb288856c43673d440ab680d4c4d7221360247dd97cca00b5a20e";
    bins = "fst"; check = chk ''cd "$W" && printf "abc,1\nabcd,1\n" > f.csv && "$out/bin/fst" map f.csv f.fst --force && "$out/bin/fst" fuzzy f.fst abc'' "^abc$"; };
  # csview (MIT OR Apache-2.0): pretty CSV tables in the terminal.
  csview = pkg { vendorHash = "sha256-iDIEFmQfeNSEzscSm/kqh56CRTHiUcpn4Wak/7Q6HiY="; pname = "csview"; version = "1.3.4"; src = gh "wfxr/csview" "v1.3.4" "91fadcddef511265f4bf39897ce4a65c457ac89ffd8dd742dc209d30bf04d6aa";
    bins = "csview"; check = chk ''printf "a,b\n1,2\n" | "$out/bin/csview"'' "│ 1 │ 2 │|\\| 1 \\| 2 \\|"; };
  # json-sort (EUPL-1.2): sort the keys of JSON files.
  json-sort = pkg { vendorHash = "sha256-jCjWfRTF3dl080+kjs13fWKPwxdiB00/WI83HwgJvbU="; pname = "json-sort"; version = "1.1.6"; src = gh "drupol/json-sort" "refs/tags/1.1.6" "05082a54e4764e0864c0a96bcd919bf16229aa7b569b3eb7458b6854cde92978";
    bins = "json-sort"; check = chk ''"$out/bin/json-sort" --version'' "^json-sort 1\\.1\\.6"; };
  # tagref (MIT): cross-references in code (tags and refs) checked.
  tagref = pkg { vendorHash = "sha256-haywruvet34bNxH8yrdyZR9tpqGURaMFCz0X6MRAerA="; pname = "tagref"; version = "1.14.0"; src = gh "stepchowfun/tagref" "v1.14.0" "a422ed19499436ed126bd9b53c8744cc4ab81832f90b1b6ae8481ecb5ed4b1d8";
    bins = "tagref"; check = chk ''"$out/bin/tagref" --version'' "^tagref 1\\.14\\.0"; };
  # ruplacer (BSD-3-Clause): find and replace across a tree.
  ruplacer = pkg { vendorHash = "sha256-4MwFD6OCpfx7UZvc5mUy/sRC4UJVFE5A//BGX+ULoH8="; pname = "ruplacer"; version = "0.10.0"; src = gh "your-tools/ruplacer" "v0.10.0" "64570d46e9d3587903bc6d553da5f1581be9771a08672fd7a1b08e65ee0e008a";
    bins = "ruplacer"; check = chk ''"$out/bin/ruplacer" --version'' "^ruplacer 0\\.10\\.0"; };
  # kondo (MIT): clean build artifacts out of project trees (the CLI; the workspace's GUI is excluded upstream).
  kondo = pkg { vendorHash = "sha256-6cQBOSkFDJJpEU+nbvNnQo4sCteE0g38qpuX6M4IO4o="; pname = "kondo"; version = "0.9"; src = gh "tbillington/kondo" "v0.9" "188c577f1d21d783cd2b4b43a5cbae5ffe8b085e5773e10846af55968ddd50c4";
    bins = "kondo"; check = chk ''cd "$W" && mkdir -p kp/target && echo x > kp/target/o && printf '[package]\nname = "k"\n' > kp/Cargo.toml && "$out/bin/kondo" -n kp'' "Projects cleaned: 0/1";   # no --version flag; -n deletes nothing; an empty target/ is skipped
  };
  # dupe-krill (MIT): replace duplicate files with hardlinks.
  dupe-krill = pkg { vendorHash = "sha256-LiU/BS1ddYhyBefFkY4jwTweVlKZpfO/vdaGL2UmIbs="; pname = "dupe-krill"; version = "1.5.0"; src = gh "kornelski/dupe-krill" "v1.5.0" "ef00a7a7517c7c813d881f4724b21c46f28cdd44005d346aa32490ed2d0457dc";
    bins = "dupe-krill"; check = chk ''cd "$W" && mkdir dk && echo same > dk/a && echo same > dk/b && "$out/bin/dupe-krill" --dry-run dk'' "[Dd]upe|[Hh]ardlink|1 "; };
  # topfew-rs (GPL-3.0-only): the most frequent field values of a log, fast (tf).
  topfew-rs = pkg { vendorHash = "sha256-W7XngtNDN4kZLNdSCbKHPd9+OT0aA2iVrjdYacUt53g="; pname = "topfew-rs"; version = "0.2.3"; src = gh "djc/topfew-rs" "refs/tags/0.2.3" "3149ca0c2c3c99c6e8b6cf412c50a164354c7acf8f5423065520888ee87dde0b";
    bins = "tf"; check = chk ''i=0; while [ $i -lt 200 ]; do echo "a $i"; i=$((i + 1)); done > "$W/t.log"; echo "b 0" >> "$W/t.log"; "$out/bin/tf" -f 1 "$W/t.log"'' "^200 a$"; };   # a file smaller than the CPU count gives chunk size 0 and no output (upstream)
  # rblake3sum (MIT): a recursive BLAKE3 digest of a directory tree.
  rblake3sum = pkg { vendorHash = "sha256-65vX/C1BCVVmD2/bjWO35TcZpHjV9bNpHKALBURo8Es="; pname = "rblake3sum"; version = "0.4.0"; src = gh "rustshop/rblake3sum" "6a8e2576ccc05214eacb75b75a9d4cfdf272161c" "b98198821ba975aeca314ded7037db1ce731305b2ca7f735112605ca70c248a5";
    bins = "rblake3sum"; check = chk ''"$out/bin/rblake3sum" --version'' "^rblake3sum 0\\.4\\.0"; };
  # rblake2sum (MIT): a recursive BLAKE2 digest of a directory tree.
  rblake2sum = pkg { vendorHash = "sha256-Won0b2D3ujVrxe+xYK+Eh5XSyjCxBK3j4bf24HuIY3k="; pname = "rblake2sum"; version = "0.3.1"; src = gh "crev-dev/rblake2sum" "cdbaba9f198bd28bfad2fbc17011ce5c8c7ad957" "3eacaa4c87ddcc0c3a9ab99b24c3f215fac2c0e2376f7a736832b02707c792ce";
    bins = "rblake2sum"; check = chk ''"$out/bin/rblake2sum" --version'' "^rblake2sum 0\\.3\\.1"; };
  # chars (MIT): what a Unicode character is (names, codepoints).
  chars = pkg { vendorHash = "sha256-x/H8asHfO+iBOqvUh1gdrJmaS8MgOalMHKeW6tBpJgQ="; pname = "chars"; version = "0.7.0"; src = gh "boinkor-net/chars" "v0.7.0" "2f79843a3b1173870b41ebce491a54812b13a44090d0ae30a6f572caa91f0736";
    bins = "chars"; pkg = "chars"; check = chk ''"$out/bin/chars" A'' "LATIN CAPITAL LETTER A"; };
  # cocom (GPL-3.0-only): NTP client.
  cocom = pkg { vendorHash = "sha256-Xg5MUoWqEIRQk2yZTbg/BD3zdYZhX8/bFw96yiX5RpM="; pname = "cocom"; version = "2.1.0"; src = gh "LamdaLamdaLamda/cocom" "refs/tags/v2.1.0" "1f59917b102212b6ab985e135e388caf096fcbdbbfdb82ef5bce6e4d146b9a6a";
    bins = "cocom"; check = chk ''"$out/bin/cocom" --version'' "^[Cc]ocom 2\\.1\\.0"; };
  # tre-command (MIT): tree with git awareness and editor aliases (tre); its man page as nixpkgs.
  tre-command = pkg { vendorHash = "sha256-RGwmomEE15XQ35Yfgv/RKD/LNyETyAUpTOeN3t0TDEg="; pname = "tre-command"; version = "0.4.0"; src = gh "dduan/tre" "v0.4.0" "280243cfa837661f0c3fff41e4a63c6768631073c9f6ce9982d9ed08e038788a";
    bins = "tre"; man = ''mkdir -p "$out/share/man/man1" && cp manual/tre.1 "$out/share/man/man1/"''; check = chk ''"$out/bin/tre" --version'' "^tre-command 0\\.4\\.0"; };
  # mdbook-toc (MPL-2.0): an mdbook preprocessor for a table of contents.
  mdbook-toc = pkg { vendorHash = "sha256-Av6To0ME8HTRFPC/8gjisMTbMUFLXTOE7NumHYv0enw="; pname = "mdbook-toc"; version = "0.15.4"; src = gh "badboy/mdbook-toc" "refs/tags/0.15.4" "bdac90076df07368f91e8ed7d474ba5be3e887725baed1ef4e9bf3352a70c8cd";
    bins = "mdbook-toc"; check = chk ''"$out/bin/mdbook-toc" --version'' "^mdbook-toc 0\\.15\\.4"; };
  # mdbook-footnote (Apache-2.0): an mdbook preprocessor for footnotes.
  mdbook-footnote = pkg { vendorHash = "sha256-mrfaRQFaY5YODZuKVhGyond9ATWrqbUnNWyPGTS6LgQ="; pname = "mdbook-footnote"; version = "0.2.0"; src = gh "daviddrysdale/mdbook-footnote" "refs/tags/v0.2.0" "f814ea4195734e59701565bb008f0f432628806d28e580af1038774448cbffeb";
    bins = "mdbook-footnote"; check = chk ''"$out/bin/mdbook-footnote" supports html; echo "rc=$?"'' "^rc=0$"; };
  # mdbook-pagetoc (MPL-2.0): an mdbook preprocessor for a per-page TOC.
  mdbook-pagetoc = pkg { vendorHash = "sha256-vCJfV98jA/6PbJ/IaUDX0MjwuRGyYCMzSm5Z6B00VA8="; pname = "mdbook-pagetoc"; version = "0.3.0"; src = gh "slowsage/mdbook-pagetoc" "v0.3.0" "404b72d2d9039fc52b2a1b5e516f96d42f0f80637846947b4b63f25d5261a672";
    bins = "mdbook-pagetoc"; check = chk ''"$out/bin/mdbook-pagetoc" supports html; echo "rc=$?"'' "^rc=0$"; };
  # --- batch 3
  # anewer (GPL-3.0-or-later): append stdin lines a file lacks (anew in Rust).
  anewer = pkg { vendorHash = "sha256-+7NCWsgtamtmTrd/3O1TCBDZBayxAq709qSQ0V8VSaI="; pname = "anewer"; version = "0.2.2"; src = gh "ysf/anewer" "refs/tags/v0.2.2" "2f4021c76084ff7a3a4b43f45ab806c3de4766283ba23b6993534c67b38b3d11";
    bins = "anewer"; check = chk ''cd "$W" && printf "a\n" > an.txt && printf "a\nb\n" | "$out/bin/anewer" an.txt > /dev/null && tr "\n" , < an.txt'' "^a,b,$"; };
  # cargo-readme (MIT OR Apache-2.0): a README from a crate's doc comments.
  cargo-readme = pkg { vendorHash = "sha256-G6jendLLoCAaRf3HmRS3TmHkr9InTD96nkrjePWJCkU="; pname = "cargo-readme"; version = "3.4.1"; src = gh "webern/cargo-readme" "v3.4.1" "e71ebfead44907ea1573c6e4c177800808b06d6a5cbef2cd49d59a1934f9eb1f";
    bins = "cargo-readme"; check = chk ''"$out/bin/cargo-readme" readme --version'' "3\\.4\\.1"; };
  # cargo-toml-lint (MIT OR Apache-2.0): lint Cargo.toml files.
  cargo-toml-lint = pkg { vendorHash = "sha256-nthe/dnpyRacRxEwAFbL/fCKZNIEStHkhq5kua/pphg="; pname = "cargo-toml-lint"; version = "0.1.1"; src = crate "cargo-toml-lint" "0.1.1" "25a182b3351aa4b74f8ce165c137f9bdea02e1cf50b9a07101a1f8855eaef25e";
    bins = "cargo-toml-lint"; check = chk ''"$out/bin/cargo-toml-lint" --version'' "0\\.1\\.1"; };
  # clini (MIT): get and set keys in INI files.
  clini = pkg { vendorHash = "sha256-be3EHepL55t+FrhBP+tsjzeuuiEOJMULb5FTU7u3/AU="; pname = "clini"; version = "0.1.0"; src = crate "clini" "0.1.0" "01b441f72fa54588629ebcec7e9e139baa5d324a8aa1d97580adc0fcb7d61335";
    bins = "clini"; check = chk ''"$out/bin/clini" --version'' "^clini 0\\.1\\.0"; };
  # elf-info (GPL-3.0-only): inspect ELF files (headers, sections, symbols): elf.
  elf-info = pkg { vendorHash = "sha256-ubCCwf0Er/QOrry6FknRy3ugIi4bN2JkgFVB9ROsyQ0="; pname = "elf-info"; version = "0.3.0"; src = gh "kevin-lesenechal/elf-info" "v0.3.0" "1b182c54b3e498b6a447b937725b1dc5131c5f4239c3585473cea203ef42c923";
    bins = "elf"; check = chk ''"$out/bin/elf" --version'' "0\\.3\\.0"; };
  # nix-olde (MIT): which packages in a Nix system are older than upstream (repology).
  nix-olde = pkg { vendorHash = "sha256-bnZRFOBbcOOWAz0QJQ97aywloz/KBWz8DNwz6+uGREw="; pname = "nix-olde"; version = "0.3.0"; src = gh "trofi/nix-olde" "refs/tags/v0.3.0" "0ac445fd855894abe656175e98874dcc2182bc431cc5a6c9fb7c517c4a35910a";
    bins = "nix-olde"; check = chk ''"$out/bin/nix-olde" --version'' "^nix-olde 0\\.3\\.0"; };
  # paging-calculator (MIT): split a virtual address into its x86_64 page-table indexes.
  paging-calculator = pkg { vendorHash = "sha256-su4IH2mcNo8/p/PNREdyTqH7qT23zQMb35G41cIGR8k="; pname = "paging-calculator"; version = "0.4.0"; src = crate "paging-calculator" "0.4.0" "fd5f9d7e012f41d7928a971c1022d5fe3618fdcac4f9e6efb335429b3b0d6789";
    bins = "paging-calculator"; check = chk ''"$out/bin/paging-calculator" --version'' "^paging-calculator 0\\.4\\.0"; };
  # ropr (MIT OR Apache-2.0): a ROP gadget finder.
  ropr = pkg { vendorHash = "sha256-E7H7a6bxtkwDARhLJLrfxYbYba1/+7I2ivxUdzVAfvs="; pname = "ropr"; version = "0.2.26-unstable-2025-07-20"; src = gh "Ben-Lichtman/ropr" "ec3eb2d91d9b4a940a8013a079ead47d7eab6dac" "298633881cdbfcfd3088b1949c91b4a073806d5f26a9e6a65f2ff77e29829f10";
    bins = "ropr"; check = chk ''"$out/bin/ropr" --version'' "^ropr 0\\.2\\.26"; };
  # omekasy (MIT): decorate letters with Unicode font variants.
  omekasy = pkg { vendorHash = "sha256-j+7wUBDCpazVQXITFetgFw9nf/sTbAv8xJrQ1PMKXSw="; pname = "omekasy"; version = "1.3.3"; src = gh "ikanago/omekasy" "v1.3.3" "0def519ad64396aa12b341dee459049fb54a3cfae265ae739da5e65ca1d7e377";
    bins = "omekasy"; check = chk ''"$out/bin/omekasy" --font bold ab'' "^𝐚𝐛$"; };
  # freqle (MIT): rank shell commands by frecency.
  freqle = pkg { vendorHash = "sha256-e4oMRF94P1UY2zzZJQ/+qV7tMLVUy+tODg/I8oy0sFI="; pname = "freqle"; version = "0.1.0"; src = crate "freqle" "0.1.0" "b2eb593ebb8789ad84e0d6b11e21478551f3fcbcae0acb68200cfc30cb630ebd";
    bins = "freqle"; check = chk ''"$out/bin/freqle" --version'' "^freqle 0\\.1\\.0"; };
  # dabet (LGPL-3.0-only): the duration between two times.
  dabet = pkg { vendorHash = "sha256-JGxVOmSJDJxNqesnVWfzzni+AL7t/8GE2+pCqEsUZHk="; pname = "dabet"; version = "3.0.1"; src = cb "annaaurora/dabet" "v3.0.1" "68ced061be9f390c18adfa0dd705d72e000bd77cdf8fe9b37c60717f0589b06b";
    bins = "dabet"; check = chk ''"$out/bin/dabet" --version'' "^dabet 3\\.0\\.1"; };
  # cargo-llvm-lines (MIT OR Apache-2.0): count LLVM IR lines per generic function.
  cargo-llvm-lines = pkg { vendorHash = "sha256-8Ape2KXHrdteoEUIXXqURkxFyKAuFT39R0+l1cdiqHQ="; pname = "cargo-llvm-lines"; version = "0.4.48"; src = gh "dtolnay/cargo-llvm-lines" "refs/tags/0.4.48" "7eb44a0296047711a9c2c301296ba2c4968203c8fde65f8405de577dfd7c5107";
    bins = "cargo-llvm-lines"; check = chk ''"$out/bin/cargo-llvm-lines" llvm-lines --version'' "0\\.4\\.48"; };
  # rsass (MIT OR Apache-2.0): the rsass-cli Sass compiler.
  rsass = pkg { vendorHash = "sha256-jPrdlhE1+QtS/KX80Xi+ffCzvrw5ZcjW4Tx70BCfRf8="; pname = "rsass"; version = "0.29.0"; src = crate "rsass-cli" "0.29.0" "43208c715a9113e1d9782c242fc7ebfbe0410441ad576479f51c52f609c9c422";
    bins = "rsass"; check = chk ''printf "a { b { c: d } }\n" > "$W/t.scss" && "$out/bin/rsass" "$W/t.scss"'' "^a b ?\\{"; };
  # jsonkdl (MIT): JSON to KDL.
  jsonkdl = pkg { vendorHash = "sha256-/h5DiKTC73gE7cOAhsWe9uxB+mopl8GaCG8qvHvMy4I="; pname = "jsonkdl"; version = "1.1.0"; src = crate "jsonkdl" "1.1.0" "f42da80964d293d092c40b3e69ba48cf85079afd557c63a4b5239d8ded55511a";
    bins = "jsonkdl"; check = chk ''cd "$W" && printf '[{"name": "a", "arguments": [1]}]' > j.json && "$out/bin/jsonkdl" j.json j.kdl && cat j.kdl'' "^a 1$"; };   # the JSON form of a KDL document
  # --- batch 4
  # efmt (MIT OR Apache-2.0): an Erlang code formatter.
  efmt = pkg { vendorHash = "sha256-UgvgxKzdOiGQL9Lreq0QLJRiVaksIloQ5S3p06mnr6E="; pname = "efmt"; version = "0.21.0"; src = gh "sile/efmt" "0.21.0" "fe5b0d92a45257542492258c53c90aec83ac62f29df9de2993035f1d96854a2c";
    bins = "efmt"; check = chk ''"$out/bin/efmt" --version'' "^efmt 0\\.21\\.0"; };
  # svd2rust-form (MIT OR Apache-2.0): split a single-file Rust crate into modules (svd2rust's form).
  svd2rust-form = pkg { vendorHash = "sha256-T4+L8+mu+3gL6rAybKuZd0+JJtxJ28RjnrhBuUB3OB4="; pname = "svd2rust-form"; version = "0.13.0"; src = crate "form" "0.13.0" "628e43ce95d8e6c79d12b611e14410edda3b694075d1665bec24c6a182461f7b";
    bins = "form"; check = chk ''"$out/bin/form" --version'' "0\\.13\\.0"; };
  # tv (MIT): JSON/CSV as a table in the terminal.
  tv = pkg { vendorHash = "sha256-qfYwB6JqcQDwCFst3CEnkoIweVroQbs6Dwl5X+sEtq0="; pname = "tv"; version = "0.7.0"; src = gh "uzimaru0000/tv" "v0.7.0" "7b3c70f93cf4f23bd0a9dc1bd90591ce2db3804218ba7820bba3bc2431b4b68c";
    bins = "tv"; check = chk ''printf "[{\"a\":1,\"b\":2}]" | "$out/bin/tv"'' "\\| *a *\\| *b *\\||│ *a *│"; };
  # grip-grab (Apache-2.0): a lightweight ripgrep alternative (gg).
  grip-grab = pkg { vendorHash = "sha256-d88w61FbFesyx7IYkvBAW92kfoxRP7V1FTbAe417h14="; pname = "grip-grab"; version = "0.6.7"; src = gh "alexpasmantier/grip-grab" "refs/tags/v0.6.7" "e8bd66455ed7c05c2100f12dbc6c22f42c1c9fe8a411d1bd3948efb6906e3af3";
    bins = "gg"; check = chk ''"$out/bin/gg" --version'' "0\\.6\\.7"; };
  # moxide (GPL-3.0-only): a tmux session manager.
  moxide = pkg { vendorHash = "sha256-SkwnQDwKK1fpBHIzJ8RYTb+xGrT9J1+a9Qe2/rri8ek="; pname = "moxide"; version = "0.3.0"; src = gh "dlurak/moxide" "refs/tags/v0.3.0" "d0adf9a25b526570f507d33c57b6ea05192d4ab2d36949b05e807a2f93e6830e";
    bins = "moxide"; check = chk ''"$out/bin/moxide" --version'' "^moxide 0\\.3\\.0"; };
  # sleek (MIT): a SQL formatter.
  sleek = pkg { vendorHash = "sha256-iI2rYNq+T8C/RFRlCVeGo1/6uSgHOihNhe1889uHV2A="; pname = "sleek"; version = "0.5.0"; src = gh "nrempel/sleek" "v0.5.0" "fcb589fdc5ece8c050883ff0b56aec6bd25e2e4d6e77a1d52e870535d66fdf67";
    bins = "sleek"; check = chk ''echo "select a from t" | "$out/bin/sleek"'' "^SELECT"; };
  # rhai-doc (MIT OR Apache-2.0): HTML documentation from Rhai scripts.
  rhai-doc = pkg { vendorHash = "sha256-KjcliA1U6IRMdhVRabEb7dMvlFfUIMX5PAzilp7WFMI="; pname = "rhai-doc"; version = "0.2.3"; src = gh "rhaiscript/rhai-doc" "v0.2.3" "5236ef0a352a8c7aa9ad36dcb8be45fffbdc8dc786576c9dd689f03623a55207";
    bins = "rhai-doc"; check = chk ''"$out/bin/rhai-doc" --version'' "^rhai-doc 0\\.2\\.3"; };
  # wasm-component-ld (Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT): the wasm32-wasip2 linker wrapper.
  wasm-component-ld = pkg { vendorHash = "sha256-92+oUMLQcz0cCR1V1EBI588oX6g5zhEMtttVW1eI1iQ="; pname = "wasm-component-ld"; version = "0.5.31"; src = gh "bytecodealliance/wasm-component-ld" "refs/tags/v0.5.31" "0ff2469fe15d674a1430d1b851f899c5511bc57f917fd7a5949d8c73f417b7b4";
    bins = "wasm-component-ld"; check = chk ''"$out/bin/wasm-component-ld" --version'' "0\\.5\\.31"; };
  # oas2html (MIT): an OpenAPI/Swagger spec to one HTML page.
  oas2html = pkg { vendorHash = "sha256-m2PUa+PLnHUIrIuTmQYqa5DwaWN03e+5ieP/2KZsXv4="; pname = "oas2html"; version = "0.1.0"; src = gh "affolter-engineering/oas2html" "refs/tags/0.1.0" "8affd6638a010baeab32f8c9a6bcea3fd06709e917597c839addf675c904a82c";
    bins = "oas2html"; check = chk ''"$out/bin/oas2html" --version'' "0\\.1\\.0"; };
}
