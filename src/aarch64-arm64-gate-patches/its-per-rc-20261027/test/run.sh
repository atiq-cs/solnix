#!/bin/bash
# run.sh [patched dboot_synth_fdt.c] : extract the walk + synth_rc_its from the patched file, build, run,
# then the negative control (OLDCODE: every RC gets segment 0's ITS, the pre-aa64g rule) must FAIL.
set -u; cd "$(dirname "$0")"; F=${1:-../t/dboot.c}
sed -n '/^\/\* BEGIN synth_iort_pci_its_id \*\//,/^\/\* END synth_iort_pci_its_id \*\//p' $F > iort_walk.inc
sed -n '/^\/\* BEGIN synth_rc_its \*\//,/^\/\* END synth_rc_its \*\//p' $F > rcits.inc
[ -s iort_walk.inc ] && [ -s rcits.inc ] || { echo "EXTRACT_FAIL"; exit 2; }
cc -std=c99 -Wall -Wextra -fsanitize=address,undefined -g -o t_rcits t_rcits.c && ./t_rcits; R=$?
echo "== negative control (OLDCODE) =="
cc -std=c99 -Wall -DOLDCODE -g -o t_rcits_old t_rcits.c && ./t_rcits_old; N=$?
[ $R = 0 ] && [ $N != 0 ] && echo "T_RCITS_VERDICT PASS (new passes, old fails)" || echo "T_RCITS_VERDICT FAIL r=$R n=$N"
