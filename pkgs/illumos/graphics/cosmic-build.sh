#!/usr/bin/bash
# cosmic-build.sh -- builder for graphics/cosmic.nix cargoApp: offline cargo build of a COSMIC
# rust program with rust199 + the from-source gcc, store RUNPATH baked at link time, then the
# mk-src-pkg closure gate (no global errno, no gate/gcc path, ldd resolves inside /nix/store).
set -eu
export PATH=/usr/gnu/bin:/usr/bin:/usr/sbin
W=$NIX_BUILD_TOP; cd "$W"
RP=""; PCD=""
for d in $libDirs; do
  [ -d "$d/lib/amd64" ] && RP="$RP:$d/lib/amd64"
  for s in lib/amd64/pkgconfig share/pkgconfig; do [ -d "$d/$s" ] && PCD="$PCD:$d/$s"; done
done
RP="$out/lib:${RP#:}:$gccLibDir/amd64"
# -L every store lib dir: some -sys crates link a bare -lfoo without pkg-config
# (pixman-sys, xkbcommon), and the cc's sysroot is the gate proto, so no host lib dir is searched.
LD="-L$out/lib"; for d in $(echo "$RP" | tr ':' ' '); do LD="$LD -L$d"; done
mkdir -p w home "$out/lib"
printf '#!/usr/bin/bash\nexec %s/bin/gcc -m64 -D_TS_ERRNO %s -Wl,-R,%s "$@" -g0\n' "$gcc" "$LD" "$RP" > w/cc
chmod +x w/cc
export PATH="$W/w:$rust/bin:$PATH" HOME="$W/home" CARGO_HOME="$W/home/.cargo"
export CC=$W/w/cc CC_x86_64_unknown_illumos=$W/w/cc CARGO_TARGET_X86_64_UNKNOWN_ILLUMOS_LINKER=$W/w/cc
tar xzf "$src"; cd "$(ls -d */ | head -1)"
cp -r "$vendor" vendor; chmod -R u+w vendor
cmp -s Cargo.lock vendor/.Cargo.lock || { echo "FATAL: vendor FOD is for another Cargo.lock" >&2; exit 1; }
bash "$fixups/cosmic-comp-vendor-fixup.sh" "$PWD/vendor"
if [ -n "$stubsSh" ]; then
  CC=$W/w/cc bash "$stubsSh" vendor "$out/lib"   # link-only STUB libudev/libinput (see the script)
  PCD="$out/lib/pkgconfig:${PCD#:}"
fi
export PKG_CONFIG_PATH="${PCD#:}" PKG_CONFIG_LIBDIR="${PCD#:}"
mkdir -p .cargo; cp vendor/.cargo-config.toml .cargo/config.toml
eval "$prep"
# --offline, not --frozen: dropping softbuffer/kms prunes drm from the lock graph (no fetch is possible).
cargo build --release --offline --no-default-features ${features:+--features "$features"} -j "${NIX_BUILD_CORES:-16}"
mkdir -p "$out/bin"
for b in $bins; do
  if [ -n "$wrap" ]; then  # makeWrapper --set-default analog: env defaults, then the real binary
    mkdir -p "$out/libexec"; cp "target/release/$b" "$out/libexec/$b"
    { echo '#!/usr/bin/bash'; for kv in $wrap; do echo ": \"\${${kv%%=*}:=${kv#*=}}\"; export ${kv%%=*}"; done
      echo "exec $out/libexec/$b \"\$@\""; } > "$out/bin/$b"; chmod +x "$out/bin/$b"
  else cp "target/release/$b" "$out/bin/"; fi
done
cd "$W"
: > fail
bash "$tsErrnoGate" "$out" 2>> fail || echo "ts-errno gate failed" >> fail
find "$out" -type f > files
while read -r f; do
  [ "$(od -An -tx1 -N4 "$f" | tr -d ' \n')" = 7f454c46 ] || continue
  chmod u+w "$f"; /usr/bin/gstrip --strip-debug "$f"
  for x in "$gate" "$gcc/"; do grep -q "$x" "$f" && echo "$f names $x" >> fail; done
  /usr/bin/elfdump -d "$f" 2>/dev/null | grep -q NEEDED || continue
  for e in $(/usr/bin/elfdump -d "$f" | awk '$2=="RUNPATH"||$2=="RPATH"{print $4}' | tr ':' ' '); do
    case "$e" in /nix/store/*|'$ORIGIN'*) ;; *) echo "$f RUNPATH $e" >> fail;; esac
  done
  (unset LD_LIBRARY_PATH; /usr/bin/ldd "$f") 2>&1 | awk -v f="$f" '/not found/ || (/=>/ && $NF !~ /^\/nix\/store\//) {print f": "$0}' >> fail
done < files
if [ -s fail ]; then echo "FATAL: closure gate failed:" >&2; head -40 fail >&2; exit 1; fi
echo "=== $name: every ELF resolves inside /nix/store ===" >&2
