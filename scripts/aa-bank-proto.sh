#!/usr/bin/env bash
# aa-bank-proto.sh — bank the aarch64 illumos build proto (proto/root_aarch64) in
# the R2/S3 object store, and verify it by READING THE OBJECT BACK, never by exit
# status.
#
# WHY THIS EXISTS: the aarch64 proto has now been lost TWICE. The archived
# aarch64-proto-73466454.tar.zst 404s, the arm64-gate tree died with a prior host,
# and both aarch64 AMIs died with a burner account without ever being banked. The
# cross toolchain survived only because it was banked in a non-account-scoped
# bucket. The proto is the expensive half (multi-hour nightly) and had no such
# copy.
#
# WHY READ-BACK AND NOT EXIT STATUS: images/release-224-ena-mtufix/solnix-raw.img.gz
# in this same bucket is 20 BYTES — a silently truncated upload that has sat there
# behind a SUCCESSFUL exit status since August. Two independent defences here:
#   1. SigV4 with x-amz-content-sha256 = the sha256 of the WHOLE body. A truncated
#      or corrupted body cannot produce a valid signature, so the server rejects
#      it rather than storing a short object.
#   2. After upload, GET the object back and compare sha256 + byte count against
#      the local file. Only that comparison decides success.
#
# RUNS ON THE BUILD NODE (illumos). Deliberately depends on nothing beyond
# python3 + hashlib/hmac/http.client/ssl (present on the OI build hosts) and
# gzip/tar. No aws CLI, no gsutil, no nix — those are not on the build host.
#
#   aa-bank-proto.sh bank   <proto-dir> <prefix>   tar+gz -> signed PUT -> read-back verify -> manifest
#   aa-bank-proto.sh verify <prefix>               re-verify a banked prefix from the store alone
#
# Credentials come from the environment ONLY (never a file, never logged):
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY  (the s3-cache key; see secrets/s3-cache.yaml)
# Knobs: S3_HOST=s3.solnix.io S3_BUCKET=solnix-cache S3_REGION=us-east-1
#        WORKDIR=/aarch64/bank
set -eu

S3_HOST="${S3_HOST:-s3.solnix.io}"
S3_BUCKET="${S3_BUCKET:-solnix-cache}"
S3_REGION="${S3_REGION:-us-east-1}"
WORKDIR="${WORKDIR:-/aarch64/bank}"
export S3_HOST S3_BUCKET S3_REGION

: "${AWS_ACCESS_KEY_ID:?set AWS_ACCESS_KEY_ID}"
: "${AWS_SECRET_ACCESS_KEY:?set AWS_SECRET_ACCESS_KEY}"

mkdir -p "$WORKDIR"
SIGNER="$WORKDIR/s3io.py"

# ---------------------------------------------------------------------------
# Embedded SigV4 client. Same signing chain as scripts/oi-node-publish.sh (which
# carries a known-answer test against an awscli-captured signature), reduced to
# the three verbs needed here, plus streaming GET-and-hash so verification never
# has to hold the object in memory.
# ---------------------------------------------------------------------------
cat > "$SIGNER" <<'PYEOF'
import sys, os, hashlib, hmac, datetime, http.client, ssl, urllib.parse

REGION = os.environ.get('S3_REGION', 'us-east-1')
SERVICE = 's3'
HOST = os.environ.get('S3_HOST', 's3.solnix.io')
BUCKET = os.environ.get('S3_BUCKET', 'solnix-cache')
AKID = os.environ.get('AWS_ACCESS_KEY_ID', '')
SECRET = os.environ.get('AWS_SECRET_ACCESS_KEY', '')
TOKEN = os.environ.get('AWS_SESSION_TOKEN', '')
CHUNK = 8 << 20


def _h(k, m):
    return hmac.new(k, m.encode() if isinstance(m, str) else m, hashlib.sha256)


def _sigkey(secret, ds, region, service):
    k = _h(('AWS4' + secret).encode(), ds).digest()
    k = _h(k, region).digest()
    k = _h(k, service).digest()
    return _h(k, 'aws4_request').digest()


