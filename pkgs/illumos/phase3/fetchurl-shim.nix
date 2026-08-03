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
# path (no host leak). Nix's own downloader retries with backoff on transient
# errors, so no retry logic is needed here (tryEval cannot catch a fetch
# error anyway).
#
# mirror:// expansion: nixpkgs fetchurl expands mirror://<site>/<p> via a
# mirrorsFile; builtins.fetchurl only speaks real protocols, so we expand it
# here from the upstream mirrors.nix (first http(s) mirror per site).
#
# NOTE: eval-time fetch (needs network during evaluation). Fine for a build
# host with outbound HTTPS; the hash pins it. Upgrade path: seed srcs into the
# S3 cache and eval fetches from cache.solnix.io.
final: prev:
let
  lib = final.lib;
  mirrors = import /nix/store/p3lfwcvh0vz6xc8wc1yhj2f8rg1flnb9-nixpkgs-patched/pkgs/build-support/fetchurl/mirrors.nix;
  firstHttp = list: let ok = builtins.filter (u: lib.hasPrefix "http" u) list;
                    in if ok != [] then builtins.head ok else builtins.head list;
  expand = url:
    let m = builtins.match "mirror://([^/]+)/(.*)" url;
    in if m == null then url
       else let site = builtins.elemAt m 0; rest = builtins.elemAt m 1;
                base = firstHttp (mirrors.${site} or (throw "fetchurl-shim: unknown mirror ${site}"));
            in base + rest;
in {
  fetchurl = args@{ ... }:
    let
      rawUrl = if args ? url then args.url
               else if args ? urls then builtins.head args.urls
               else throw "fetchurl-shim: no url/urls";
      url = expand rawUrl;
      sha256 = args.hash or args.sha256
        or (throw "fetchurl-shim: no hash/sha256");
      name = args.name or (baseNameOf url);
    in builtins.fetchurl { inherit url sha256 name; };
}
