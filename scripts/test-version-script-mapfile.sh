#!/usr/bin/env bash
# test-version-script-mapfile.sh -- pkgs/illumos/version-script-mapfile.sh's converter (any awk; the link shim itself is proven by
# the four recipes' in-build checks on illumos). Each case: a GNU version script, the names the link defines, the mapfile wanted.
S=${1:-$(dirname "$0")/../pkgs/illumos/version-script-mapfile.sh}
W=$(mktemp -d); trap 'find "$W" -delete' EXIT
bad=0; ok() { echo "ok: $1"; }; no() { echo "FAIL: $1"; bad=1; }
t() {   # <name> <script> <defined names, space-separated> <want> : convert must exit 0 and print exactly <want>
  printf '%b' "$2" > "$W/s"; printf '%s\n' $3 > "$W/d"
  got=$(bash "$S" convert "$W/s" "$W/d" 2>&1); rc=$?
  [ $rc = 0 ] && [ "$got" = "$(printf '%b' "$4")" ] && ok "$1" || { no "$1 (rc=$rc)"; printf '%s\n' "$got" | head -20; }
}
n() {   # <name> <script> : convert must fail closed (exit 1, a message, no mapfile on stdout)
  printf '%b' "$2" > "$W/s"; printf 'a\n' > "$W/d"
  out=$(bash "$S" convert "$W/s" "$W/d" 2>/dev/null); rc=$?
  [ $rc = 1 ] && [ -z "$out" ] && ok "NEG $1" || no "NEG $1 (rc=$rc, out=$out)"
}
H='$mapfile_version 2\n'
# exact names, a parent, `local: *`; names the link does not define are left out (illumos ld would export them as UNDEF)
t "nodes+parent" 'V1 { global: a; gone; local: *; };\nV2 { global: b; } V1;\n' "a b c" \
  "${H}SYMBOL_VERSION V1 {\n  global:\n    a;\n  local:\n    *;\n};\nSYMBOL_VERSION V2 {\n  global:\n    b;\n} V1;"
# globs expand against the defined names (illumos mapfiles take none but a bare *); comments of both kinds
t "globs+comments" '/* generated */\n# hash\nV { global: sh*; x?; local: _*; };\n' "show shy xa xbb _p q" \
  "${H}SYMBOL_VERSION V {\n  global:\n    show;\n    shy;\n    xa;\n  local:\n    _p;\n};"
# an exact name beats a glob in another node (GNU precedence); `global: *` takes what nothing else matched
t "precedence" 'A { global: f*; };\nB { global: fx; g; };\nC { global: *; };\n' "fa fx g h _end _DYNAMIC" \
  "${H}SYMBOL_VERSION A {\n  global:\n    fa;\n};\nSYMBOL_VERSION B {\n  global:\n    fx;\n    g;\n};\nSYMBOL_VERSION C {\n  global:\n    h;\n};"
# an anonymous node (libglvnd's export lists) is a scope, no version; the link-editor's reserved names are never listed
t "anonymous" '{\n  global:\n    __glDispatchInit;\n    _glapi_Current;\n  local: *;\n};\n' "__glDispatchInit _glapi_Current internal _end _init" \
  "${H}SYMBOL_SCOPE {\n  global:\n    __glDispatchInit;\n    _glapi_Current;\n  local:\n    *;\n};"
# no `;` before `}`, quoted names, dotted version names
t "lenient" 'LIBMD_0.0 { global: "q" ; r };\n' "q r" "${H}SYMBOL_VERSION LIBMD_0.0 {\n  global:\n    q;\n    r;\n};"
n "extern C++" 'V { global: extern "C++" { foo::bar; }; };'
n "unterminated node" 'V { global: a;'
n "unterminated comment" '/* x\nV { global: a; };'
n "anonymous + named" '{ global: a; };\nV { global: b; };'
n "no nodes" '/* empty */'
n "missing ; after node" 'V { global: a; }\nW { global: b; };'
[ $bad = 0 ] && echo "PASS" || echo "FAILED"; exit $bad
