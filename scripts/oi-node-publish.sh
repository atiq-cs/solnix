#!/usr/bin/env bash
# oi-node-publish.sh — publish solnix store paths DIRECTLY from a build node to
# the S3-compatible inbox (s3.solnix.io) via SigV4-signed curl/HTTP PUTs, so
# egret nodes with FAST region bandwidth stop bridging closures through the
# orchestrator's slow home uplink.
#
# The from-source illumos nix lacks the s3:// store scheme, so we assemble the
# narinfo + nar ourselves and PUT them with our own SigV4 signer (embedded
# python; the node has python3 + hashlib/hmac/ssl). Idempotent + resumable:
# skips any object already durable at cache.solnix.io.
#
#   Usage:
#     AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... [AWS_SESSION_TOKEN=...] \
#     SIGN_KEY=/path/to/cache.solnix.io-1.secret \
#     ./oi-node-publish.sh <paths-file>
#
#   paths-file: one /nix/store/... path per line; a leading label + TAB is OK
#               (matches x86-wave19-paths.txt), extra TAB columns ignored.
#
#   Env knobs (defaults shown):
#     S3_HOST=s3.solnix.io  S3_BUCKET=solnix-cache  S3_REGION=us-east-1
#     READ_HOST=cache.solnix.io      # durable read endpoint for presence checks
#     COMPRESSION=xz                 # must match what the durable cache serves
#     DRYRUN=                        # set to 1 to print PUTs without uploading
#     FORCE=                         # set to 1 to skip the durable presence check
#     PATH=/run/current-system/sw/bin:$PATH   # caller should export this on egret
#
# Creds + signing key come from env/files only; never hardcoded, never logged.
set -eu

PATHS_FILE="${1:?usage: AWS_ACCESS_KEY_ID=.. AWS_SECRET_ACCESS_KEY=.. SIGN_KEY=.. oi-node-publish.sh <paths-file>}"
[ -r "$PATHS_FILE" ] || { echo "FATAL: cannot read paths file: $PATHS_FILE" >&2; exit 2; }

S3_HOST="${S3_HOST:-s3.solnix.io}"
S3_BUCKET="${S3_BUCKET:-solnix-cache}"
S3_REGION="${S3_REGION:-us-east-1}"
READ_HOST="${READ_HOST:-cache.solnix.io}"
COMPRESSION="${COMPRESSION:-xz}"
DRYRUN="${DRYRUN:-}"
FORCE="${FORCE:-}"

: "${AWS_ACCESS_KEY_ID:?set AWS_ACCESS_KEY_ID}"
: "${AWS_SECRET_ACCESS_KEY:?set AWS_SECRET_ACCESS_KEY}"
SIGN_KEY="${SIGN_KEY:?set SIGN_KEY to the cache.solnix.io-1 secret key file}"
[ -r "$SIGN_KEY" ] || { echo "FATAL: cannot read SIGN_KEY: $SIGN_KEY" >&2; exit 2; }

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 2; }
command -v nix-store >/dev/null 2>&1 || { echo "FATAL: nix-store required" >&2; exit 2; }
NF="nix-command flakes"           # from-source nix needs this for store sign / path-info
NIXX() { nix --extra-experimental-features "$NF" "$@"; }

case "$COMPRESSION" in
  xz)   COMP_CMD="xz -c -T0";   NAR_EXT="nar.xz"  ;;
  zstd) COMP_CMD="zstd -c -q";  NAR_EXT="nar.zst" ;;
  none) COMP_CMD="cat";         NAR_EXT="nar"     ;;
  *) echo "FATAL: unknown COMPRESSION=$COMPRESSION" >&2; exit 2 ;;
esac

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT INT TERM
umask 077

