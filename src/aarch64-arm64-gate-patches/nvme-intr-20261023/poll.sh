#!/bin/bash
# poll.sh <iid-file> <tag> N : one get-console-output --latest read -> out/<tag>-cN.{json,txt} + counts
export AWS_PROFILE=kiwi AWS_REGION=us-east-2
cd /scratch/solnix/aa64c; I=$(cut -f1 $1); T=$2; N=$3
aws ec2 get-console-output --instance-id $I --latest --output json > out/$T-c$N.json
python3 -c "import json,sys; d=json.load(open('out/$T-c$N.json')); sys.stdout.write(d.get('Output') or '')" | tr -d '\r' > out/$T-c$N.txt
F=out/$T-c$N.txt
echo "$T c$N $(date -u +%H:%M:%SZ) bytes=$(wc -c <$F) md5=$(md5sum <$F | cut -c1-8) its=$(grep -ac 'gicv3_its0 at' $F) iort=$(grep -ac '^\[IORT\]' $F) mapti=$(grep -ac 'MAPTI ' $F) adm=$(grep -ac 'admin intr type' $F) missed=$(grep -ac 'possible missed interrupt' $F) tmo=$(grep -ac 'timeout, OPC' $F) down=$(grep -ac '(nvme0) down' $F) root=$(grep -ac 'root on ' $F) panic=$(grep -aic 'panic\[' $F) login=$(grep -ac 'login:' $F)"
