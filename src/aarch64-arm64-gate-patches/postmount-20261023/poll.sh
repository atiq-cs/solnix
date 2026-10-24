#!/bin/bash
# poll.sh <iid-file> <tag> N : one get-console-output --latest read -> out/<tag>-cN.{json,txt} + counts
export AWS_PROFILE=kiwi AWS_REGION=us-west-2
cd /scratch/solnix/aa64e; I=$(cut -f1 $1); T=$2; N=$3
timeout 60 aws ec2 get-console-output --instance-id $I --latest --output json > out/$T-c$N.json
python3 -c "import json,sys; d=json.load(open('out/$T-c$N.json')); sys.stdout.write(d.get('Output') or '')" | tr -d '\r' > out/$T-c$N.txt
F=out/$T-c$N.txt
echo "$T c$N $(date -u +%H:%M:%SZ) bytes=$(wc -c <$F) md5=$(md5sum <$F | cut -c1-8) root=$(grep -ac 'root on ' $F) obs=$(grep -ac 'AA64E\] observer up' $F) S=$(grep -ao '\[AA64E\] S[0-9]*' $F | tail -1) hb=$(grep -ac 'AA64E-HB' $F) D=$(grep -ac '^|D|' $F) W=$(grep -ac '^|W|' $F) P=$(grep -ac 'AA64E-P' $F) panic=$(grep -aic 'panic\[' $F) login=$(grep -ac 'login:' $F)"