# ---- embedded SigV4 signer / HTTP PUT+HEAD (classic single-chunk, path-style) ----
# Reads creds from env; writes nothing sensitive to disk or stdout.
SIGNER="$WORK/s3put.py"
cat > "$SIGNER" <<'PYEOF'
import sys, os, hashlib, hmac, datetime, http.client, ssl, urllib.parse
REGION=os.environ.get('S3_REGION','us-east-1'); SERVICE='s3'
HOST=os.environ.get('S3_HOST','s3.solnix.io'); BUCKET=os.environ.get('S3_BUCKET','solnix-cache')
AKID=os.environ.get('AWS_ACCESS_KEY_ID',''); SECRET=os.environ.get('AWS_SECRET_ACCESS_KEY','')
TOKEN=os.environ.get('AWS_SESSION_TOKEN','')
def _h(k,m): return hmac.new(k, m.encode() if isinstance(m,str) else m, hashlib.sha256)
def _sigkey(secret,ds,region,service):
    k=_h(('AWS4'+secret).encode(),ds).digest(); k=_h(k,region).digest()
    k=_h(k,service).digest(); return _h(k,'aws4_request').digest()
def sign_headers(method,key,payload_sha256,amzdate=None,extra=None):
    now=datetime.datetime.now(datetime.timezone.utc)
    amzdate=amzdate or now.strftime('%Y%m%dT%H%M%SZ'); datestamp=amzdate[:8]
    canonical_uri='/'+urllib.parse.quote(BUCKET+'/'+key, safe='/')
    hdrs={'host':HOST,'x-amz-content-sha256':payload_sha256,'x-amz-date':amzdate}
    if TOKEN: hdrs['x-amz-security-token']=TOKEN
    if extra:
        for k2,v in extra.items(): hdrs[k2.lower()]=v
    signed=';'.join(sorted(hdrs))
    canon_hdr=''.join('%s:%s\n'%(k2,hdrs[k2]) for k2 in sorted(hdrs))
    creq='\n'.join([method,canonical_uri,'',canon_hdr,signed,payload_sha256])
    creq_hash=hashlib.sha256(creq.encode()).hexdigest()
    scope='%s/%s/%s/aws4_request'%(datestamp,REGION,SERVICE)
    sts='\n'.join(['AWS4-HMAC-SHA256',amzdate,scope,creq_hash])
    sig=hmac.new(_sigkey(SECRET,datestamp,REGION,SERVICE),sts.encode(),hashlib.sha256).hexdigest()
    auth='AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s'%(AKID,scope,signed,sig)
    out={k2:hdrs[k2] for k2 in hdrs}; out['Authorization']=auth
    return out, dict(canonical_request=creq,string_to_sign=sts,signature=sig)
def _emptyhash(): return hashlib.sha256(b'').hexdigest()
def request(method,key,body=None,extra=None,timeout=600):
    payload=_emptyhash() if body is None else hashlib.sha256(body).hexdigest()
    hdrs,_=sign_headers(method,key,payload,extra=extra)
    conn=http.client.HTTPSConnection(HOST,443,timeout=timeout,context=ssl.create_default_context())
    conn.request(method,'/'+BUCKET+'/'+key,body=body or b'',headers=hdrs)
    r=conn.getresponse(); data=r.read(); conn.close(); return r.status,r.reason,data

