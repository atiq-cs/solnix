#!/bin/bash
# ptyproof.sh TAG KERNEL N -- rvtty3c: N boots of the dropbear root on lixr at -smp 8; per boot, from floki, the
# interactive ssh -tt session (ptyssh.py) and the wrong-key control. qemu is stopped via the .done file.
T=$1; K=$2; N=$3; PORT=${PORT:-2523}; L=gburd@192.168.1.179; R=/scratch/solnix/rvtty3c/proof; mkdir -p $R
SO=(-F /dev/null -o ControlMaster=no -o ControlPath=none -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o LogLevel=ERROR -o ConnectTimeout=60 -o "ProxyCommand=ssh -o BatchMode=yes $L -W 127.0.0.1:$PORT")
for i in $(seq 1 $N); do
  timeout -s KILL 30 ssh $L "cd ~/scratch/rvtty3 && PORT=$PORT HOLD=600 bash bg.sh logs/sshboot-$T-$i.out bash sshboot.sh $T $K $i 8" >/dev/null
  for _ in $(seq 1 120); do r=$(timeout -s KILL 20 ssh $L "cat ~/scratch/rvtty3/logs/ssh-$T-$i.ready 2>/dev/null"); [ -n "$r" ] && break; sleep 5; done
  timeout -s KILL 200 python3 /scratch/solnix/rvtty3c/ptyssh.py $PORT > $R/$T-$i.pty 2>&1; cp /tmp/ptyssh-last.txt $R/$T-$i.transcript 2>/dev/null
  timeout -s KILL 120 env -u SSH_AUTH_SOCK ssh "${SO[@]}" -i /scratch/solnix/rvlogin/keys/wrong_ed25519 gburd@127.0.0.1 'echo WRONGKEY-GOT-IN' > $R/$T-$i.bad 2>&1; e2=$?
  timeout -s KILL 20 ssh $L "touch ~/scratch/rvtty3/logs/ssh-$T-$i.done"
  echo "proof $T boot $i [$r]: $(grep RESULT $R/$T-$i.pty) | wrongkey exit=$e2 $(grep -c WRONGKEY-GOT-IN $R/$T-$i.bad)"
  sleep 8
done
