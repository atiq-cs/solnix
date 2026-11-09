#!/usr/bin/env bash
# solnix-image-identity-gate.sh <image-file|root-dir> [...]
#
# Refuses any image (raw, raw.gz, .img, .img.gz, .zst, ISO, tar) that carries a personal identity or any credential
# material. The image equivalent of the NAR content gate. Run on the DECOMPRESSED bytes (we decompress here).
#
# infra 2026-11-06 asked it to refuse an image containing:
#   - a private key block (OpenSSH / PEM / PGP / PuTTY);
#   - a crypt hash for any account other than an empty or locked root;
#   - any authorized_keys, known_hosts, .netrc, .git-credentials, sops or age file;
#   - the strings `gburd`, `greg@burd.me` or `/home/gburd`.
#
# Exit 0 = clean (prints "CLEAN <file>"); 1 = REJECT (prints each finding, no secret VALUES — only the offending path and a
# label); 2 = usage, cannot read, or a container it found but could not open: never CLEAN on bytes it did not look at.
# It never prints a key body or a hash value.
#
# Scope: the content of the image and of every container inside it. An ISO or a tar is extracted (nothing is mounted) and
# every file in it is scanned: text files with the full rules, binary files with the strong-evidence byte rules
# (scan_bytes), and a file that is itself a container -- gzip, xz, zstd, bzip2, tar, cpio or ISO, recognised by its magic,
# not its name (the live media's boot_archive is a gzipped UFS image, solnix-store.iso an ISO of NARs) -- is opened and
# scanned the same way, down to GATE_MAXDEPTH (4) levels. An ISO is also byte-scanned whole, which covers its system area and
# the appended GPT partitions (ESP, scratch) that extraction does not see. A directory argument (an image root mounted
# read-only, or the ramdisk root before it is unmounted) gets the exact tree scan. A raw disk image is byte-scanned: we
# deliberately do not import a zpool or mount a UFS image here (never zpool import over ssh).
# shortcut: byte mode cannot see inside a compressed ZFS block or a .gz file inside a UFS/ZFS image, nor tell a credential
#   FILE by its name; gate the mounted root as a directory for that (the image builders have it mounted).
#
# Needs GNU grep (-a, -r, -Z), gzip, tr, od, dd (no strings(1)), plus xz/zstd/bzip2/cpio/xorriso (or bsdtar)/nix-store when such a container
# is met; a missing one is exit 2. Temp space: $TMPDIR, as large as the biggest container unpacked. Tested by
# scripts/test-image-identity-gate.sh, which asserts every fixture's EXIT CODE: the gate once printed REJECT and then CLEAN
# and exited 0, because its findings were raised in pipeline subshells.
set -u
export LC_ALL=C   # bytes, not characters: a UTF-8 locale makes grep -a slow and tr's classes multibyte
SELF=${0##*/}
MAXDEPTH=${GATE_MAXDEPTH:-4}
rej=0 err=0 any_rej=0 any_err=0

# tools. GNU grep is required: illumos /usr/bin/grep has no -r/-a/-Z, and a grep that cannot run a pattern reports
# "no match", i.e. CLEAN. strings(1) is not used: Debian cloud images have no binutils.
have() { command -v "$1" >/dev/null 2>&1; }
GREP=grep; have ggrep && GREP=ggrep
$GREP --version 2>/dev/null | $GREP -q 'GNU grep' || { echo "$SELF: needs GNU grep (ggrep or grep)" >&2; exit 2; }
have gzip && have od && have dd && have tr || { echo "$SELF: needs gzip, od, dd and tr" >&2; exit 2; }

# patterns. Values are never printed; we print the LABEL and the file path only.
# Private-key block headers (any kind). Text files only: in a text file a header is a key file.
PK_RE='-----BEGIN (OPENSSH|RSA|DSA|EC|ENCRYPTED|PGP|OPENSSH\ )?\ ?PRIVATE KEY( BLOCK)?-----|PuTTY-User-Key-File-'
# crypt hashes: $1$,$2a/b/y$,$5$,$6$,$y$,$gy$ ... in a passwd/shadow context.
CRYPT_RE='\$(1|2[aby]|5|6|y|gy|7)\$[./A-Za-z0-9]'
# identity strings. gburd as a token: no letter or digit on either side, and a line edge counts as a side (the old
# [^a-z0-9]gburd[^a-z0-9] missed "gburd:x:1000:..." at the start of a passwd line and "staff::10:gburd" at the end).
ID_RE='greg@burd[.]me|/home/gburd|(^|[^a-z0-9])gburd([^a-z0-9]|$)'
# credential/identity FILES by basename.
CRED_FILES='authorized_keys known_hosts .netrc .git-credentials .pgpass'
# sops/age material. An age identity is the prefix plus its 58-character upper-case Bech32 body; the bare prefix is not key
# material (a recipe that redacts age-keygen's example by pattern names it, and B18 also needs a body).
SOPS_RE='sops:|ENC\[AES256_GCM|AGE-SECRET-KEY-1[QPZRY9X8GF2TVDW0S3JN54KHCE6MUA7L]{58}|-----BEGIN AGE ENCRYPTED FILE-----|age1[0-9a-z]{58}'
# strong evidence in raw bytes (binaries, filesystem blocks): real key material only, never a bare header. The openssh
# binaries carry "BEGIN OPENSSH PRIVATE KEY" and sshd_config names ~/.ssh/id_ed25519 as TEXT. b3BlbnNzaC1rZXkt is base64
# "openssh-key-", the body of every OpenSSH private key; a PEM header counts only with a base64 body line after it.
# (Assembled from parts: the literal header + body text in this file would itself trip a secret scanner.)
KEYBODY_RE="b3Blbn"'NzaC1rZXkt|-----BEGIN PGP PRIVATE ''KEY BLOCK-----|PuTTY-User-Key-File-[0-9]'
PEMHDR_RE='-----BEGIN (RSA|EC|DSA|ENCRYPTED) PRIVATE ''KEY-----'
AGE_RE='AGE-SECRET-KEY-1[0-9A-Z]{20,}|ENC\[AES256_GCM,data:'
SHADOWLINE_RE='(^|[^A-Za-z0-9_.-])[A-Za-z0-9_][A-Za-z0-9_.-]*:\$(1|2[aby]|5|6|y|gy)\$[./A-Za-z0-9]'
IDBYTES_RE='greg@burd[.]me|/home/gburd|(^|[^A-Za-z0-9])gburd([^A-Za-z0-9]|$)'
ANY_RE="$KEYBODY_RE|$PEMHDR_RE|$AGE_RE|$IDBYTES_RE|$SHADOWLINE_RE|BEGIN OPENSSH PRIVATE ""KEY"

finding() { echo "REJECT $1: $2"; rej=1; }
fatal()   { echo "$SELF: $1" >&2; err=1; }

# shadow check: a crypt hash is allowed ONLY for root when the field is locked (*LK*, !, *, or empty). Anything else rejects.
scan_shadow() { # scan_shadow <path-label> <file>
  local lbl=$1 f=$2 user pw
  [ -r "$f" ] || return 0
  while IFS=: read -r user pw _; do
    case "$pw" in
      ''|'*'|'!'|'!!'|'*LK*'|'NP'|'UP'|'*NP*') continue ;;   # locked / no-login
    esac
    if printf '%s' "$pw" | $GREP -Eq -e "$CRYPT_RE"; then
      [ "$user" = root ] && finding "$lbl" "root has a set password hash (must be locked/empty in a public image)" \
        || finding "$lbl" "account '$user' has a password hash"
    fi
  done < "$f"
}