if __name__=='__main__':
    cmd=sys.argv[1]
    if cmd=='--kat':
        # known-answer test vs awscli-captured classic-form signature (empty payload,
        # AKIDEXAMPLE creds, fixed date/key). Proves the signing-key + STS + CR chain.
        globals().update(AKID='AKIDEXAMPLE',SECRET='wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',TOKEN='')
        _,i=sign_headers('HEAD','kat-test.narinfo',_emptyhash(),amzdate='20260811T145837Z')
        exp='f599c0c0762b4b344705c46ddf5a9100263b6d8480496cbb1a06ac7a0ba28d9c'
        print('KAT signature :',i['signature']); print('awscli expected:',exp)
        print('KAT MATCH:', i['signature']==exp); sys.exit(0 if i['signature']==exp else 1)
    if cmd=='--dryrun-put':
        # print the exact request line + signed headers that would be issued, no network.
        # args: method key bodyfile [content-type]  (payload hash computed from bodyfile)
        method,key,bodyfile=sys.argv[2],sys.argv[3],sys.argv[4]
        ct=sys.argv[5] if len(sys.argv)>5 else None
        extra={'content-type':ct} if ct else None
        payload=hashlib.sha256(open(bodyfile,'rb').read()).hexdigest()
        hdrs,info=sign_headers(method,key,payload,extra=extra)
        print('%s https://%s/%s/%s'%(method,HOST,BUCKET,key))
        for k2 in sorted(hdrs):
            v=hdrs[k2]
            if k2.lower() in ('authorization','x-amz-security-token'): v='<redacted-sig>'
            print('  %s: %s'%(k2,v))
        sys.exit(0)
    method,key=sys.argv[1],sys.argv[2]
    bodyfile=sys.argv[3] if len(sys.argv)>3 and sys.argv[3]!='-' else None
    ct=sys.argv[4] if len(sys.argv)>4 else None
    body=open(bodyfile,'rb').read() if bodyfile else None
    extra={'content-type':ct} if ct else None
    st,rs,data=request(method,key,body,extra)
    sys.stderr.write('%s %s -> %d %s\n'%(method,key,st,rs))
    if st>=300 and data: sys.stderr.write(data.decode('utf-8','replace')[:400]+'\n')
    sys.exit(0 if st<300 else 1)
PYEOF
export S3_HOST S3_BUCKET S3_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
[ -n "${AWS_SESSION_TOKEN:-}" ] && export AWS_SESSION_TOKEN || true

# self-test the signer before touching the network
python3 "$SIGNER" --kat >/dev/null || { echo "FATAL: SigV4 self-test failed" >&2; exit 3; }

# ---- durable presence check via the read endpoint (cache-busted) ----
# The inbox head-object gives stale positives; cache.solnix.io is authoritative.
durable() {  # $1 = object key (e.g. abc.narinfo or nar/xxx.nar.xz)
  [ -n "$FORCE" ] && return 1
  code="$(curl -s -o /dev/null -w '%{http_code}' -I \
          "https://$READ_HOST/$1?x=$RANDOM$RANDOM" 2>/dev/null || echo 000)"
  [ "$code" = "200" ]
}

