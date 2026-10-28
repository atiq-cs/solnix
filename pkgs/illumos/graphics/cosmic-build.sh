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
# A link naming -lclang is a bindgen build script (pam-sys) on the host libclang, a build tool like
# meson's host python. It links against the HOST runtime only: with the store RUNPATH it loaded the
# store libc AND libclang's host libc (pldd), and aborted in _thrp_exit on clang's parse thread.
{ echo '#!/usr/bin/bash'
  echo 'case " $* " in *" -lclang "*) exec '"$gcc"'/bin/gcc -m64 "$@" -L/usr/clang/21/lib -L/usr/lib/amd64 -Wl,-R,/usr/clang/21/lib:/usr/gcc/14/lib/amd64:/usr/lib/amd64 -g0 ;; esac'
  echo "exec $gcc/bin/gcc -m64 -D_TS_ERRNO $LD -Wl,-R,$RP \"\$@\" -g0"; } > w/cc
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
# gettext-sys: the illumos libintl (a libc filter) instead of its bundled gettext 0.26 build.
export GETTEXT_DIR="$gate" GETTEXT_LIB_DIR="$gate/usr/lib/amd64" GETTEXT_INCLUDE_DIR="$gate/usr/include"
export LIBCLANG_PATH=/usr/clang/21/lib BINDGEN_EXTRA_CLANG_ARGS="-I$gate/usr/include"   # bindgen (pam-sys): host clang, a build tool
mkdir -p .cargo; cp vendor/.cargo-config.toml .cargo/config.toml
if [ -n "$appFixups" ]; then  # the shell/apps (cosmicApp); cosmic-comp and cosmic-term keep their own
  [ -d vendor/libcosmic ] && python3 "$fixups/cosmic-widen-linux.py" vendor libcosmic 'iced?' 'iced_core?' 'iced_runtime?' 'iced_winit?' 'iced_widget?'
  python3 "$fixups/cosmic-apps-src-fixup.py" "$appFixups" "$PWD"
fi
eval "$prep"
# --offline, not --frozen: dropping softbuffer/kms prunes drm from the lock graph (no fetch is possible).
cargo build --release --offline --no-default-features ${features:+--features "$features"} $cargoArgs -j "${NIX_BUILD_CORES:-16}"
T=${CARGO_TARGET_DIR:-target}/release
mkdir -p "$out/bin"
for b in $bins; do
  if [ -n "$wrap" ]; then  # makeWrapper --set-default analog: env defaults, then the real binary
    mkdir -p "$out/libexec"; cp "$T/$b" "$out/libexec/$b"
    { echo '#!/usr/bin/bash'; for kv in $wrap; do echo ": \"\${${kv%%=*}:=${kv#*=}}\"; export ${kv%%=*}"; done
      echo "exec -a \"\$0\" $out/libexec/$b \"\$@\""; } > "$out/bin/$b"; chmod +x "$out/bin/$b"
  else cp "$T/$b" "$out/bin/"; fi
done
. "$fixups/cosmic-data.sh"; eval "$install"   # data files (desktop entries, schemas, icons), in the source dir
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
  (unset LD_LIBRARY_PATH; /usr/bin/ldd -r "$f") 2>&1 | awk -v f="$f" '/symbol not found/ {print f": "$0}' >> fail
  (unset LD_LIBRARY_PATH; /usr/bin/ldd "$f") 2>&1 | awk -v f="$f" '/not found/ || (/=>/ && $NF !~ /^\/nix\/store\//) {print f": "$0}' >> fail
done < files
if [ -s fail ]; then echo "FATAL: closure gate failed:" >&2; head -40 fail >&2; exit 1; fi
echo "=== $name: every ELF resolves inside /nix/store ===" >&2
# Run check: every program starts with all symbols bound (LD_BIND_NOW: a STUB or a missing
# symbol fails here, not at first use) and reaches main. No compositor or bus here, so an
# error exit is expected for GUI programs; a runtime-linker error or a signal death fails.
# runok <bin> <args..>: one run, output kept in $out/share/solnix-check/<bin>.txt.
runok() {
  local b=$1 rc=0 o="$out/share/solnix-check/$1.txt"; shift; mkdir -p "$out/share/solnix-check"
  (cd "$W"; unset WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS DISPLAY; export XDG_RUNTIME_DIR="$W/home" LD_BIND_NOW=1
    exec /usr/bin/timeout 20 "$out/bin/$b" "$@" < /dev/null) > "$o" 2>&1 || rc=$?
  echo "rc=$rc" >> "$o"
  # ld.so.1 fatal errors end in SIGKILL (137); a hang is timeout's 124 (still running = it started).
  # The one accepted signal: SIGABRT (134) from a panic=abort profile whose panic is "no display"
  # (iced_winit: no WAYLAND_DISPLAY here), i.e. main ran with every symbol bound.
  local nodisp='neither WAYLAND_DISPLAY nor WAYLAND_SOCKET nor DISPLAY is set'
  if [ $rc -eq 134 ] && /usr/gnu/bin/grep -q "$nodisp" "$o"; then rc=0; fi
  if /usr/gnu/bin/grep -Eq 'ld\.so\.1: .*fatal|relocation error|symbol not found' "$o" || { [ $rc -ge 128 ]; }; then
    echo "FATAL: run check $b $* (rc=$rc):" >&2; head -20 "$o" >&2; exit 1; fi
  echo "run check $b $*: rc=$rc: $(head -c 200 "$o" | tr '\n' ' ')" >&2
}
eval "${check:-for b in $bins; do runok \$b --help; done}"
