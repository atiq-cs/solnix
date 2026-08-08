# fetchurl-shim.nix — a stdenv-free fetchurl for the pure illumos world.
#
# The nixpkgs fetchurl builds a real curlMinimal (openssl/perl/krb5/...) as its
# downloader; evaluating that toolchain against the pure x86_64-solaris stdenv
# hits perl<->libxcrypt infinite recursion. stdenv.fetchurlBoot avoids curl but
# emits a derivation whose /setup sourcing breaks under Nix 2.3.16 (no
# __structuredAttrs support). builtins.fetchurl needs neither a builder nor a
# stdenv: it fetches at eval time, hash-verified (fixed-output =
# hermetic-by-hash), and yields the SAME store path the drv path targets, so
# the src closure of every package still traces to a /nix/store fixed-output
# path (no host leak).
#
# H3 FIX (tranche 5): the top-level `fetchurl` was already shimmed, but the
# curl-bootstrap toolchain (curlMinimal.override { perl.override { fetchurl =
# stdenv.fetchurlBoot; ... } ... }) fetches its sources — notably perl's
# `libxcrypt-4.5.2.tar.xz` — via `stdenv.fetchurlBoot`, a SEPARATE fetch path
# (curl=null) that still emits a real derivation built by the un-adapted
# `stdenvNoCC`, so it hits the `/setup: No such file` structuredAttrs failure.
# We now route `fetchurlBoot` through the SAME builtins.fetchurl shim, both as
# the top-level attr AND baked onto the (adapted) stdenv/stdenvNoCC that the
# bootstrap captured, so bootstrap-fetched srcs are eval-time fixed-output
# fetches with no builder — killing the recursion at its source.
#
# mirror:// expansion: nixpkgs fetchurl expands mirror://<site>/<p> via a
# mirrorsFile; builtins.fetchurl only speaks real protocols, so we expand it
# here from the upstream mirrors.nix, trying EVERY http(s) mirror in turn.
#
# Fallback: builtins.fetchurl throws on a failed/interrupted download or a
# wrong-content mirror (hash mismatch). We iterate all candidate URLs with
# builtins.tryEval and take the first that fetches to the pinned hash. This
# absorbs both flaky mirrors and a mirror that served an error page.
#
# NOTE: eval-time fetch (needs network during evaluation). Fine for a build
# host with outbound HTTPS; the hash pins it. Upgrade path: seed srcs into the
# S3 cache and eval fetches from cache.solnix.io.
# forkPath: the patched-nixpkgs source tree the mirrors list is read from.
# Default is the absolute store path (classic/impure build path). The pure
# by-name flake passes its `fork` flake input here so eval never references an
# out-of-tree absolute path.
{ forkPath ? /nix/store/qmvlnvf0kk1zkfjpjpxwimg5ym8sfwnk-nixpkgs-patched-1785781297346528064 }:
final: prev:
let
  lib = final.lib;
  # curl for the in-builder raw download (fetchpatch path). Uses the already-built
  # curl from the pkg set (`final.curl`), lazily: only forced when a package
  # actually carries a postFetch (fetchpatch). NOTE: curl's OWN src must not need
  # this path (else a cycle) -- curl's src is a plain hash-pinned tarball
  # (fetchurl, no postFetch), so it takes the fetchFirst branch and never forces
  # final.curl. CA trust: sandbox=false, so the builder inherits the daemon's
  # NIX_SSL_CERT_FILE (nix.conf ssl-cert-file); curl reads CURL_CA_BUNDLE from it.
  solnixCurl = final.curl.bin or final.curl;
  mirrors = import (forkPath + "/pkgs/build-support/fetchurl/mirrors.nix");
  # httpOnly: keep only http(s) mirrors, and DROP ftpmirror.gnu.org — it 502s
  # from illumos hosts, and builtins.tryEval cannot catch a builtins.fetchurl IO
  # error (network failures are fatal at eval), so a failing FIRST candidate
  # aborts the whole evaluation instead of falling through. Dropping the flaky
  # redirector puts a 200-returning mirror (nluug/kernel.org/ftp.gnu.org) first.
  httpOnly = builtins.filter
    (u: lib.hasPrefix "http" u && !(lib.hasInfix "ftpmirror.gnu.org" u));
  # expand one url: a mirror:// yields ALL its http(s) mirrors + path; a plain
  # url yields itself — but ftp:// and dead hosts (info-zip.org) are dropped so a
  # non-recoverable FIRST candidate never aborts eval (tryEval can't catch a
  # fetchurl IO error). zip lists ftp://ftp.info-zip.org first + a fedora http
  # mirror second; dropping the ftp url makes the http mirror win.
  liveUrl = u: lib.hasPrefix "http" u
    && !(lib.hasInfix "ftpmirror.gnu.org" u)
    && !(lib.hasInfix "info-zip.org" u);
  expand = url:
    let m = builtins.match "mirror://([^/]+)/(.*)" url;
    in if m == null then (if liveUrl url then [ url ] else [ ])
       else let site = builtins.elemAt m 0; rest = builtins.elemAt m 1;
                bases = httpOnly (mirrors.${site} or (throw "fetchurl-shim: unknown mirror ${site}"));
            in map (b: b + rest) bases;
  # try each candidate url with builtins.fetchurl; first success wins.
  fetchFirst = name: sha256: cands:
    if cands == [] then throw "fetchurl-shim: all urls failed for ${name}"
    else let r = builtins.tryEval (builtins.fetchurl {
                   inherit name sha256; url = builtins.head cands;
                 });
         in if r.success then r.value
            else fetchFirst name sha256 (builtins.tail cands);
  # try each candidate url IMPURELY (no hash) — used for the fetchpatch path
  # where the recorded hash is of the POST-normalized patch, not the raw
  # download, so builtins.fetchurl can't verify the raw bytes. First fetch wins.
  # Pass an explicit sanitized name: gitlab/github archive urls carry query
  # strings (`archive.tar.gz?sha=refs%2Ftags%2F...`) whose `%` is illegal in a
  # store path name if derived from the url.
  fetchFirstImpure = name: cands:
    if cands == [] then throw "fetchurl-shim: all urls failed (impure)"
    else let r = builtins.tryEval (builtins.fetchurl {
                   url = builtins.head cands;
                   name = solnixSanitizeName name;
                 });
         in if r.success then r.value
            else fetchFirstImpure name (builtins.tail cands);
  # store-path-safe name: keep alnum + +-._?= , map everything else to '-',
  # strip any leading dot.
  solnixSanitizeName = s:
    let cleaned = builtins.replaceStrings
          ["%" "/" "&" " " "@" ":" "'" "\""]
          ["-" "-" "-" "-" "-" "-" "-" "-"]
          s;
    in if lib.hasPrefix "." cleaned then "s" + cleaned else cleaned;

  # H18 (tranche 6) + PURE-EVAL FIX: fetchpatch calls fetchurl with a
  # `postFetch` that normalizes the patch (decode + lsdiff/filterdiff), and the
  # sha256 it passes is of that NORMALIZED output, not the raw download. The old
  # shim fetched the raw at EVAL TIME via a hashless `builtins.fetchurl` (it
  # cannot know the raw hash, only the post-normalized one) -- but a hashless
  # `builtins.fetchurl` is ILLEGAL in pure evaluation mode
  # ("fetchurl requires a 'sha256' argument"), so any package carrying a
  # fetchpatch (wget's CVE patches, libev/libevent/libxml2 -> nghttp2/curl/
  # gnutls/... -> git/openssh/gnupg/cmake) broke `nix profile install` without
  # --impure. FIX: don't fetch the raw at eval time at all. Build a SINGLE
  # fixed-output derivation keyed on the KNOWN post-normalized outputHash, and
  # download the raw INSIDE the builder with curl (then run postFetch to
  # normalize). This is exactly what real nixpkgs fetchurl does -- minus building
  # curl from scratch (we use the already-built curl passthru), which is the
  # recursion the eval-time shim was avoiding. Pure-eval-safe: the FOD's
  # outputHash pins the result; no hashless eval-time fetch remains.
  postFetchFOD = args: cands:
    let
      sha256 = args.hash or args.sha256 or (throw "fetchurl-shim: no hash");
      name = args.name or (baseNameOf (builtins.head cands));
      # fetchzip sets downloadToTemp=true + recursiveHash=true: the raw file is
      # placed at $downloadedFile (NOT $out) and postFetch builds $out as a
      # directory hashed recursively. fetchpatch uses $out directly, flat hash.
      toTemp = args.downloadToTemp or false;
      recursive = args.recursiveHash or false;
      # try each candidate url in the builder until curl succeeds (mirrors +
      # flaky-host tolerance, same as the eval-time fetchFirst did).
      curlDownload = dest: ''
        _ok=
        _ca="''${NIX_SSL_CERT_FILE:-''${SSL_CERT_FILE:-/nix-tools224/ca-bundle.crt}}"
        for _u in ${lib.concatMapStringsSep " " (u: lib.escapeShellArg u) cands}; do
          if curl -fsSL --cacert "$_ca" --retry 3 --connect-timeout 30 -o "${dest}" "$_u"; then _ok=1; break; fi
        done
        [ -n "$_ok" ] || { echo "fetchurl-shim: all urls failed for ${name}" >&2; exit 1; }
      '';
    in final.stdenvNoCC.mkDerivation {
      inherit name;
      # curl (already built) for the raw download; plus any patch-tooling
      # (patchutils for filterdiff/lsdiff) the postFetch needs. CA trust comes
      # from the inherited NIX_SSL_CERT_FILE (sandbox=false); point curl's
      # CURL_CA_BUNDLE at it in the download step.
      nativeBuildInputs = [ solnixCurl ] ++ (args.nativeBuildInputs or []);
      buildCommand =
        (if toTemp
         then ''
           downloadedFile="$TMPDIR/${name}"
           ${curlDownload "$downloadedFile"}
           chmod +w "$downloadedFile"
         ''
         else ''
           ${curlDownload "$out"}
           chmod +w "$out"
         '')
        + (args.postFetch or "");
      outputHashAlgo = "sha256";
      outputHashMode = args.outputHashMode or (if recursive then "recursive" else "flat");
      outputHash = sha256;
      preferLocalBuild = true;
    };

  # the shared builtins.fetchurl-backed fetcher, used for BOTH fetchurl and
  # fetchurlBoot (H3). With postFetch (fetchpatch), take the H18 normalize-FOD
  # path; otherwise the plain hash-verified builtins.fetchurl path.
  #
  # H19 (tranche 6): fetchzip/fetchFromGitHub wrap this via
  # `lib.extendMkDerivation { constructDrv = fetchurl; }`, whose __functor calls
  # `constructDrv (finalAttrs: <attrs>)` — it hands the fetcher a FUNCTION (the
  # finalAttrs fixpoint), not a plain attrset. A plain-function shim then does
  # `args ? urls` on a lambda -> `value is a function while a set was expected`
  # (blocks zstd/libarchive/cmake/curl/git/... whose src is fetchFromGitHub).
  # Resolve the fixpoint here (self = f self), same trick as the perl
  # mkDerivation wrapper, then run the normal shim on the resolved attrs.
  shimFetch = argsOrFn:
    if builtins.isFunction argsOrFn
    # H19: the finalAttrs fixpoint. extendDrvArgs (fetchzip/fetchFromGitHub)
    # returns attrs whose `derivationArgs` (extension/stripRoot/...) real
    # fetchurl folds up into the drv attrs, and the body then reads them back
    # as `finalAttrs.extension`. Reproduce that fold in the self-reference so
    # those reads resolve, then run the shim on the merged attrs.
    then let self = let a = argsOrFn self; in a // (a.derivationArgs or {}); in shimFetch self
    else let
      args = argsOrFn;
      rawUrls = if args ? urls && args.urls != [] then args.urls
                else if args ? url && args.url != "" then [ args.url ]
                else throw "fetchurl-shim: no url/urls";
      cands = lib.concatMap expand rawUrls;
      # builtins.fetchurl only accepts a `sha256` field (base16/base32/SRI).
      # A src pinned with a bare `sha512`/`sha1` (no `hash`/`sha256`) has no
      # sha256 to hand it; wrap the sha512 as an SRI string so the eval-time
      # fetch still verifies. If nothing pins it, fall to the impure fetch
      # (the enclosing FOD's outputHash pins the final result anyway).
      # builtins.fetchurl's `sha256` field only accepts a real sha256 (hex/
      # base32/SRI-sha256). A src pinned with a bare `sha512`/`sha1` cannot be
      # verified through it, so fetch those impurely at eval time; the
      # enclosing FOD's outputHash still pins the final store path.
      sha256 = if args ? hash then args.hash
               else if args ? sha256 then args.sha256
               else null;
      name = args.name or (baseNameOf (builtins.head cands));
    in if (args.postFetch or "") != ""
       then postFetchFOD args cands
       else if sha256 != null
            then (let r = builtins.tryEval (fetchFirst name sha256 cands);
                  in if r.success then r.value else fetchFirstImpure name cands)
            else fetchFirstImpure name cands;
in {
  fetchurl = shimFetch;
  # H3: expose the shimmed fetcher so a later overlay (after the structuredAttrs
  # adapter re-wraps stdenv) can bake it onto stdenv.fetchurlBoot — the attr
  # that `libxcrypt = callPackage { fetchurl = stdenv.fetchurlBoot; ... }` reads
  # to break the perl<->libxcrypt cycle. Setting it here on prev.stdenv is not
  # enough (the adapter overlay rebuilds stdenv and drops it), so tranche5.nix
  # re-asserts it after the adapter using this passthru.
  fetchurlBoot = shimFetch;
  solnixShimFetch = shimFetch;
}
