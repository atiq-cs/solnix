#!/usr/bin/bash
# cosmic-comp-vendor-fixup.sh <vendor-dir>: illumos arms in vendored crates, each GUARDED
# (a missing anchor FAILS, so an upstream bump cannot turn a fix into a silent no-op), then
# re-stamps .cargo-checksum.json for every edited file. Called from the cosmic-comp derivation.
set -eu
V=$1; cd "$V"
have() { [ -d "$V/$1" ]; }
edit() { # edit <crate> <file> <python-literal-old> <python-literal-new>; no-op if <crate> is absent
  have "$1" || { echo "skip $1 (not vendored)" >&2; return 0; }
  python3 - "$1/$2" "$3" "$4" <<'PY'
import sys, ast
p, o, n = sys.argv[1], ast.literal_eval(sys.argv[2]), ast.literal_eval(sys.argv[3])
s = open(p).read()
if o not in s: sys.exit("FATAL: anchor not found in %s: %r" % (p, o[:80]))
open(p, "w").write(s.replace(o, n))
PY
  echo "$1 $2" >> "$V/.illumos-edited"
}
: > "$V/.illumos-edited"

# 1. rustix ioctl: solarish uses the Linux _IOC opcode encoding, which the illumos i915 port
#    decodes (src/drm-port/i915/i915_drmioc.h). Without it drm-ffi fails E0432.
for r in rustix rustix-0.38.44; do
  have $r || continue
  f=src/ioctl/mod.rs
  if grep -qF '#[cfg(any(linux_kernel, target_os = "redox"))]' "$r/$f"; then lk='any(linux_kernel, target_os = "redox")'; lkb='any(linux_kernel, bsd, target_os = "redox")'
  else lk='linux_kernel'; lkb='any(linux_kernel, bsd)'; fi
  edit $r $f "'#[cfg($lk)]\nmod linux;'" "'#[cfg(any($lk, solarish))]\nmod linux;'"
  edit $r $f "'#[cfg($lk)]\nuse linux as platform;'" "'#[cfg(any($lk, solarish))]\nuse linux as platform;'"
  python3 - "$r/$f" "$lkb" <<'PY'
import sys
p, g = sys.argv[1], sys.argv[2]
s = open(p).read(); n = s.count("#[cfg(%s)]" % g)
if n < 2: sys.exit("FATAL: %s has %d %s gates" % (p, n, g))
open(p, "w").write(s.replace("#[cfg(%s)]" % g, "#[cfg(any(%s, solarish))]" % g[4:-1]))  # g = any(...)
PY
  echo "$r $f" >> "$V/.illumos-edited"
done

# rustix 0.38's typed opcodes (ReadOpcode, ...), used by drm-ffi 0.7.1 (softbuffer's drm 0.11).
edit rustix-0.38.44 src/ioctl/patterns.rs "'#[cfg(any(linux_kernel, bsd))]'" "'#[cfg(any(linux_kernel, bsd, solarish))]'"

# 2. wayland-backend: illumos has epoll (the server poll arm) and no MSG_CMSG_CLOEXEC; the
#    same three cuts as solnix-pkgs cosmic-term.nix.
wg='any(target_os = "linux", target_os = "android", target_os = "redox")'
wn='any(target_os = "linux", target_os = "android", target_os = "redox", target_os = "illumos", target_os = "solaris")'
for f in src/rs/server_impl/common_poll.rs src/rs/server_impl/handle.rs; do
  edit wayland-backend $f "'$wg'" "'$wn'"
done
edit wayland-backend src/rs/socket.rs "'target_os = \"macos\", target_os = \"redox\"'" \
  "'target_os = \"macos\", target_os = \"redox\", target_os = \"illumos\", target_os = \"solaris\"'"