# grep's exit: 0 match, 1 none, >1 it could not read -- which must not read as "none"
g() { "$GREP" "$@"; local r=$?; [ $r -gt 1 ] && fatal "grep failed (rc $r) on ${*: -1}"; [ $r = 0 ]; }

# byte scan of one file: a raw image (or block device), or a binary file inside a tree. One streaming pass: tr -cs turns
# every run of non-printable bytes into one newline (grep -a buffers a whole "line", and a raw image's gigabytes of zeros
# would be one line), and grep keeps only the lines that can hold a finding, plus the next one (a PEM body follows its
# header). Every pattern is printable ASCII, so the reduction loses none, and a run boundary is a word boundary for the
# identity rule as any non-alphanumeric byte is. A read error is an error, never "no match".
scan_bytes() { # scan_bytes <file> <label>
  local f=$1 lbl=$2 h=$TMPD/hits ps
  tr -cs '\040-\176' '\n' < "$f" 2>/dev/null | $GREP -aE -A1 -e "$ANY_RE" > "$h"; ps="${PIPESTATUS[0]} ${PIPESTATUS[1]}"
  case "$ps" in "0 0"|"0 1") : ;; *) fatal "$lbl: could not read it (tr/grep rc $ps)"; return ;; esac
  { g -aqE -e "$KEYBODY_RE" "$h" || $GREP -aA1 -E -e "$PEMHDR_RE" "$h" | $GREP -aqE '^[A-Za-z0-9+/]{40}'; } \
    && finding "$lbl" "private key BODY (byte scan: real key material)"
  g -aqE -e "$AGE_RE" "$h" && finding "$lbl" "age secret / sops ciphertext (byte scan)"
  g -aqE -e "$IDBYTES_RE" "$h" && finding "$lbl" "maintainer identity string (byte scan)"
  g -aqE -e "$SHADOWLINE_RE" "$h" && finding "$lbl" "shadow-shaped line with a password hash (byte scan)"
  # inconclusive marker -> WARN only (the ssh binaries carry this header as a template)
  if g -aq "BEGIN OPENSSH PRIVATE ""KEY" "$h" && ! g -aq "b3Blbn""NzaC1rZXkt" "$h"; then
    echo "WARN $lbl: BEGIN-OPENSSH marker with no key body (likely the ssh binaries template)"; fi
  return 0
}

