#!/bin/sh
# run-matrix.sh : on dixa as gburd, in /var/tmp/aa64tls. tls-repro2.sh under each rtld x libc combination; nothing installed.
#   sys  = image /lib/ld.so.1 (PT_INTERP) + store libc rs4hiizl (RUNPATH)  : negative control (expect FAIL)
#   t0   = rebuilt-unpatched ld.so.1 + libc (same tree, no diffs)         : rebuild control (expect = sys)
#   rtld = t1 ld.so.1 + store libc   : IE half only (expect A,A',B-gd FAIL; B-ie PASS)
#   libc = image ld.so.1 + t1 libc   : GD half only (expect B-gd PASS; IE parts FAIL)
#   both = t1 ld.so.1 + t1 libc      : the fix (expect all PASS, rc 0)
D=/var/tmp/aa64tls; cd $D
for c in "sys:" "t0:env LD_LIBRARY_PATH=$D/t0/lib $D/t0/lib/ld.so.1" "rtld:$D/t1/lib/ld.so.1" \
         "libc:env LD_LIBRARY_PATH=$D/t1/lib" "both:env LD_LIBRARY_PATH=$D/t1/lib $D/t1/lib/ld.so.1"; do
  n=${c%%:*}; RUN=${c#*:}; W=$D/w-$n; export RUN W
  [ -d $W ] && find $W -depth -delete
  sh $D/tls-repro2.sh > $D/out-$n.txt 2>&1; rc=$?
  lc=$(cd $W && env LD_TRACE_LOADED_OBJECTS=1 $RUN ./a 2>&1 | grep 'libc.so.1' | awk '{print $NF}' | tr '\n' ' ')
  echo "== $n rc=$rc PASS=$(grep -c ^PASS $D/out-$n.txt) FAIL=$(grep -c ^FAIL $D/out-$n.txt) libc: $lc"
done
