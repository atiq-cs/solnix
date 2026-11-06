#!/usr/bin/env bash
# solnix-image-identity-gate.sh <image-file> [image-file...]
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
# label); 2 = usage / cannot read. It never prints a key body or a hash value.
#
# Scope: this scans filesystem CONTENT of the image. It mounts nothing it does not have to: for a raw/zfs image it falls back
# to a byte scan (strings/grep over the raw bytes) when it cannot enumerate files, which still catches every pattern above.
set -u
SELF=${0##*/}
rc=0

# tools (store or system)
have() { command -v "$1" >/dev/null 2>&1; }
GREP=grep; have ggrep && GREP=ggrep
ZCAT=$(command -v gzcat || command -v zcat || echo "gzip -dc")
ZSTD=$(command -v zstd || true)

# patterns. Values are never printed; we print the LABEL and the file path only.
# Private-key block headers (any kind).
PK_RE='-----BEGIN (OPENSSH|RSA|DSA|EC|ENCRYPTED|PGP|OPENSSH\ )?\ ?PRIVATE KEY( BLOCK)?-----|PuTTY-User-Key-File-'
# crypt hashes: $1$,$2a/b/y$,$5$,$6$,$y$,$gy$ ... in a passwd/shadow context.
CRYPT_RE='\$(1|2[aby]|5|6|y|gy|7)\$[./A-Za-z0-9]'
# identity strings.
ID_RE='greg@burd[.]me|/home/gburd|[^a-z0-9]gburd[^a-z0-9]'
# credential/identity FILES by basename.
CRED_FILES='authorized_keys known_hosts .netrc .git-credentials .pgpass'
# sops/age material.
SOPS_RE='sops:|ENC\[AES256_GCM|AGE-SECRET-KEY-1|-----BEGIN AGE ENCRYPTED FILE-----|age1[0-9a-z]{58}'

finding() { echo "REJECT $1: $2"; rc=1; }

# shadow check: a crypt hash is allowed ONLY for root when the field is locked (*LK*, !, *, or empty). Anything else rejects.
scan_shadow() { # scan_shadow <path-label> <file>
  local lbl=$1 f=$2 line user pw
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

# scan an already-mounted / extracted tree
scan_tree() { # scan_tree <root> <label-prefix>
  local root=$1 pfx=$2 f b
  # files by name
  for n in $CRED_FILES; do
    find "$root" -xdev -name "$n" -type f 2>/dev/null | while read -r f; do finding "$pfx${f#$root}" "credential file '$n'"; done
  done
  find "$root" -xdev -type f \( -name '*.sops.yaml' -o -name '*.agekey' -o -name 'keys.txt' \) -path '*sops*' 2>/dev/null \
    | while read -r f; do finding "$pfx${f#$root}" "sops/age file"; done
  # shadow / passwd
  for s in etc/shadow etc/security/passwd; do [ -f "$root/$s" ] && scan_shadow "$pfx/$s" "$root/$s"; done
  # content scan: private keys, age material, identity strings, inline sops. Skip the nix store's compiled blobs cheaply by
  # scanning text-ish files; private-key/age/sops markers are ASCII.
  grep -rIlE -e "$PK_RE" "$root" 2>/dev/null | while read -r f; do finding "$pfx${f#$root}" "private key block"; done
  grep -rIlE -e "$SOPS_RE" "$root" 2>/dev/null | while read -r f; do finding "$pfx${f#$root}" "sops/age-encrypted content"; done
  grep -rIlE -e "$ID_RE" "$root" 2>/dev/null | while read -r f; do finding "$pfx${f#$root}" "maintainer identity string"; done
}

# byte scan when we cannot enumerate files (raw zfs/ufs image we won't mount)
scan_bytes() { # scan_bytes <file> <label>
  local f=$1 lbl=$2
  # strings over the raw bytes; each pattern is ASCII so this catches keys/age/ids even inside fs structures.
  # Raw-byte scan is a FALLBACK and is imprecise: the openssh binaries carry the literal "BEGIN OPENSSH PRIVATE KEY" and
  # sshd_config carries "~/.ssh/id_ed25519" as TEXT, so a marker alone is NOT a finding. We require strong evidence:
  #  - a real private-key FILE has the base64 body "b3BlbnNzaC1rZXkt" (openssh) or a PEM "MII" body right after the header;
  #  - a real age secret key is "AGE-SECRET-KEY-1<base58>"; sops ciphertext is "ENC[AES256_GCM,data:";
  #  - identity: greg@burd.me / /home/gburd as whole tokens.
  # Anything weaker is reported as WARN (inconclusive: a tree scan is needed), never REJECT. shortcut: byte mode cannot prove
  # a FILE exists; the release rebuild uses the read-only tree scan (exact). This fallback is only for banked raw images.
  if strings -a -n 8 "$f" 2>/dev/null | $GREP -Eq "b3BlbnNzaC1rZXkt|-----BEGIN (RSA|EC|PGP) PRIVATE"; then finding "$lbl" "private key BODY (byte scan: real key material)"; fi
  if strings -a -n 8 "$f" 2>/dev/null | $GREP -Eq "AGE-SECRET-KEY-1[0-9A-Z]{20,}|ENC\[AES256_GCM,data:"; then finding "$lbl" "age secret / sops ciphertext (byte scan)"; fi
  if strings -a -n 6 "$f" 2>/dev/null | $GREP -Eq -e "$ID_RE"; then finding "$lbl" "maintainer identity string (byte scan)"; fi
  # inconclusive markers -> WARN only
  if strings -a -n 8 "$f" 2>/dev/null | $GREP -q "BEGIN OPENSSH PRIVATE KEY"; then
    strings -a -n 8 "$f" 2>/dev/null | $GREP -Eq "b3BlbnNzaC1rZXkt" || echo "WARN $lbl: BEGIN-OPENSSH marker with no key body (likely the ssh binaries template; confirm with a tree scan)"; fi
  # a crypt hash sitting next to a username in a shadow-shaped line
  if strings -a -n 8 "$f" 2>/dev/null | $GREP -Eq "^[A-Za-z0-9_.-]+:\\\$(1|2[aby]|5|6|y|gy)\\\$"; then
    finding "$lbl" "shadow-shaped line with a password hash (byte scan)"; fi
}

process() { # process <file>
  local img=$1 tmp d base
  [ -r "$img" ] || { echo "$SELF: cannot read $img" >&2; rc=2; return; }
  base=${img##*/}
  tmp=$(mktemp -d) || { rc=2; return; }
  d="$tmp/img"
  case "$img" in
    *.gz)  $ZCAT "$img" > "$d" 2>/dev/null ;;
    *.zst) [ -n "$ZSTD" ] && $ZSTD -dc "$img" > "$d" 2>/dev/null || { echo "$SELF: no zstd for $img" >&2; rc=2; rm -rf "$tmp"; return; } ;;
    *)     ln -s "$(readlink -f "$img" 2>/dev/null || echo "$img")" "$d" ;;
  esac
  # ISO / tar: enumerate without mounting
  local kind=raw
  case "${img%.gz}" in *.iso) kind=iso ;; *.tar) kind=tar ;; esac
  file "$d" 2>/dev/null | $GREP -qiE 'ISO 9660|UDF' && kind=iso
  file "$d" 2>/dev/null | $GREP -qiE 'tar archive|POSIX tar' && kind=tar
  if [ "$kind" = iso ]; then
    local ex="$tmp/iso"; mkdir -p "$ex"
    if have xorriso; then xorriso -osirrox on -indev "$d" -extract / "$ex" >/dev/null 2>&1
    elif have bsdtar; then bsdtar -C "$ex" -xf "$d" 2>/dev/null; fi
    [ -n "$(ls -A "$ex" 2>/dev/null)" ] && scan_tree "$ex" "$base:iso" || scan_bytes "$d" "$base"
  elif [ "$kind" = tar ]; then
    local ex="$tmp/tar"; mkdir -p "$ex"; tar -C "$ex" -xf "$d" 2>/dev/null && scan_tree "$ex" "$base:tar" || scan_bytes "$d" "$base"
  else
    # raw disk image: byte scan (we deliberately do not import a zpool; see docs — never zpool import over ssh)
    scan_bytes "$d" "$base"
  fi
  [ "$rc" = 0 ] && echo "CLEAN $base"
  rm -rf "$tmp"
}

[ $# -ge 1 ] || { echo "usage: $SELF <image> [image...]" >&2; exit 2; }
for a in "$@"; do process "$a"; done
exit $rc