def sign_headers(method, key, payload_sha256, amzdate=None, extra=None, query=''):
    now = datetime.datetime.now(datetime.timezone.utc)
    amzdate = amzdate or now.strftime('%Y%m%dT%H%M%SZ')
    datestamp = amzdate[:8]
    canonical_uri = '/' + urllib.parse.quote(BUCKET + '/' + key, safe='/')
    hdrs = {'host': HOST, 'x-amz-content-sha256': payload_sha256, 'x-amz-date': amzdate}
    if TOKEN:
        hdrs['x-amz-security-token'] = TOKEN
    if extra:
        for k2, v in extra.items():
            hdrs[k2.lower()] = v
    signed = ';'.join(sorted(hdrs))
    canon_hdr = ''.join('%s:%s\n' % (k2, hdrs[k2]) for k2 in sorted(hdrs))
    creq = '\n'.join([method, canonical_uri, query, canon_hdr, signed, payload_sha256])
    creq_hash = hashlib.sha256(creq.encode()).hexdigest()
    scope = '%s/%s/%s/aws4_request' % (datestamp, REGION, SERVICE)
    sts = '\n'.join(['AWS4-HMAC-SHA256', amzdate, scope, creq_hash])
    sig = hmac.new(_sigkey(SECRET, datestamp, REGION, SERVICE), sts.encode(),
                   hashlib.sha256).hexdigest()
    auth = ('AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s'
            % (AKID, scope, signed, sig))
    out = dict(hdrs)
    out['Authorization'] = auth
    return out, dict(signature=sig, string_to_sign=sts, canonical_request=creq)


def _conn(timeout):
    return http.client.HTTPSConnection(HOST, 443, timeout=timeout,
                                       context=ssl.create_default_context())


def file_sha256(path):
    h = hashlib.sha256()
    n = 0
    with open(path, 'rb') as f:
        while True:
            b = f.read(CHUNK)
            if not b:
                break
            h.update(b)
            n += len(b)
    return h.hexdigest(), n


def put_file(key, path, ctype='binary/octet-stream', timeout=3600):
    """Signed PUT with the payload hash of the WHOLE file. A truncated body
    cannot satisfy the signature, so the store rejects it instead of keeping a
    short object -- the exact failure that produced a 20-byte image in this
    bucket."""
    digest, size = file_sha256(path)
    hdrs, _ = sign_headers('PUT', key, digest,
                           extra={'content-type': ctype,
                                  'content-length': str(size)})
    c = _conn(timeout)
    with open(path, 'rb') as f:
        c.request('PUT', '/' + BUCKET + '/' + key, body=f, headers=hdrs)
        r = c.getresponse()
        body = r.read()
    c.close()
    return r.status, r.reason, body[:400].decode('utf-8', 'replace'), digest, size


def get_hash(key, timeout=3600):
    """Stream the object back and hash it. Returns (status, sha256, nbytes)."""
    empty = hashlib.sha256(b'').hexdigest()
    hdrs, _ = sign_headers('GET', key, empty)
    c = _conn(timeout)
    c.request('GET', '/' + BUCKET + '/' + key, headers=hdrs)
    r = c.getresponse()
    if r.status >= 300:
        body = r.read()
        c.close()
        return r.status, None, 0, body[:400].decode('utf-8', 'replace')
    h = hashlib.sha256()
    n = 0
    while True:
        b = r.read(CHUNK)
        if not b:
            break
        h.update(b)
        n += len(b)
    c.close()
    return r.status, h.hexdigest(), n, ''


if __name__ == '__main__':
    cmd = sys.argv[1]

    if cmd == 'kat':
        # Known-answer test: proves the signing-key/STS/canonical-request chain
        # against an awscli-captured signature. A guard that cannot fail is
        # worse than no guard, so the signer self-tests before any network use.
        globals().update(AKID='AKIDEXAMPLE',
                         SECRET='wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY', TOKEN='')
        _, i = sign_headers('HEAD', 'kat-test.narinfo',
                            hashlib.sha256(b'').hexdigest(), amzdate='20260811T145837Z')
        exp = 'f599c0c0762b4b344705c46ddf5a9100263b6d8480496cbb1a06ac7a0ba28d9c'
        print('KAT signature :', i['signature'])
        print('KAT expected  :', exp)
        print('KAT MATCH:', i['signature'] == exp)
        sys.exit(0 if i['signature'] == exp else 1)

    if cmd == 'sha256':
        d, n = file_sha256(sys.argv[2])
        print('%s %d' % (d, n))
        sys.exit(0)

    if cmd == 'put':
        key, path = sys.argv[2], sys.argv[3]
        ctype = sys.argv[4] if len(sys.argv) > 4 else 'binary/octet-stream'
        st, rs, body, d, n = put_file(key, path, ctype)
        sys.stderr.write('PUT %s -> %d %s (%d bytes, sha256 %s)\n' % (key, st, rs, n, d))
        if st >= 300:
            sys.stderr.write(body + '\n')
        print('%s %d' % (d, n))
        sys.exit(0 if st < 300 else 1)

    if cmd == 'getsha':
        st, d, n, err = get_hash(sys.argv[2])
        if st >= 300:
            sys.stderr.write('GET %s -> %d %s\n' % (sys.argv[2], st, err))
            sys.exit(1)
        print('%s %d' % (d, n))
        sys.exit(0)

    sys.stderr.write('unknown command %s\n' % cmd)
    sys.exit(2)
