# run by: dash /etc/dash-test.sh  -- builtins only, compared against the host dash
x=$((6 * 7)); echo "arith $x"
for i in 1 2 3; do printf 'loop%s ' "$i"; done; echo
f() { echo "func $1 $#"; return 4; }; f a b; echo "ret $?"
case riscv64 in risc*) echo case-ok;; *) echo case-bad;; esac
v=hello.tar.gz; echo "${v%.gz} ${v#*.} ${#v}"
set -- one two three; shift; echo "args $# $*"
while [ "$x" -gt 40 ]; do x=$((x - 1)); done; echo "while $x"
s=$(echo sub); echo "cmdsub $s"
echo "${unset:-dflt} ${unset2:=assigned} $unset2"
