#!/bin/bash
# poll.sh N : one get-console-output --latest read of the metal -> out/metal-cN.{json,txt}, plus counts
export AWS_PROFILE=kiwi AWS_REGION=us-east-2
cd /scratch/solnix/aa64b; I=$(cut -f1 metal-iid.txt); N=$1
aws ec2 get-console-output --instance-id $I --latest --output json > out/metal-c$N.json
python3 -c "import json,sys; d=json.load(open('out/metal-c$N.json')); sys.stdout.write(d.get('Output') or '')" | tr -d '\r' > out/metal-c$N.txt
T=out/metal-c$N.txt
echo "c$N $(date -u +%H:%M:%SZ) bytes=$(wc -c <$T) banners=$(grep -ac 'Tianocore/EDK2' $T) scan=$(grep -ac 'Performing full ZFS' $T) ecam0=$(grep -ac 'ecam0 at root' $T) E146=$(grep -ac '^\[E>146 ' $T) E147=$(grep -ac '^\[E.147 ' $T) muted=$(grep -ac '^\[E~' $T) panic=$(grep -aic 'panic' $T) login=$(grep -ac 'login:' $T)"