PYEOF

py() { python3 "$SIGNER" "$@"; }

# The signer must prove it can produce a known-correct signature before the
# network is touched at all.
py kat >/dev/null || { echo "FATAL: SigV4 self-test FAILED — refusing to upload" >&2; exit 3; }

# upload_verified <local-file> <object-key> <content-type>
# Uploads, then GETs the object back and compares sha256 AND byte count.
# Success is decided ONLY by that comparison.
upload_verified() {
  local f="$1" key="$2" ct="${3:-binary/octet-stream}"
  local local_out local_sha local_n back_out back_sha back_n

  echo "--- upload $f -> s3://$S3_BUCKET/$key"
  local_out="$(py sha256 "$f")"
  local_sha="${local_out%% *}"; local_n="${local_out##* }"
  echo "    local : sha256=$local_sha bytes=$local_n"
  [ "$local_n" -gt 0 ] || { echo "    FAIL: local file is EMPTY" >&2; return 1; }

  py put "$key" "$f" "$ct" >/dev/null || {
    echo "    FAIL: PUT rejected (signature or server error) — nothing to verify" >&2; return 1; }

  # READ-BACK. This, not the PUT's exit status, is the verification.
  back_out="$(py getsha "$key")" || { echo "    FAIL: read-back GET failed" >&2; return 1; }
  back_sha="${back_out%% *}"; back_n="${back_out##* }"
  echo "    stored: sha256=$back_sha bytes=$back_n"

  if [ "$back_sha" != "$local_sha" ]; then
    echo "    FAIL: sha256 MISMATCH (local $local_sha != stored $back_sha)" >&2; return 1
  fi
  if [ "$back_n" != "$local_n" ]; then
    echo "    FAIL: SIZE MISMATCH (local $local_n != stored $back_n)" >&2; return 1
  fi
  echo "    VERIFIED (read-back sha256 + size match)"
  printf '%s  %s  %s\n' "$local_sha" "$local_n" "$key" >> "$WORKDIR/SHA256SUMS.$$"
  return 0
}

