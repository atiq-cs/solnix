# desktop/gtk/devtools.nix -- the build-only tools Firefox's mach needs (nixpkgs nativeBuildInputs): nodejs, cbindgen.
{ mkSrcPkg, tools, cargoPkg, zlib, openssl, nixChain, world, python3 ? null }:
rec {
  # nodejs 24 (nixpkgs' nodejs at 7f81d69): bundled ICU/libuv/c-ares/nghttp2 (nixpkgs shares them; solnix has none of
  # them from source yet), shared zlib + openssl + brotli. OI's two node24 patches (pid_t cast for uv_os_getppid,
  # madvise(void *) for the illumos prototype). No npm/corepack (Firefox runs node scripts only).
  nodejs = mkSrcPkg {
    pname = "nodejs"; version = "24.18.0";
    src = { url = "https://nodejs.org/dist/v24.18.0/node-v24.18.0.tar.xz";
            sha256 = "e94afde24db08e0c564ee7110a2d5aab51ee0059382c9fd8233c54eec47b28f9"; };
    deps = [ zlib openssl nixChain.brotli world ];   # world: libkstat.so.1 (node.gypi solaris -lkstat; not in the libc slice)
    build = ''
      ${tools.path}
      patch -p1 < ${./patches/nodejs-24-illumos-cast-pid_t.patch}
      patch -p1 < ${./patches/nodejs-24-illumos-madvise.patch}
      patch -p1 < ${./patches/nodejs-24-snapshot-padding.patch}   # upstream c988b7d3: snapshot bytes from heap padding (--check differed)
      # --no-cross-compiling as nixpkgs: a host and a target toolset would both emit libv8_zlib.a ("multiple rules", measured).
      # gyp's make generator, as OI: common.gypi makes every solaris static lib standalone, which the ninja generator puts in
      # out/Release/ while node.gypi's --whole-archive names obj/deps/uv/libuv.a (node_mksnapshot link failed, measured).
      python3 configure.py --prefix="$out" --no-cross-compiling --dest-os=solaris --dest-cpu=x64 --with-intl=full-icu \
        --without-npm --without-corepack --openssl-use-def-ca-store \
        --shared-zlib --shared-zlib-includes=${zlib}/include --shared-zlib-libpath=${zlib}/lib/amd64 \
        --shared-openssl --shared-openssl-includes=${openssl}/include --shared-openssl-libpath=${openssl}/lib/amd64 \
        --shared-brotli --shared-brotli-includes=${nixChain.brotli}/include --shared-brotli-libpath=${nixChain.brotli}/lib/amd64
      gmake -C out -j''${NIX_BUILD_CORES:-8} BUILDTYPE=Release
      python3 tools/install.py install --dest-dir "" --prefix "$out"
      find "$out/share/doc" -delete 2>/dev/null || true
      "$out/bin/node" -e 'const c = require("crypto"), z = require("zlib");
        if (z.gunzipSync(z.gzipSync("solnix")).toString() !== "solnix") process.exit(2);
        console.log("node-ok", process.version, c.createHash("sha256").update("").digest("hex").slice(0, 8), new Intl.NumberFormat("de-DE").format(1234.5))' \
        | grep -qx 'node-ok v24.18.0 e3b0c442 1.234,5' || { echo "FATAL: node self-test" >&2; exit 1; }
    '';
  };

  # cbindgen 0.29.4 (nixpkgs rust-cbindgen; OI's firefox recipe `cargo install --vers 0.29.4 cbindgen`).
  cbindgen = cargoPkg {
    pname = "cbindgen"; version = "0.29.4";
    src = { url = "https://codeload.github.com/mozilla/cbindgen/tar.gz/refs/tags/v0.29.4";
            sha256 = "9b5757e915cf8be523d3aca282b9b5651bafa112e14bf1ba488562ba282807d6"; };
    vendorHash = "sha256-P4FJ0vTLusee7n/cRRE0vyUFV3TfliBHmBFNQ4wijdA=";   # chef rust199 cargo vendor --locked
    bins = "cbindgen";
    check = ''"$out/bin/cbindgen" --version | grep -qx 'cbindgen 0.29.4' || { echo "FATAL: cbindgen --version" >&2; exit 1; }'';
  };
}
