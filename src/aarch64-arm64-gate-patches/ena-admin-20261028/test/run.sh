#!/bin/sh
# run.sh : t_p10.c with p10 (NEW) must PASS; the gate loop (OLD, negative control) must FAIL case A.
cd "$(dirname "$0")"
cc -Wall -Werror -fsanitize=address,undefined -DNEW -o t_new t_p10.c && cc -Wall -Werror -fsanitize=address,undefined -o t_old t_p10.c || exit 2
echo "== NEW (p10)"; ./t_new; n=$?
echo "== OLD (gate, negative control)"; ./t_old; o=$?
[ $n = 0 ] && [ $o != 0 ] && echo "VERDICT PASS (new passes, old fails)" || { echo "VERDICT FAIL"; exit 1; }
