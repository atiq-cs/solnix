#!/usr/bin/bash
# version-script-mapfile.sh -- GNU ld version scripts on the illumos link-editor (recipes5, 2026-11-09).
# illumos ld rejects --version-script; it takes mapfiles (-M). Version 2 mapfiles have the same nodes (SYMBOL_VERSION NAME
# { global: ...; local: *; } PARENT;) but, measured on woof: no glob except a bare `local: *`, a listed global the link does not
# define becomes an UNDEF export (GNU ld drops it; consumers then fail to link), comments are syntax errors, and gas .symver
# aliases stay literal names (foo@@V2). So the shim links once without the script, reads the global names that link defines
# (nm -P), expands every pattern against them, and links again with a mapfile that lists only those names.
#   "$BASH" version-script-mapfile.sh wrap        in a mk-src-pkg build: put the shim in front of $CC and $CXX (same paths)
#   version-script-mapfile.sh convert <script> <names>   the mapfile for a version script and a file of defined names (stdout)
#   version-script-mapfile.sh <compiler> <args...>       the shim: a link with a version script gets the mapfile instead
# Fails closed (exit 1) on anything it cannot translate: a syntax error, extern "C++" blocks, .symver names in the objects.
self=$0

conv() {
  awk -v DEF="$2" '
  function fail(m) { printf "version-script-mapfile: %s: %s\n", SRC, m > "/dev/stderr"; bad = 1; exit 1 }
  function tok() { while (k < n) { k++; if (t[k] != "") return t[k] } k = n + 1; return "" }
  function glob2re(g,   r, c, i, j) {
    r = "^"
    for (i = 1; i <= length(g); i++) { c = substr(g, i, 1)
      if (c == "*") r = r ".*"; else if (c == "?") r = r "."
      else if (c == "[") { j = index(substr(g, i), "]"); if (!j) fail("bad pattern " g); r = r substr(g, i, j); i += j - 1 }
      else if (index(".$^+(){}|\\", c)) r = r "\\" c; else r = r c }
    return r "$"
  }
  BEGIN { SRC = ARGV[1] }
  { sub(/#.*/, ""); s = s $0 "\n" }
  END {
    if (bad) exit 1
    while ((i = index(s, "/*")) > 0) { j = index(substr(s, i + 2), "*/"); if (!j) fail("unterminated comment")
      s = substr(s, 1, i - 1) " " substr(s, i + j + 3) }
    gsub(/[{};:]/, " & ", s)
    n = split(s, t, /[ \t\n]+/); k = 0; nn = 0; anon = 0
    while ((x = tok()) != "") {
      name = ""; if (x != "{") { name = x; if (tok() != "{") fail("expected { after " name) }
      if (name !~ /^[A-Za-z0-9_.]*$/) fail("bad version name " name)
      nn++; vn[nn] = name; if (name == "") anon++; sc = "global"
      while (1) { x = tok()
        if (x == "") fail("unexpected end of script")
        if (x == "}") break
        if (x == ";") continue
        if (x == "global" || x == "local") { if (tok() != ":") fail("expected : after " x); sc = x; continue }
        if (x == "extern") fail("extern blocks (C++ demangled names) are not supported")
        if (x == ":" || x == "{") fail("unexpected " x)
        gsub(/"/, "", x); np++; pn[np] = nn; ps[np] = sc; pp[np] = x
        if (tok() != ";") { if (t[k] == "}") break; fail("expected ; after " x) }
      }
      dep[nn] = ""; while ((x = tok()) != ";") { if (x == "" || x == "{" || x == "}") fail("expected ; after node " name); dep[nn] = dep[nn] " " x }
    }
    if (nn == 0) fail("no version nodes")
    if (anon && nn > 1) fail("an anonymous version node cannot be combined with others")
    # reserved names the link-editor makes itself: never listed
    split("_DYNAMIC _GLOBAL_OFFSET_TABLE_ _PROCEDURE_LINKAGE_TABLE_ _edata _end _etext _init _fini _START_ _END_", rv, " ")
    for (i in rv) res[rv[i]] = 1
    while ((getline d < DEF) > 0) if (d != "" && !(d in res)) def[++nd] = d
    # GNU precedence: an exact name, then the first wildcard that matches, then a bare `*`
    for (i = 1; i <= np; i++) { p = pp[i]
      if (p == "*") { if (ps[i] == "local") lstar[pn[i]] = 1; else if (!gstar) gstar = pn[i]; continue }
      if (p ~ /[*?]/ || index(p, "[")) { ng++; gre[ng] = glob2re(p); gi[ng] = i } else if (!(p in ex)) ex[p] = i }
    for (m = 1; m <= nd; m++) { d = def[m]; w = 0
      if (d in ex) w = ex[d]; else for (g = 1; g <= ng && !w; g++) if (d ~ gre[g]) w = gi[g]
      if (w) { if (ps[w] == "global") G[pn[w]] = G[pn[w]] "    " d ";\n"; else L[pn[w]] = L[pn[w]] "    " d ";\n" }
      else if (gstar) G[gstar] = G[gstar] "    " d ";\n" }
    print "$mapfile_version 2"
    for (i = 1; i <= nn; i++) {
      print (vn[i] == "" ? "SYMBOL_SCOPE {" : "SYMBOL_VERSION " vn[i] " {")
      if (G[i] != "") printf "  global:\n%s", G[i]
      if (L[i] != "" || lstar[i]) printf "  local:\n%s%s", L[i], (lstar[i] ? "    *;\n" : "")
      print "}" dep[i] ";" }
  }' "$1"
}

wrap() {
  n=0
  for f in "$CC" "${CXX:-}"; do
    [ -n "$f" ] || continue
    # a compiler given by name (the store-only stdenv: CC=gcc, CXX=g++ on PATH, regular files in $W/bin$ABI) is the file PATH finds
    case $f in */*) ;; *) f=$(command -v "$f") || continue ;; esac
    [ -f "$f" ] || continue
    grep -q version-script-mapfile "$f" && { n=$((n + 1)); continue; }
    mv "$f" "$f.real" || exit 1
    { head -1 "$f.real"; printf 'exec "%s" "%s" "%s" "$@"   # version-script-mapfile\n' "$BASH" "$self" "$f.real"; } > "$f"
    chmod +x "$f" || exit 1; n=$((n + 1))
  done
  # fail closed: wrapping nothing would leave the raw --version-script for illumos ld (or configure's probe dropping it)
  [ $n -gt 0 ] || { echo "version-script-mapfile: wrap found no compiler file for CC='$CC' CXX='${CXX:-}'" >&2; exit 1; }
}

shim() {
  real=$1; shift
  case " $* " in *version-script*) ;; *) exec "$real" "$@" ;; esac
  args=() vs="" oi=-1 link=1 pend=0; set -f
  while [ $# -gt 0 ]; do a=$1; shift
    if [ $pend = 1 ]; then pend=0; vs=${a#-Wl,}; continue; fi   # the file after a lone --version-script: -Wl,F or a plain F
    case $a in
      -c|-S|-E) link=0 ;;
      -Xlinker) case ${1:-} in
          --version-script=*|-version-script=*) vs=${1#*=}; shift; continue ;;
          --version-script|-version-script) shift; [ "${1:-}" = -Xlinker ] && shift; vs=${1:-}; shift; continue ;;
        esac ;;
      -Wl,*) IFS=,; w=(${a#-Wl,}); unset IFS; keep=(); i=0
        while [ $i -lt ${#w[@]} ]; do x=${w[$i]}
          case $x in
            --version-script=*|-version-script=*) vs=${x#*=} ;;
            --version-script|-version-script) i=$((i + 1)); if [ $i -lt ${#w[@]} ]; then vs=${w[$i]}; else pend=1; fi ;;
            *) keep+=("$x") ;;
          esac; i=$((i + 1))
        done
        [ ${#keep[@]} -gt 0 ] && args+=("-Wl,$(IFS=,; echo "${keep[*]}")"); continue ;;
      -o) args+=(-o "${1:-}"); oi=$((${#args[@]} - 1)); shift; continue ;;
      -o?*) args+=(-o "${a#-o}"); oi=$((${#args[@]} - 1)); continue ;;
    esac
    args+=("$a")
  done
  [ $link = 1 ] && [ -n "$vs" ] || exec "$real" "${args[@]}"
  [ -f "$vs" ] || { echo "version-script-mapfile: no version script '$vs'" >&2; exit 1; }
  [ $oi -ge 0 ] || { args+=(-o a.out); oi=$((${#args[@]} - 1)); }
  out=${args[$oi]} a1=("${args[@]}"); a1[$oi]="$out.vsm1"
  "$real" "${a1[@]}" || exit $?
  nm -P -g "$out.vsm1" | awk '$2 !~ /^[Uwv]$/ { print $1 }' > "$out.vsm.def"; rc=$?
  rm -f "$out.vsm1"
  [ $rc = 0 ] && [ -s "$out.vsm.def" ] || { echo "version-script-mapfile: nm found no defined names in the first link (stripped?)" >&2; rm -f "$out.vsm.def"; exit 1; }
  if grep -q @ "$out.vsm.def"; then
    echo "version-script-mapfile: the objects define .symver names, which illumos ld does not version: $(grep @ "$out.vsm.def" | head -3 | tr '\n' ' ')" >&2
    rm -f "$out.vsm.def"; exit 1
  fi
  conv "$vs" "$out.vsm.def" > "$out.vsm" || { rm -f "$out.vsm" "$out.vsm.def"; exit 1; }
  "$real" "${args[@]}" -Wl,-M,"$out.vsm"; rc=$?
  rm -f "$out.vsm" "$out.vsm.def"; exit $rc
}

case ${1:-} in
  wrap) wrap ;;
  convert) conv "$2" "$3" ;;
  "") echo "usage: $0 wrap | convert <script> <names> | <compiler> <args...>" >&2; exit 2 ;;
  *) shim "$@" ;;
esac
