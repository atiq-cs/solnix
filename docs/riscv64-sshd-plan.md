# Step 5: what a remote login for gburd needs (plan only, nothing shipped)

Per the brief, telnet or any login without crypto is not acceptable for a hosted server, so none was shipped. This is
what sshd needs on this kernel, measured against the tree (rvsrv final kernel `unix-final`, newlib 4.5.0 glue in
`src/riscv/pkg/solnix-libc/glue.c`).

## The choice: dropbear, statically linked, not OpenSSH

* dropbear (MIT license) is one static binary with its own libtomcrypt and libtommath. It needs no libcrypto, no PAM
  and no dynamic loader, and it was built for small libcs (uClibc, musl).
* OpenSSH needs OpenSSL/LibreSSL libcrypto (about 3 MB of C plus perl to configure), privilege-separation users,
  `chroot`, `setgroups` and fd passing over AF_UNIX (that last one exists here: SCM_RIGHTS). It comes after dropbear.
* Both would be built the way rvpkg built dash: `solnix-cc`, static ET_EXEC at 0x40010000, newlib.

## Kernel / libc gaps, each checked in the tree

| Need | State on unix-final | Work |
|---|---|---|
| TCP listen/accept/read/write/close, fork per connection | REAL: inettest tcpecho, 110 conns/boot, 4/4 | none |
| `poll` on a socket + a pty master | REAL for sockets (inet_poll). No pty | pty below |
| pseudo-terminals (`/dev/ptmx`, `grantpt`, `ptsname`, a slave tty the shell runs on) | ABSENT: the only tty is the console (proc_ioctl answers TCGETS for an empty fd 0-2) | a pty pair = two byte rings like uproc.c's pipe, plus a termios struct per pair. This is the largest item |
| termios `tcgetattr`/`tcsetattr`, raw mode, `TIOCGWINSZ`/`TIOCSWINSZ`, `SIGWINCH` | ABSENT (rvsh §6: console is line mode, tcsetattr ENOTTY) | per-tty termios with ICANON/ECHO/ISIG, done in the pty line discipline |
| `setsid`, controlling tty, `SIGHUP` on hangup | glue.c:976 `setsid` is an ENOSYS stub | session id + ctty in proc_t |
| `setuid`/`setgid`/`getuid` | REAL (R-P11, p_uid/p_gid) | `setgroups`/`initgroups`: stubs are fine for one user |
| `/etc/passwd`, `getpwnam` | REAL (`/etc/passwd`, login stage) | add gburd, home `/home/gburd`, shell `/bin/dash` |
| password or public-key auth | `/etc/shadow` crypt absent | public keys only: `~gburd/.ssh/authorized_keys` in the root image, password auth disabled |
| entropy (`/dev/urandom` or `getrandom`) | ABSENT. inet.c's ISN generator is xorshift on the `time` CSR, NOT crypto | a must for key exchange: seed a ChaCha20 DRBG from the qemu `virtio-rng` device (`-device virtio-rng-device`, a third virtio class like vioblk) and expose `getrandom(278)` + `/dev/urandom`. Without it, sshd is insecure, not merely weak |
| a persistent host key | the SNFS `/data` disk persists across boots (R-P12) | generate once with `dropbearkey` into `/data/dropbear_ed25519_host_key` |
| signals with illumos numbering | rvsh §6: not done | dropbear uses SIGCHLD/SIGPIPE/SIGHUP/SIGTERM; it works with the Linux numbers the kernel uses today |
| exec from the ramfs | ABSENT (rvsh §6) | not needed: the binaries live in the root ustar |
| syscall pointer validation | **FOUND this track**: syscalls dereference user pointers with SUM=1, and copyin/copyout check no range, so a U-mode pointer into a kernel slot (now: all of DRAM) is read or written by the kernel | before any network-facing daemon runs: copyin/copyout and the direct-deref paths must reject an address outside the user slots (`hat_user_range_ok`) |
| dynamic loader | not needed for a static dropbear | `elf.c` is ET_EXEC only. ld.so.1 is for later |

## Order

1. Syscall pointer validation (a security bug, independent of sshd).
2. virtio-rng + `getrandom` + `/dev/urandom`.
3. ptys + termios + `setsid`/ctty.
4. dropbear static build with `solnix-cc`; host key on `/data`; `authorized_keys` for gburd.
5. Proof from the host: `ssh -p 2222 gburd@127.0.0.1` through `hostfwd=tcp::2222-:22`, run `id; uname -a`, and a
   negative control: a wrong key is refused.