# ---- narinfo builder for one closure member ----
# emits the narinfo text on stdout; needs NarHash(base32), NarSize, References
# (sorted by basename, incl self), FileHash(base32 of compressed nar), FileSize, Sig.
build_narinfo() {  # $1=storepath $2=narurl $3=filehash_b32 $4=filesize $5=narfile_for_deriver
  sp="$1"; narurl="$2"; fh="$3"; fsz="$4"
  narhash="$(nix-store -q --hash "$sp")"          # sha256:<base32>
  narsize="$(nix-store -q --size "$sp")"
  refs="$(nix-store -q --references "$sp" | xargs -n1 basename | LC_ALL=C sort | tr '\n' ' ')"
  refs="${refs% }"
  deriver="$(nix-store -q --deriver "$sp" 2>/dev/null || true)"
  case "$deriver" in /nix/store/*) drv="$(basename "$deriver")";; *) drv="";; esac
  sig="$(NIXX path-info --json --sigs "$sp" 2>/dev/null \
        | python3 -c 'import sys,json; v=list(json.load(sys.stdin).values())[0]; s=(v.get("signatures") or []); print(s[0] if s else "")')"
  {
    printf 'StorePath: %s\n' "$sp"
    printf 'URL: %s\n' "$narurl"
    printf 'Compression: %s\n' "$COMPRESSION"
    printf 'FileHash: sha256:%s\n' "$fh"
    printf 'FileSize: %s\n' "$fsz"
    printf 'NarHash: %s\n' "$narhash"
    printf 'NarSize: %s\n' "$narsize"
    printf 'References: %s\n' "$refs"
    [ -n "$drv" ] && printf 'Deriver: %s\n' "$drv"
    [ -n "$sig" ] && printf 'Sig: %s\n' "$sig"
  }
}

# ---- publish one closure member ----
publish_path() {  # $1 = /nix/store/<hash>-name
  sp="$1"; base="$(basename "$sp")"; hash="${base%%-*}"
  narinfo_key="$hash.narinfo"

  # sign this path (idempotent; adds sig if missing)
  NIXX store sign -k "$SIGN_KEY" "$sp" >/dev/null 2>&1 || true

  # dump + compress the nar to get FileHash/FileSize (nar URL basename = FileHash b32)
  narfile="$WORK/nar.out"
  NIXX store dump-path "$sp" 2>/dev/null | $COMP_CMD > "$narfile" 2>/dev/null \
    || nix-store --dump "$sp" | $COMP_CMD > "$narfile"
  filehash="$(nix-hash --type sha256 --flat --base32 "$narfile")"
  filesize="$(wc -c < "$narfile" | tr -d ' ')"
  narurl="nar/$filehash.$NAR_EXT"
  narinfo="$WORK/out.narinfo"
  build_narinfo "$sp" "$narurl" "$filehash" "$filesize" > "$narinfo"

  if [ -n "$DRYRUN" ]; then
    echo "--- DRYRUN $base ---"
    echo "narinfo key: $narinfo_key   nar key: $narurl   filesize: $filesize"
    python3 "$SIGNER" --dryrun-put PUT "$narurl" "$narfile" "binary/octet-stream"
    python3 "$SIGNER" --dryrun-put PUT "$narinfo_key" "$narinfo" "text/x-nix-narinfo"
    echo "--- narinfo body ---"; cat "$narinfo"; echo "---"
    return 0
  fi

  # upload nar first (so a present narinfo always has its nar), then narinfo.
  if durable "$narurl"; then
    :
  else
    python3 "$SIGNER" PUT "$narurl" "$narfile" "binary/octet-stream" \
      || { echo "  FAIL nar PUT: $base" >&2; return 1; }
  fi
  if durable "$narinfo_key"; then
    return 0
  fi
  python3 "$SIGNER" PUT "$narinfo_key" "$narinfo" "text/x-nix-narinfo" \
    || { echo "  FAIL narinfo PUT: $base" >&2; return 1; }
}

# ---- main loop ----
pub=0; skip=0; fail=0
while IFS= read -r line || [ -n "$line" ]; do
  # accept "label<TAB>/nix/store/.." or bare "/nix/store/.."
  sp="$line"
  case "$sp" in *"	"*) sp="${sp#*	}"; sp="${sp%%	*}";; esac
  case "$sp" in "") continue;; \#*) continue;; /nix/store/*) ;; *) continue;; esac

  echo "=== $(basename "$sp") ==="
  # publish the whole closure of this top path (each member is its own narinfo)
  members="$(nix-store -qR "$sp" 2>/dev/null || true)"
  [ -n "$members" ] || { echo "  FAIL closure query" >&2; fail=$((fail+1)); continue; }
  # sign the top path recursively once (covers the closure) before per-member sigs
  NIXX store sign -k "$SIGN_KEY" --recursive "$sp" >/dev/null 2>&1 || true
  for m in $members; do
    mkey="$(basename "$m")"; mkey="${mkey%%-*}.narinfo"
    if [ -z "$FORCE" ] && durable "$mkey"; then
      skip=$((skip+1)); continue
    fi
    if publish_path "$m"; then
      echo "  published $(basename "$m")"; pub=$((pub+1))
    else
      fail=$((fail+1))
    fi
  done
done < "$PATHS_FILE"

echo "done: published=$pub skipped=$skip failed=$fail"
[ "$fail" = 0 ]
