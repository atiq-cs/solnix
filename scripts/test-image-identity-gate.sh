#!/usr/bin/env bash
# test-image-identity-gate.sh [gate]: solnix-image-identity-gate.sh against crafted images. Every case asserts the gate's EXIT
# CODE and its verdict line: the gate once printed "REJECT" and then "CLEAN" and exited 0 (findings raised in a pipeline
# subshell), and a test that read only the printed line passed it. The key material is fake (a valid-looking body prefix,
# no real key). Runs on Linux or illumos; needs GNU grep, gzip, tar, xorriso (else the ISO cases are SKIP and the test
# fails), and nix-store for the NAR case.
#   gate   the script to test (default: the one beside this file). Point it at an old gate for a negative control.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
G=${1:-$HERE/solnix-image-identity-gate.sh}
export LC_ALL=C
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
cd "$W" || exit 2
have() { command -v "$1" >/dev/null 2>&1; }
pass=0 fail=0 skip=0

# Assembled from parts so the committed text is no key block (it would trip gitleaks, as gate-checks.py's selftest does).
H='-----BEGIN OPENSSH PRIVATE ''KEY-----' T='-----END OPENSSH PRIVATE ''KEY-----'
KEY="$H
b3Blbn""NzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
$T"
# a root with the shape of the live media's root: passwd/shadow with locked accounts, an sshd binary-ish blob carrying the
# header TEMPLATE (as the openssh binaries do), a config naming ~/.ssh/id_ed25519
mkroot() { # mkroot <dir>
  mkdir -p "$1/etc/ssh" "$1/root" "$1/usr/bin" "$1/platform"
  printf 'root:x:0:0:Super-User:/root:/sbin/sh\nnobody:x:60001:60001::/:\n' > "$1/etc/passwd"
  printf 'root::19000::::::\nnobody:*LK*:6445::::::\n' > "$1/etc/shadow"
  printf '#IdentityFile ~/.ssh/id_ed25519\n' > "$1/etc/ssh/ssh_config"
  printf '\177ELF\0\0\0%s\0%%s\0' "$H" > "$1/usr/bin/ssh-keygen"
}
mkiso() { xorriso -as mkisofs -R -o "$1" "$2" >/dev/null 2>&1; }   # mkiso <out.iso> <dir>
mktar() { tar -C "$2" -cf "$1" .; }                                # mktar <out.tar> <dir>

# expect <want-exit> <want-line-regex> <name> <file>
expect() {
  local want=$1 re=$2 name=$3 f=$4 out rc
  [ -e "$f" ] || { echo "SKIP $name (fixture not built: missing tool)"; skip=$((skip + 1)); return; }
  out=$(bash "$G" "$f" 2>&1); rc=$?
  if [ "$rc" = "$want" ] && printf '%s\n' "$out" | grep -qE -e "$re"; then echo "PASS $name (exit $rc)"; pass=$((pass + 1))
  else echo "FAIL $name: exit $rc (want $want), output:"; printf '%s\n' "$out" | sed 's/^/    /'; fail=$((fail + 1)); fi
}

# --- clean fixtures (must exit 0) ---
mkroot clean; mktar clean.tar clean
mkdir -p ciso/platform/i86pc/amd64; mkroot cba; mktar cba.tar cba; gzip -c cba.tar > ciso/platform/i86pc/amd64/boot_archive
mkroot cst; nix-store --dump cst > ciso/x.nar 2>/dev/null || true
have xorriso && mkiso clean.iso ciso
# --- bad fixtures (each must exit 1) ---
mkroot k1; printf '%s\n' "$KEY" > k1/etc/ssh/ssh_host_ed25519_key; mktar key.tar k1
mkroot c1; mkdir -p c1/root/.ssh; printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample nobody@example\n' > c1/root/.ssh/authorized_keys; mktar cred.tar c1
mkroot i1; printf 'gburd:x:1000:10::/home/user:/bin/sh\n' >> i1/etc/passwd; mktar ident.tar i1
mkroot i2; printf 'staff::10:gburd\n' > i2/etc/group; mktar ident-eol.tar i2
mkroot h1; printf 'bob:$6$abcdefgh$0123456789abcdefABCDEF./:19000::::::\n' >> h1/etc/shadow; mktar hash.tar h1
if have xorriso; then
  mkroot ba; printf '%s\n' "$KEY" > ba/etc/ssh/ssh_host_ed25519_key; mktar ba.tar ba
  mkdir -p kiso/platform/i86pc/amd64; gzip -c ba.tar > kiso/platform/i86pc/amd64/boot_archive; mkiso key-in-bootarchive.iso kiso
  mkdir -p inner; printf '%s\n' "$KEY" > inner/id_ed25519; mkiso inner.iso inner
  mkdir -p outer; mv inner.iso outer/solnix-store.iso; mkiso nested.iso outer
  # the key only in an appended partition (the ESP/scratch shape): not in any file the ISO's directory tree lists
  mkdir -p piso; printf 'x\n' > piso/README; printf '%s\n' "$KEY" > part.img; dd if=/dev/zero bs=1k count=64 >> part.img 2>/dev/null
  xorriso -as mkisofs -R -o key-in-partition.iso -append_partition 2 0xef part.img piso >/dev/null 2>&1
