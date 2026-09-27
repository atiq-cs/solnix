# Remote SSH install must actually WORK (measured on the X1, tui11 — it did NOT)

## The failure (tui11, X1 at 192.168.1.124)
tui11's `solnix-install --ssh` started sshd; key auth + login worked; commands ran (rc=0). But sshd
delivered ZERO stdout to the client, and connections dropped intermittently (rc=255). Verified 5 ways
from the dev box (same LAN): plain `ssh cmd`, `ssh -T`, `ssh -tt`, `ssh 'cmd > file'` + scp readback,
and `ssh 'cat file'` — all returned 0 bytes though the box was reachable (ping 0% loss, :22 open).

Result: an operator can start sshd but a remote helper cannot SEE command output — so cannot drive or
debug the install remotely. That defeats the point of `--ssh`.

## Root cause — NOT yet established (do NOT guess-fix)
Key clue: the EXEC channel (no pty) also produced no stdout. So it is NOT merely a missing /dev/pts
(that would break `-tt` interactive only, not plain `ssh cmd`). The fork'd sshd session cannot write
its stdout pipe at all. Leading hypotheses (unconfirmed):
  1. OpenSSH 9.x split-process model: sshd-session / sshd-auth mis-staged so the session's data pipe
     is not wired (auth + exit-status work; stdout does not).
  2. A missing runtime lib in the sshd-session closure (the same second-order lib class that broke
     curl/dig) — the helper starts but its stdio is broken.
  3. /dev/pts (devpts) not mounted — would explain the -tt failure but not the exec-channel failure.

## The fix process (measure in KVM, where output IS visible)
The NEXT image's KVM boot-verify MUST include a REMOTE-SSH-STDOUT check and it must pass before ship:
  - boot the image under KVM with hostfwd tcp:127.0.0.1:2222-:22
  - run `solnix-install --ssh` (or SOLNIX_SSHD=1) inside the guest
  - from the dev box: `ssh -p 2222 root@127.0.0.1 'echo REMOTE-OK; zpool list'`
  - ASSERT "REMOTE-OK" comes back on stdout (this reproduces the X1 failure).
Then iterate the fix (mount /dev/pts; verify the sshd-session helper + its lib closure; check
sshd_config UsePAM / Subsystem) until the echo round-trips. Add this as a boot-phase check in
scripts/image-acceptance-test.sh so it cannot regress.

Until remote-ssh-stdout is proven in KVM, the operator drives the install at the CONSOLE and uses the
die() paste.rs failure-log upload for off-host debugging (that path works).