# 3. reis (libei): illumos recvmsg has no MSG_CMSG_CLOEXEC.
edit reis src/util.rs "'            net::RecvFlags::CMSG_CLOEXEC,'" \
  "'            #[cfg(not(any(target_os = \"illumos\", target_os = \"solaris\")))]\n            net::RecvFlags::CMSG_CLOEXEC,\n            #[cfg(any(target_os = \"illumos\", target_os = \"solaris\"))]\n            net::RecvFlags::empty(),'"

# 4. winit 0.31: is_main_thread has no illumos arm (same cut as cosmic-term.nix: the netbsd one).
edit winit src/platform_impl/linux/mod.rs "'#[cfg(target_os = \"netbsd\")]\nfn is_main_thread'" \
  "'#[cfg(any(target_os = \"netbsd\", target_os = \"illumos\", target_os = \"solaris\"))]\nfn is_main_thread'"

# 5. smithay: libc's solarish siginfo_t has si_addr() as an unsafe method, not a field, and
#    solarish makedev() is an unsafe fn (Linux's is a const safe fn).
edit smithay src/wayland/shm/pool.rs "'    unsafe { (*info).si_addr as _ }'" \
  "'    #[cfg(any(target_os = \"illumos\", target_os = \"solaris\"))]\n    return unsafe { (*info).si_addr() as _ };\n    #[cfg(not(any(target_os = \"illumos\", target_os = \"solaris\")))]\n    unsafe { (*info).si_addr as _ }'"
for w in primary render; do
  edit smithay src/backend/vulkan/mod.rs "'DrmNode::from_dev_id(libc::makedev(props.${w}_major as _, props.${w}_minor as _))'" \
    "'DrmNode::from_dev_id(#[allow(unused_unsafe)] unsafe { libc::makedev(props.${w}_major as _, props.${w}_minor as _) })'"
done

# 6. smithay udev: illumos has no udev. UdevBackend lists /dev/dri/card* itself and its fd is
#    a pipe that never fires (no DRM hotplug: a documented gap); primary_gpu() takes the
#    first card. The libudev STUB (cosmic-comp-stubs.sh) only satisfies the link.
if have smithay; then
  python3 "$(dirname "$0")/cosmic-comp-udev-illumos.py" "$V/smithay/src/backend/udev.rs"
  echo "smithay src/backend/udev.rs" >> "$V/.illumos-edited"
fi

# 7. softbuffer (the client side, cosmic-term): illumos shm_open needs a leading '/', and
#    0700 is refused for shm; drop the kms default feature (drm-ffi) for clients.
edit softbuffer src/wayland/buffer.rs "'String::from(\"softbuffer-\")'" "'String::from(\"/softbuffer-\")'"
edit softbuffer src/wayland/buffer.rs "'            Mode::RWXU,'" "'            Mode::RUSR | Mode::WUSR,'"

# softbuffer's default `kms` feature pulls drm-ffi into a client that never uses it
# (cosmic-term.nix does the same). Only when NO_SOFTBUFFER_KMS is set (clients).
if [ -n "${NO_SOFTBUFFER_KMS:-}" ]; then
  edit softbuffer Cargo.toml "'default = [\n    \"kms\",\n'" "'default = [\n'"
fi

# 8. drm-rs 0.14 node (smithay's DrmNode): on non-Linux is_device_drm is `major == 226` and the
#    node type comes from the minor, but the illumos i915 cdev has a name_to_major major and
#    clone minors (clone<<16 | instance<<8 | kind 0 card / 128 render, i915_drmioc.h). Normalise
#    the dev_t to the /dev/dri node it came from (clone 0), so DrmNode equality and dev_path work.
#    Same mapping as pkgs/illumos/graphics/patches/libdrm-2.4.120-illumos-device.patch.
#    Only where smithay is vendored (cosmic-term's drm 0.11 has no node module).
if have smithay; then
edit drm src/node/mod.rs "'    pub fn from_dev_id(dev: dev_t) -> Result<Self, CreateDrmNodeError> {\n'" \
  "'    pub fn from_dev_id(dev: dev_t) -> Result<Self, CreateDrmNodeError> {\n        #[cfg(target_os = \"illumos\")]\n        let dev = illumos_node_dev(dev).ok_or(CreateDrmNodeError::NotDrmNode)?;\n'"
