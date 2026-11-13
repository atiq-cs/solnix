# cli/py-leaves.nix -- Python leaves the x86 build queue has jobs for (py1, 2026-11-13): nixpkgs f4a03c0 by-name
# buildPythonApplication attrs with no python runtime dependency (qnew8 py-evidence.tsv), on ../python.nix's buildPythonApplication.
# pname and version are the queue job's; each source is pinned by its tarball sha256 (its unpacked tree's NAR hash = nixpkgs' src
# hash, or the file hash for a fetchPypi/fetchurl src: py1 leafsrc.sh); build-system, postPatch and postInstall are nixpkgs'.
# Not here: lerpn (its gitea archive does not hash to nixpkgs' src today). A new file: no served drv moves.
{ buildPythonApplication, setuptools, chk }:
let
  gh = repo: ref: sha256: { url = "https://github.com/${repo}/archive/${ref}.tar.gz"; inherit sha256; };
  app = a: buildPythonApplication ({ build-system = [ setuptools ]; } // a);   # every leaf here: nixpkgs build-system = [ setuptools ]
  # in-build check: <cmd> run from the out, its output must match <re>
  run = cmd: re: chk ''cd "$W" && ${cmd}'' re;
in {
  # txt2tags (GPL-2.0-or-later): one text markup to HTML, LaTeX, man, ...
  txt2tags = app { pname = "txt2tags"; version = "3.9"; src = gh "txt2tags/txt2tags" "refs/tags/3.9" "1f188be1c3dccdf6beaffd1a45829b4df2b2f58973c8de6bc1a7c9cef1c0e4f1";
    pythonImportsCheck = [ "txt2tags" ];
    check = run ''printf 'Title\n\n\nhello **bold**\n' > t.t2t && "$out/bin/txt2tags" -t html -o - t.t2t'' "<strong>bold</strong>"; };
  # fypp (BSD-2-Clause): the Fortran preprocessor
  fypp = app { pname = "fypp"; version = "3.2"; src = gh "aradi/fypp" "3.2" "33f48c8d2337db539865265ce33c7c50e4d521aacbd31ac7b7e8b189d771ce1d";
    pythonImportsCheck = [ "fypp" ];
    check = run ''"$out/bin/fypp" --version'' "^fypp 3\\.2$"; };
  # compdb (MIT): the compilation database tool (headers into compile_commands.json)
  compdb = app { pname = "compdb"; version = "0.2.0"; src = gh "Sarcasm/compdb" "v0.2.0" "bfa945f924678b701f1311098f24d9a4d0358a874913c55698a8acbb7047ac67";
    pythonImportsCheck = [ "compdb" ];
    check = run ''"$out/bin/compdb" version'' "0\\.2\\.0"; };
  # flawfinder (GPL-2.0-only): a C/C++ source scanner for risky calls (code review aid)
  flawfinder = app { pname = "flawfinder"; version = "2.0.20"; src = { url = "https://dwheeler.com/flawfinder/flawfinder-2.0.20.tar.gz";
      sha256 = "9d732a4e0fef1cd4eaeefd4a0093f183c5981f6c843711ceae6a63419404996b"; };
    pythonImportsCheck = [ "flawfinder" ];
    check = run ''"$out/bin/flawfinder" --version'' "^2\\.0\\.20$"; };
  # pypi-mirror (MIT): makes a local PyPI mirror from downloaded packages
  pypi-mirror = app { pname = "pypi-mirror"; version = "5.2.1"; src = gh "montag451/pypi-mirror" "refs/tags/v5.2.1" "0ada6b17905fc2c443a6c65a7bcd093af76baf603fb12525af1aa719e1459f4b";
    pythonImportsCheck = [ "pypi_mirror" ];
    check = run ''"$out/bin/pypi-mirror" --help'' "usage: pypi-mirror"; };
  # sphinxygen (ISC): Sphinx ReST from Doxygen XML
  sphinxygen = app { pname = "sphinxygen"; version = "1.0.12";
    src = { url = "https://gitlab.com/drobilla/sphinxygen/-/archive/v1.0.12/sphinxygen-v1.0.12.tar.gz"; sha256 = "b1ac1515e84fa4c31dc10ad1a7800c0f305a1a3887b4b4e6e1980ceda4f50173"; };
    pythonImportsCheck = [ "sphinxygen" ];
    check = run ''"$out/bin/sphinxygen" -V'' "1\\.0\\.12"; };
  # perfect-hash (BSD-3-Clause): perfect hash functions for a set of keys
  perfect-hash = app { pname = "perfect-hash"; version = "0.4.1"; src = gh "ilanschnell/perfect-hash" "0.4.1" "e23cd437c168d7ac381979342581a1c06684dd126f7606c7700c9cf518f81a84";
    pythonImportsCheck = [ "perfect_hash" ];
    postInstall = ''
      mkdir -p "$out/share/doc/perfect-hash"
      cp README.md "$out/share/doc/perfect-hash"
      cp -r examples "$out/share/doc/perfect-hash"
    '';
    check = run ''"$out/bin/perfect-hash" --version'' "0\\.4\\.1"; };
  # rfc-bibtex (MIT): BibTeX entries for IETF RFCs and drafts
  rfc-bibtex = app { pname = "rfc-bibtex"; version = "0.3.2"; src = gh "iluxonchik/rfc-bibtex" "refs/tags/0.3.2" "83bcf29234a69accc9ee2944e6377269d1c3d8636fef93fdf256865f614cbc19";
    pythonImportsCheck = [ "rfc_bibtex" ];
    check = run ''"$out/bin/rfcbibtex" --help'' "usage: rfcbibtex"; };
  # xenomapper (GPL-3.0): assigns reads to the primary or secondary genome of a xenograft
  xenomapper = app { pname = "xenomapper"; version = "1.0.2"; src = gh "genomematt/xenomapper" "v1.0.2" "77f3f398768f2bb9f51914150f84724f7bee7e96445af908830af3448e269494";
    pythonImportsCheck = [ "xenomapper.xenomapper" "xenomapper.mappability" ];
    check = run ''"$out/bin/xenomapper" --help'' "usage: xenomapper"; };
  # csv2odf (GPL-3.0): CSV into an OpenDocument spreadsheet, text or presentation. Departs from nixpkgs (whose csv2odf fails at run time):
  # it imports cgi (gone in Python 3.13) for cgi.escape (gone in 3.8): html.escape with cgi.escape's default quote=False.
  csv2odf = app { pname = "csv2odf"; version = "2.09";
    prep = ''
      grep -qx "import cgi" csv2odf && [ "$(grep -c "cgi\\." csv2odf)" = 1 ] || { echo "FATAL: csv2odf cgi anchors" >&2; exit 1; }
      sed -i -e "s/^import cgi$/import html/" -e "s/cgi\\.escape(string)/html.escape(string, quote=False)/" csv2odf
      ! grep -q cgi csv2odf || { echo "FATAL: csv2odf still names cgi" >&2; exit 1; }
    '';
    src = { url = "https://downloads.sourceforge.net/project/csv2odf/csv2odf-2.09/csv2odf-2.09.tar.gz"; sha256 = "f7943891960f2b71bd17efc75fae4dc47a06810b018aab7e93f925e495f38026"; };
    check = run ''"$out/bin/csv2odf" -V'' "version 2\\.09"; };   # -V runs the top-level imports (the cgi one failed)
  # pywalfox-native (MPL-2.0): the native messaging host of the Pywalfox browser extension
  pywalfox-native = app { pname = "pywalfox-native"; version = "2.9.0"; src = gh "Frewacom/pywalfox-native" "v2.9.0" "a0cb42b301f3972875930ada946f81d3c403ef37cf33fcf0a2b5ba167137a1ea";
    pythonImportsCheck = [ "pywalfox" ];
    check = run ''"$out/bin/pywalfox" --help'' "usage: pywalfox"; };
  # cfv (GPL-2.0-or-later): checksum files (sfv, md5sum, sha1sum, torrent) test and create
  cfv = app { pname = "cfv"; version = "3.2.0"; src = gh "cfv-project/cfv" "refs/tags/v3.2.0" "fb043f4b9de0dde2985734298a299e91898d4b6b3263eb4f09a72335c42cf72b";
    check = run ''echo hello > f && "$out/bin/cfv" -C -t sha1 -f f.sha1 f && "$out/bin/cfv" -f f.sha1'' "1 OK"; };
  # git-machete (MIT): branch layout and rebase helper for git; nixpkgs' shell completions
  git-machete = app { pname = "git-machete"; version = "3.46.1"; src = gh "virtuslab/git-machete" "refs/tags/v3.46.1" "263b63ccf612ffa3b3f44e2a5f32687072f31ef51673e930f56f582c12c99a60";
    pythonImportsCheck = [ "git_machete" ];
    postInstall = ''   # installShellCompletion
      install -Dm644 completion/git-machete.completion.bash "$out/share/bash-completion/completions/git-machete"
      install -Dm644 completion/git-machete.completion.zsh "$out/share/zsh/site-functions/_git-machete"
      install -Dm644 completion/git-machete.fish "$out/share/fish/vendor_completions.d/git-machete.fish"
    '';
    check = run ''"$out/bin/git-machete" version'' "^git-machete version 3\\.46\\.1$"; };
  # lesspass-cli (GPL-3.0): the LessPass stateless password generator (the cli/ dir of the monorepo, nixpkgs' sourceRoot)
  lesspass-cli = app { pname = "lesspass-cli"; version = "9.1.9"; src = gh "lesspass/lesspass" "9.1.9" "628e319fdb445d6fbb9d33b5108a144c3f15884504cd078fff78a813bd8e38e5";
    prep = "cd cli"; pythonImportsCheck = [ "lesspass" ];
    check = run ''"$out/bin/lesspass" --version'' "9\\.1\\.9"; };
  # protocol (GPL-3.0-or-later): ASCII art header diagrams for network protocol specs (nixpkgs' setup.py postPatch)
  protocol = app { pname = "protocol"; version = "0-unstable-2019-03-28";
    src = gh "luismartingarcia/protocol" "4e8326ea6c2d288be5464c3a7d9398df468c0ada" "e8cdde9a6bb7dffa855382f820835a84251d928e66cf029779127e3ab17afd86";
    prep = ''
      grep -qF "scripts=['protocol', 'constants.py', 'specs.py']" setup.py || { echo "FATAL: protocol setup.py anchor" >&2; exit 1; }
      sed -i "s/scripts=\['protocol', 'constants.py', 'specs.py'\]/scripts=['protocol'], py_modules=['constants', 'specs']/" setup.py
    '';
    check = run ''"$out/bin/protocol" "Source:16,Destination:16"'' "Source"; };
  # syncrclone (MIT): bi-directional sync of two rclone remotes
  syncrclone = app { pname = "syncrclone"; version = "0-unstable-2023-03-23";
    src = gh "jwink3101/syncrclone" "137c9c4cc737a383b23cd9a5a21bb079e6a8fc59" "1ffdf80f8794e4add7b429fb32201a8869d85cb6417e9a9d010c57714bf5c454";
    pythonImportsCheck = [ "syncrclone" ];
    check = run ''"$out/bin/syncrclone" --help'' "usage: syncrclone"; };
}