# what a file is, by its first bytes (ISO9660: "CD001" at byte 32769). Prints gz|xz|zst|bz2|cpio|nar|iso|tar or nothing.
kind_of() { # kind_of <file>
  local m
  m=$(od -An -tx1 -N6 "$1" 2>/dev/null | tr -d ' \n')
  case "$m" in
    1f8b*) echo gz; return ;; fd377a585a00) echo xz; return ;; 28b52ffd*) echo zst; return ;; 425a68*) echo bz2; return ;;
    303730373031*|303730373032*|303730373037*|c771*|71c7*) echo cpio; return ;;
    0d0000000000) [ "$(dd if="$1" bs=1 skip=8 count=13 2>/dev/null | tr -d '\000')" = nix-archive-1 ] && { echo nar; return; } ;;
  esac
  [ "$(dd if="$1" bs=1 skip=32769 count=5 2>/dev/null | tr -d '\000')" = CD001 ] && { echo iso; return; }
  [ "$(dd if="$1" bs=1 skip=257 count=5 2>/dev/null | tr -d '\000')" = ustar ] && echo tar
}

# true iff every error line names a device node it could not create (mknod), plus the tools' summary lines
only_mknod() { # only_mknod <stderr-file>
  [ -s "$1" ] || return 1
  ! $GREP -vE 'Cannot mknod: Operation not permitted|Exiting with failure status due to previous errors|^[0-9]+ blocks?$' "$1" | $GREP -q .
}

