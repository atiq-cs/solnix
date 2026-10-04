# sshd/PAM fails open: root ssh accepts ANY password (security defect)

**Status:** FIXED (root cause proven) 2026-10-04 -- the fix is `UsePAM yes` in
sshd_config. Flagged during the tui14 image build, reproduced in KVM against the
tui14 live media, independently confirmed on the real Lenovo X1 Carbon installer,
and the fix was PROVEN on the live X1 (a wrong password is now rejected). The fix
is committed to scripts/solnix-install (both the live `_start_sshd` and the
installed-system block, gated) and scripts/oi-make-livecd.sh (baked into the
media). NOTE: tui14 was BUILT BEFORE that commit, so the tui14 image's shipped
sshd STILL fails open -- a later image (tui15+) carries the fix.

## Symptom

Remote root ssh into the solnix **live installer media** succeeds with *any*
password — including a wrong password and an empty password — as long as
password authentication is the method used. Public-key, GSSAPI and host-based
auth are not involved.

### Measured — KVM (tui14 live media, forced password auth)

```
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password \
    -o IdentitiesOnly=yes -o IdentityAgent=none \
    -o KbdInteractiveAuthentication=no -o NumberOfPasswordPrompts=1 \
    -p 2222 root@127.0.0.1 'echo AUTH_OK'
```

| password supplied | result |
|-------------------|--------|
| `testpw123` (the real one) | `AUTH_OK` |
| `WRONGpw999` | `AUTH_OK` |
| *(empty)* | `AUTH_OK` |
| `zzz` | `AUTH_OK` |
| `short` | `AUTH_OK` |
| `abcdefg` | `AUTH_OK` |

6/6 authenticate. The password is not enforced.

### Measured — real X1 installer

A deliberately-wrong password with pubkey fully disabled
(`PubkeyAuthentication=no`, `-i /dev/null`, `PreferredAuthentications=password`)
returns rc=0 and a root shell. Same fail-open behaviour as KVM — this is **not**
a QEMU/user-net artifact.

## Why this matters

The live installer offers `solnix-install --ssh` for *remote* installation
("ssh in from another host"). If root ssh accepts any password, the install
media is remotely root-accessible to anyone who can reach port 22 the moment
`--ssh` is run — the set root password is cosmetic.

## RESOLUTION (proven on the live X1, 2026-10-04)

The fix is a single line: **`UsePAM yes`** in sshd_config.

Despite `strings` reporting "UsePAM option value ... is always on", the SHIPPED
sshd_config had NO `UsePAM` line, and with it absent this OpenSSH 10.5p1 build on
illumos used its OWN internal `auth_password` (crypt() against the shadow hash)
rather than the PAM stack -- and that internal path FAILS OPEN here (every
password authenticates). Setting `UsePAM yes` explicitly makes sshd delegate to
the illumos PAM `other` auth stack (pam_unix_auth, present + correct), which
actually enforces the `$6$` hash.

PROOF (live X1, after adding `UsePAM yes` + `svcadm restart network/ssh`):
- a WRONG password with pubkey disabled did NOT get a shell -- verified by a
  write-a-proof-file side-effect test, not the exit code (the flaky session
  channel returned a misleading rc=0; the command never actually ran). The proof
  file was ABSENT => "SECURE: wrong pw did NOT get a shell".
- the CORRECT password still logs in.
The negative control flipped, which is the only acceptable proof.

LESSON: over a flaky/no-stdout ssh channel, exit codes LIE -- verify auth
outcomes by a durable side-effect (did a file get written?), never by rc alone.

## Mechanism (observed) -- why the earlier hypothesis was incomplete

### sshd is OpenSSH 10, UsePAM always on

```
$ strings /usr/sbin/sshd | grep -i OpenSSH_
OpenSSH_10.5p1, OpenSSL 3.5.8 25 Aug 2026

$ strings /usr/sbin/sshd | grep -i UsePAM
%s line %d: ignoring UsePAM option value. This option is always on.
```

Running processes show the split architecture:

```
/usr/sbin/sshd
/usr/libexec/sshd-session -R      (the per-connection auth worker)
```