case "${1:-}" in
bank)
  PROTO="${2:?usage: aa-bank-proto.sh bank <proto-dir> <prefix>}"
  PREFIX="${3:?usage: aa-bank-proto.sh bank <proto-dir> <prefix>}"

  # Refuse to bank something that is not a proto: the whole point of this
  # artifact is the kernel, and an archive without it is worthless.
  #
  # ARCH is a parameter, not a fork of this script. It was aarch64-only, and
  # docs/account-migration-bene-to-lava.md records what forking-per-variant costs
  # (three drifted copies of one procedure, each stranded). x86_64 stages the kernel
  # at platform/i86pc/kernel/amd64/unix + kernel/amd64/genunix; aarch64 at
  # platform/armv8/kernel/aarch64/unix + kernel/aarch64/genunix.
  #   ARCH=aarch64 (default) | amd64
  ARCH="${ARCH:-aarch64}"
  case "$ARCH" in
    aarch64) UNIX="$PROTO/platform/armv8/kernel/aarch64/unix"; GENUNIX="$PROTO/kernel/aarch64/genunix" ;;
    amd64)   UNIX="$PROTO/platform/i86pc/kernel/amd64/unix";    GENUNIX="$PROTO/kernel/amd64/genunix" ;;
    *) echo "FATAL: unknown ARCH=$ARCH (want aarch64 or amd64)" >&2; exit 2 ;;
  esac
  [ -d "$PROTO" ]   || { echo "FATAL: no such proto dir: $PROTO" >&2; exit 2; }
  [ -f "$UNIX" ]    || { echo "FATAL: no aarch64 unix at $UNIX — refusing to bank" >&2; exit 2; }
  [ -f "$GENUNIX" ] || { echo "FATAL: no genunix at $GENUNIX — refusing to bank" >&2; exit 2; }
  # POSIX size check: illumos has NO stat(1), not even gstat, so `stat -c %s`
  # is always false here and every `&&` after it silently never runs.
  USZ="$(wc -c < "$UNIX" | tr -d ' ')"
  [ "$USZ" -gt 100000 ] || { echo "FATAL: unix is only $USZ bytes — refusing" >&2; exit 2; }
  echo "proto gate OK: unix=$USZ bytes, genunix present"

  TARNAME="${TARNAME:-proto-$(basename "$PROTO").tar.gz}"
  TAR="$WORKDIR/$TARNAME"
  echo "=== tar+gzip the proto (this is the expensive artifact) ==="
  # Solaris tar: -C works, but read/write stdin needs an explicit `f -`.
  ( cd "$(dirname "$PROTO")" && tar cf - "$(basename "$PROTO")" ) | gzip -6 > "$TAR"
  ls -l "$TAR"

  MAN="$WORKDIR/MANIFEST.txt"
  {
    echo "solnix $ARCH illumos build proto — banked artifact"
    echo "created:       $(date -u +%FT%TZ)"
    echo "host:          $(uname -a)"
    echo "proto path:    $PROTO"
    echo "unix bytes:    $USZ"
    echo "genunix bytes: $(wc -c < "$GENUNIX" | tr -d ' ')"
    echo "file count:    $(find "$PROTO" | wc -l | tr -d ' ')"
    echo "tarball:       $(basename "$TAR")"
    echo "tarball bytes: $(wc -c < "$TAR" | tr -d ' ')"
    echo
    echo "WHY: the archived aarch64-proto-73466454.tar.zst 404s and the arm64-gate"
    echo "tree died with a prior host. This is the multi-hour nightly output; the"
    echo "cross toolchain seed at seed/aarch64-solaris/ is the other half."
    echo
    echo "RESTORE:"
    echo "  curl -fsSL https://$S3_HOST/$S3_BUCKET/$PREFIX/$(basename "$TAR") | gzip -dc | tar xpf -"
    echo "  (Solaris tar needs the explicit 'f -' to read stdin)"
    echo "then point the image builder's PROTO= at the extracted proto root."
  } > "$MAN"

  rm -f "$WORKDIR/SHA256SUMS.$$"
  RC=0
  upload_verified "$TAR" "$PREFIX/$(basename "$TAR")" "application/gzip" || RC=1
  upload_verified "$MAN" "$PREFIX/MANIFEST.txt" "text/plain" || RC=1
  if [ "$RC" = 0 ]; then
    mv "$WORKDIR/SHA256SUMS.$$" "$WORKDIR/SHA256SUMS"
    upload_verified "$WORKDIR/SHA256SUMS" "$PREFIX/SHA256SUMS" "text/plain" || RC=1
  fi
  [ "$RC" = 0 ] && echo "=== PROTO BANKED AND READ-BACK VERIFIED: s3://$S3_BUCKET/$PREFIX/ ===" \
                || echo "=== BANK FAILED — DO NOT TRUST THIS PREFIX ===" >&2
  exit "$RC"
  ;;
verify)
  PREFIX="${2:?usage: aa-bank-proto.sh verify <prefix>}"
  # Verify from the store alone: fetch SHA256SUMS, then re-hash each object.
  SUMS="$WORKDIR/verify-sums.txt"
  py getsha "$PREFIX/SHA256SUMS" >/dev/null || { echo "FATAL: no SHA256SUMS at $PREFIX" >&2; exit 1; }
  curl -fsSL "https://$S3_HOST/$S3_BUCKET/$PREFIX/SHA256SUMS" -o "$SUMS" \
    || { echo "FATAL: cannot fetch SHA256SUMS" >&2; exit 1; }
  RC=0
  while read -r sha n key; do
    [ -n "${key:-}" ] || continue
    out="$(py getsha "$key")" || { echo "FAIL missing $key" >&2; RC=1; continue; }
    gs="${out%% *}"; gn="${out##* }"
    if [ "$gs" = "$sha" ] && [ "$gn" = "$n" ]; then
      echo "OK   $key ($n bytes)"
    else
      echo "FAIL $key: expected $sha/$n got $gs/$gn" >&2; RC=1
    fi
  done < "$SUMS"
  [ "$RC" = 0 ] && echo "=== VERIFIED: $PREFIX ===" || echo "=== VERIFY FAILED: $PREFIX ===" >&2
  exit "$RC"
  ;;
*)
  echo "usage: aa-bank-proto.sh bank <proto-dir> <prefix> | verify <prefix>" >&2
  exit 2
  ;;
esac