edit drm src/node/mod.rs "'        let ty = match minor(dev) >> 6 {'" \
  "'        #[cfg(target_os = \"illumos\")]\n        let ty = if minor(dev) & 0xff == 128 { NodeType::Render } else { NodeType::Primary };\n        #[cfg(not(target_os = \"illumos\"))]\n        let ty = match minor(dev) >> 6 {'"
edit drm src/node/mod.rs "'#[cfg(not(any(target_os = \"linux\", target_os = \"freebsd\")))]\npub fn is_device_drm(dev: dev_t) -> bool {\n    major(dev) == DRM_MAJOR\n}'" \
  "'#[cfg(target_os = \"illumos\")]\nfn illumos_node_dev(dev: dev_t) -> Option<dev_t> {\n    let m = minor(dev) & 0xffff; // drop the clone index\n    if m & 0xff != 0 && m & 0xff != 128 {\n        return None; // the console text minor (64) is not a DRM node\n    }\n    let d = rustix::fs::makedev(major(dev), m);\n    let id = ((m >> 8) & 0xff) + (m & 0xff); // instance + 0 (card) / 128 (renderD)\n    let p = format!(\"/dev/dri/{}{}\", if m & 0xff == 128 { RENDER_NAME } else { PRIMARY_NAME }, id);\n    (stat(p.as_str()).ok()?.st_rdev == d).then_some(d) // the named node must be this device\n}\n\n/// Returns if the given device by major:minor pair is a DRM device.\n#[cfg(target_os = \"illumos\")]\npub fn is_device_drm(dev: dev_t) -> bool {\n    illumos_node_dev(dev).is_some()\n}\n\n#[cfg(not(any(target_os = \"linux\", target_os = \"freebsd\", target_os = \"illumos\")))]\npub fn is_device_drm(dev: dev_t) -> bool {\n    major(dev) == DRM_MAJOR\n}'"
edit drm src/node/mod.rs "'    let old_id = minor(dev);\n    let id_mask = 0b11_1111;\n    let id = old_id & id_mask + ty.minor_base();'" \
  "'    #[cfg(target_os = \"illumos\")]\n    let id = ((minor(dev) >> 8) & 0xff) + ty.minor_base(); // instance + 0 / 128\n    #[cfg(not(target_os = \"illumos\"))]\n    let id = {\n        let old_id = minor(dev);\n        let id_mask = 0b11_1111;\n        old_id & id_mask + ty.minor_base()\n    };'"

fi

# 9. smithay SealedFile (dmabuf feedback format table, keymaps): its non-Linux arm shm_open()s
#    "name-XXXXXXX"; illumos shm_open needs a leading '/' (EINVAL otherwise, measured
#    /scratch/solnix/gpu3/t/shm.c), the same fix as softbuffer's (item 7).
edit smithay src/utils/sealed_file.rs "'            let mut shm_name = name.to_bytes().to_owned();'" \
  "'            let mut shm_name = b\"/\".to_vec();\n            shm_name.extend_from_slice(name.to_bytes());'"

# Required per app: fail if an expected crate was not vendored at all.
for c in ${REQUIRED:-}; do have $c || { echo "FATAL: required crate $c not vendored" >&2; exit 1; }; done

# re-stamp checksums of every edited file
sort -u "$V/.illumos-edited" | while read -r c f; do
  new=$(sha256sum "$c/$f" | cut -d' ' -f1); sum="$c/.cargo-checksum.json"
  grep -q "\"$f\":\"[0-9a-f]\{64\}\"" "$sum" || { echo "FATAL: no checksum entry $c/$f" >&2; exit 1; }
  sed -i "s|\"$f\":\"[0-9a-f]\{64\}\"|\"$f\":\"$new\"|" "$sum"
done
echo "illumos vendor fixups: $(sort -u "$V/.illumos-edited" | wc -l) files" >&2