# unpack a container into <dest>: archives as a tree, streams as <dest>/data. Nonzero if it cannot.
open_container() { # open_container <kind> <file> <dest>
  local k=$1 f=$2 d=$3
  case "$k" in
    gz)   gzip -dc "$f" > "$d/data" ;;
    xz)   have xz && xz -dc "$f" > "$d/data" ;;
    zst)  have zstd && zstd -qdc "$f" > "$d/data" ;;
    bz2)  have bzip2 && bzip2 -dc "$f" > "$d/data" ;;
    # A device node in an archive (test fixtures: util-tests' cpio/files hold a block node) cannot be created without
    # privilege and carries no content; the archive's regular files still extract, so that one refusal is not an error.
    tar)  tar -C "$d" -xf "$f" 2>"$d.err" || only_mknod "$d.err" ;;
    cpio) have cpio && { (cd "$d" && cpio -idm --quiet --no-absolute-filenames < "$f" 2>"$d.err") || only_mknod "$d.err"; } ;;
    nar)  have nix-store && nix-store --restore "$d/nar" < "$f" 2>/dev/null ;;
    iso)  { if have xorriso; then xorriso -osirrox on -indev "$f" -extract / "$d" >/dev/null 2>&1
            elif have bsdtar; then bsdtar -C "$d" -xf "$f" 2>/dev/null; else false; fi; } || return 1
          chmod -R u+rwX "$d" 2>/dev/null; return 0 ;;   # xorriso keeps the ISO's read-only modes; the temp dir must go
    *)    false ;;
  esac
}

# scan one file: a container is opened and what is inside scanned; anything else is byte-scanned
scan_file() { # scan_file <file> <label> <depth>
  local f=$1 lbl=$2 dep=$3 k sub
  k=$(kind_of "$f")
  [ -n "$k" ] || { scan_bytes "$f" "$lbl"; return; }
  [ "$dep" -lt "$MAXDEPTH" ] || { fatal "$lbl: $k container nested deeper than $MAXDEPTH (GATE_MAXDEPTH)"; return; }
  sub=$(mktemp -d "$TMPD/c.XXXXXX") || { fatal "mktemp failed"; return; }
  if open_container "$k" "$f" "$sub"; then
    case "$k" in
      gz|xz|zst|bz2) scan_file "$sub/data" "$lbl!$k" $((dep + 1)) ;;
      *) scan_tree "$sub" "$lbl!$k:" $((dep + 1)); [ "$k" = iso ] && scan_bytes "$f" "$lbl(whole iso)" ;;
    esac
  else
    fatal "$lbl: cannot open the $k container (missing tool, or corrupt)"
  fi
  rm -rf "$sub"
}

# scan a tree. Every finding is raised in THIS shell (process substitution), never in `cmd | while`: a finding raised in a
# pipeline subshell is lost with that subshell.
scan_tree() { # scan_tree <root> <label-prefix> <depth>
  local root=$1 pfx=$2 dep=$3 f n s
  for n in $CRED_FILES; do
    while IFS= read -r -d '' f; do finding "$pfx${f#"$root"}" "credential file '$n'"; done \
      < <(find "$root" -xdev -name "$n" -type f -print0 2>/dev/null)
  done
  while IFS= read -r -d '' f; do finding "$pfx${f#"$root"}" "sops/age file"; done \
    < <(find "$root" -xdev -type f \( -name '*.sops.yaml' -o -name '*.agekey' -o -name 'keys.txt' \) -path '*sops*' -print0 2>/dev/null)
  for s in etc/shadow etc/security/passwd; do [ -f "$root/$s" ] && scan_shadow "$pfx/$s" "$root/$s"; done
  # text files: the full rules
  while IFS= read -r -d '' f; do finding "$pfx${f#"$root"}" "private key block"; done < <($GREP -rIlZE -e "$PK_RE" "$root" 2>/dev/null)
  while IFS= read -r -d '' f; do finding "$pfx${f#"$root"}" "sops/age-encrypted content"; done < <($GREP -rIlZE -e "$SOPS_RE" "$root" 2>/dev/null)
  while IFS= read -r -d '' f; do finding "$pfx${f#"$root"}" "maintainer identity string"; done < <($GREP -rIlZE -e "$ID_RE" "$root" 2>/dev/null)
  # a file the scan cannot read would be "no match": refuse instead
  while IFS= read -r -d '' f; do fatal "$pfx${f#"$root"}: unreadable, not scanned"; done < <(find "$root" -xdev -type f ! -readable -print0 2>/dev/null)
  # the files -I skipped (binary, plus empty ones): containers are opened and scanned; the rest get the byte rules, in bulk
  local bin; bin=$(mktemp "$TMPD/b.XXXXXX") || { fatal "mktemp failed"; return; }
  while IFS= read -r -d '' f; do
    [ -s "$f" ] || continue
    if [ -n "$(kind_of "$f")" ]; then scan_file "$f" "$pfx${f#"$root"}" "$dep"; else printf '%s\0' "$f" >> "$bin"; fi
  done < <($GREP -rLZI -e '' "$root" 2>/dev/null)
  bulk_bytes "$bin" "$root" "$pfx"
  rm -f "$bin"
}