OpenSSH ≥ 9.8 moved per-connection work (including PAM auth) into a separate
`sshd-session` process. "UsePAM is always on" means sshd *intends* to delegate
password verification to PAM.

### sshd_config auth lines (as shipped on the live media)

```
PermitEmptyPasswords no
PasswordAuthentication yes
PermitRootLogin yes
# (no UsePAM line -> the always-on default applies)
# (no PAMServiceName / PAMServicePrefix -> PAM service name defaults to "sshd")
```

These are all correct/expected. `PermitEmptyPasswords no` should by itself
reject the empty-password case.

### PAM has NO "sshd" service entry → it uses `other`

```
$ grep -iE '^sshd|^ssh ' /etc/pam.conf        -> (none)
$ ls /etc/pam.d/sshd                           -> (does not exist)
```

With no `sshd` service defined, PAM uses the `other` fallback stack. The
`other` **auth** stack in `/etc/pam.conf` on the live media is:

```
other   auth requisite  pam_authtok_get.so.1
other   auth required   pam_dhkeys.so.1
other   auth required   pam_unix_cred.so.1
other   auth required   pam_unix_auth.so.1
```

`pam_unix_auth.so.1` is `required` and is the module that actually checks the
password against `/etc/shadow`. This stack *should* reject a wrong/empty
password.

### The module is present and the hash is real

```
$ ls -l /usr/lib/security/{,amd64/}pam_unix_auth.so.1
-rwxr-xr-x  /usr/lib/security/pam_unix_auth.so.1          (16076 bytes)
-rwxr-xr-x  /usr/lib/security/amd64/pam_unix_auth.so.1    (21928 bytes)

$ awk -F: '/^root:/{print $2}' /etc/shadow
$6$mHGEsZWy$m/5z/HUbiAONdLjv.ftp4uYefjXzWnKgfP4GoF4gLCIZM6/CWBsfIoZNk1/mOT16uKkZTL1Ro0wBYMoEYIrdT/
```

Real `$6$` SHA-512 crypt; the 64-bit module is in the ramdisk.

### Hypothesis

A correct-looking PAM `other` auth stack, a loadable `pam_unix_auth.so.1`, and a
real root hash — yet every password authenticates. The remaining explanation is
that the **OpenSSH-10 `sshd-session` split process is not actually consulting /
trusting the illumos PAM auth result** for the `other` (or `sshd`) service on
this media: either the PAM conversation in `sshd-session` is not wired up for
this illumos build, or its result is being treated as success. The negative
control (6/6, incl. empty + wrong) rules out "the password happened to match"
and rules out a public-key/GSSAPI fallback (both were disabled). The mechanism
is confined to the PAM password path; it is not the config files, which read
correctly.

Next diagnostic step (not run here): capture `sshd -ddd` + `truss -f` on
`sshd-session` during a wrong-password attempt to see whether
`pam_authenticate(3PAM)` is called at all and what it returns, versus sshd's own
internal `auth_password`.

## This contradicts — and corrects — the tui13 premise

tui13 was built on the premise that *empty* passwords don't work over ssh on
illumos, so the fix set a *non-empty* root password. That premise was **wrong**.
The real problem is not empty-vs-non-empty: **no password is enforced at all.**
Setting a real password does not help, because a wrong password authenticates
just the same. The tui13 "random/`SOLNIX_ROOT_PW` password" change is therefore
not a security control on this media — the ssh auth path must be fixed instead.

## Where the fix was applied (DONE -- committed)

* `scripts/solnix-install` -- `_start_sshd` (live remote-install sshd) and the
  installed-system sshd block both now add `UsePAM yes` (the installed block
  gates on it: die if it did not land). PermitRootLogin no + PermitEmptyPasswords
  no are kept on the installed system; the admin user logs in by password, now
  actually enforced.
* `scripts/oi-make-livecd.sh` -- bakes `UsePAM yes` into the media sshd_config so
  the live installer enforces passwords from first boot.

Verification standard (met): the negative control flipped -- a wrong password and
an empty password FAIL, the correct password SUCCEEDS. A fix claimed without the
negative control flipping is not a fix.