fi
mkroot n1; printf '%s\n' "$KEY" > n1/etc/ssh/ssh_host_ed25519_key; nix-store --dump n1 > key.nar 2>/dev/null || rm -f key.nar
[ -s key.nar ] && gzip -c key.nar > key.nar.gz
# raw byte mode (what ami-bank.sh runs on the raw device): a key in the middle of a sparse-ish raw image, past BIG
{ dd if=/dev/zero bs=1M count=70 2>/dev/null; printf '%s\n' "$KEY"; dd if=/dev/zero bs=1M count=2 2>/dev/null; } > key-raw.img
{ dd if=/dev/zero bs=1M count=70 2>/dev/null; printf 'nothing\n'; } > clean-raw.img
{ dd if=/dev/zero bs=1k count=8 2>/dev/null; printf 'gburd:x:1000:10::/export/home/x:/bin/sh\n'; } > ident-raw.img
# a tar holding a device node (util-tests' cpio fixtures do): extraction cannot mknod unprivileged; the regular files
# must still be scanned, clean -> exit 0, with a key beside the node -> exit 1. Built with python's tarfile (no root).
if have python3; then
  python3 - "$KEY" <<'PY'
import io, sys, tarfile
for name, extra in (("devnode.tar", None), ("devnode-key.tar", sys.argv[1].encode() + b"\n")):
    with tarfile.open(name, "w", format=tarfile.USTAR_FORMAT) as t:
        n = tarfile.TarInfo("node"); n.type = tarfile.BLKTYPE; n.devmajor, n.devminor = 13, 17; t.addfile(n)
        d = b"hello\n"; i = tarfile.TarInfo("etc/motd"); i.size = len(d); t.addfile(i, io.BytesIO(d))
        if extra: i = tarfile.TarInfo("etc/ssh/ssh_host_ed25519_key"); i.size = len(extra); t.addfile(i, io.BytesIO(extra))
PY
fi
# a corrupt container must not read as CLEAN
printf '\037\213\010\000garbage' > corrupt.gz

expect 0 '^CLEAN clean.tar$'  "clean tar"                   clean.tar
expect 0 '^CLEAN clean.iso$'  "clean ISO (gz boot_archive + NAR inside)" clean.iso
expect 0 '^CLEAN clean-raw.img$' "clean raw image (byte mode)" clean-raw.img
expect 1 'REJECT key.tar.*private key'   "private key in a tar"       key.tar
expect 1 "REJECT cred.tar.*credential file 'authorized_keys'" "credential file in a tar" cred.tar
expect 1 'REJECT ident.tar.*identity'    "identity string at line start in a tar" ident.tar
expect 1 'REJECT ident-eol.tar.*identity' "identity string at line end in a tar" ident-eol.tar
expect 1 "REJECT hash.tar.*account 'bob' has a password hash" "non-root password hash in a tar" hash.tar
expect 1 'REJECT key-in-bootarchive.iso!iso:/platform/i86pc/amd64/boot_archive!gz!tar:/etc/ssh/ssh_host_ed25519_key' \
         "key in a gzipped boot_archive inside an ISO" key-in-bootarchive.iso
expect 1 'REJECT nested.iso!iso:/solnix-store.iso!iso:/id_ed25519' "key in an ISO inside an ISO" nested.iso
expect 1 'REJECT key-in-partition.iso\(whole iso\)' "key only in an appended ISO partition" key-in-partition.iso
expect 1 'REJECT key.nar' "key in a NAR"                key.nar
expect 1 'REJECT key.nar.gz!gz' "key in a gzipped NAR"   key.nar.gz
expect 1 'REJECT key-raw.img: private key BODY' "key in a raw image (byte mode, ami-bank.sh)" key-raw.img
expect 1 'REJECT ident-raw.img: maintainer identity' "identity at line start in a raw image (byte mode)" ident-raw.img
expect 2 '^ERROR corrupt.gz' "corrupt gzip: not CLEAN"   corrupt.gz
expect 0 '^CLEAN devnode.tar$' "tar with a device node: CLEAN" devnode.tar
expect 1 'REJECT devnode-key.tar.*private key' "tar with a device node and a key: REJECT" devnode-key.tar

echo "test-image-identity-gate: $pass pass, $fail fail, $skip skip ($G)"
[ $fail = 0 ] && [ $skip = 0 ]