# scan_bytes's rules over a NUL-separated list of (binary, non-container) files, one grep per rule for the whole list.
# The template WARN is left out here: every ssh binary would raise it.
bulk_bytes() { # bulk_bytes <list> <root> <label-prefix>
  local l=$1 root=$2 pfx=$3 f
  [ -s "$l" ] || return 0
  while IFS= read -r -d '' f; do finding "$pfx${f#"$root"}" "private key BODY (byte scan: real key material)"; done \
    < <(xargs -0 $GREP -alZE -e "$KEYBODY_RE" < "$l")
  while IFS= read -r -d '' f; do $GREP -aA1 -E -e "$PEMHDR_RE" "$f" | $GREP -aqE '^[A-Za-z0-9+/]{40}' \
      && finding "$pfx${f#"$root"}" "private key BODY (byte scan: PEM)"; done < <(xargs -0 $GREP -alZE -e "$PEMHDR_RE" < "$l")
  while IFS= read -r -d '' f; do finding "$pfx${f#"$root"}" "age secret / sops ciphertext (byte scan)"; done \
    < <(xargs -0 $GREP -alZE -e "$AGE_RE" < "$l")
  while IFS= read -r -d '' f; do finding "$pfx${f#"$root"}" "maintainer identity string (byte scan)"; done \
    < <(xargs -0 $GREP -alZE -e "$IDBYTES_RE" < "$l")
  while IFS= read -r -d '' f; do finding "$pfx${f#"$root"}" "shadow-shaped line with a password hash (byte scan)"; done \
    < <(xargs -0 $GREP -alZE -e "$SHADOWLINE_RE" < "$l")
}

process() { # process <file|dir>
  local img=$1 base=${1##*/}
  rej=0 err=0
  if [ -d "$img" ]; then scan_tree "$img" "$base:" 0
  elif [ -r "$img" ]; then scan_file "$img" "$base" 0   # a raw disk image is no container: byte scan
  else fatal "cannot read $img"; fi
  [ $rej = 0 ] && [ $err = 0 ] && echo "CLEAN $base"
  [ $err = 1 ] && [ $rej = 0 ] && echo "ERROR $base: not fully scanned (see stderr); not CLEAN"
  any_rej=$((any_rej | rej)); any_err=$((any_err | err))
}

[ $# -ge 1 ] || { echo "usage: $SELF <image|root-dir> [...]" >&2; exit 2; }
TMPD=$(mktemp -d) || exit 2
trap 'rm -rf "$TMPD"' EXIT
for a in "$@"; do process "$a"; done
[ $any_rej = 1 ] && exit 1
[ $any_err = 1 ] && exit 2
exit 0
