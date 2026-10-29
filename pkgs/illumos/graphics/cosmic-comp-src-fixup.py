#!/usr/bin/env python3
# cosmic-comp-src-fixup.py <cosmic-comp-src>: the illumos KMS backend edits, each GUARDED
# (a missing anchor FAILS). (1) input: the VUID source (illumos_input.rs) instead of libinput;
# (2) devices: a fixed /dev/dri/card* scan instead of udev (no udev on illumos; the link-only
# STUB libudev returns NULL, so UdevBackend::new would Err). DRM hotplug is not handled.
import sys, os, shutil
root = sys.argv[1]; here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cosmic-comp")
k = os.path.join(root, "src/backend/kms/mod.rs")
s = open(k).read()
def rep(old, new, count=1):
    global s
    if s.count(old) < count: sys.exit("FATAL: anchor x%d not found in kms/mod.rs: %r" % (count, old[:90]))
    s = s.replace(old, new)
rep("mod device;\n", "mod device;\n#[cfg(target_os = \"illumos\")]\npub mod illumos_input;\n")
# KmsState: no libinput context on illumos.
rep("    libinput: Libinput,\n", "    #[cfg(not(target_os = \"illumos\"))]\n    libinput: Libinput,\n")
rep("        libinput: libinput_context,\n", "        #[cfg(not(target_os = \"illumos\"))]\n        libinput: libinput_context,\n")
rep("""    let libinput_context = init_libinput(dh, &session, &event_loop.handle())
        .context("Failed to initialize libinput backend")?;""",
"""    #[cfg(not(target_os = "illumos"))]
    let libinput_context = init_libinput(dh, &session, &event_loop.handle())
        .context("Failed to initialize libinput backend")?;
    #[cfg(target_os = "illumos")]
    init_vuid_input(dh, &session, &event_loop.handle()).context("Failed to initialize illumos input")?;""")
rep("""        if let Err(err) = backend.libinput.resume() {
            error!(?err, "Failed to resume libinput context.");
        }""", """        #[cfg(not(target_os = "illumos"))]
        if let Err(err) = backend.libinput.resume() {
            error!(?err, "Failed to resume libinput context.");
        }""")
rep("        backend.libinput.suspend();", "        #[cfg(not(target_os = \"illumos\"))]\n        backend.libinput.suspend();")
rep("fn init_libinput(", open(os.path.join(here, "cosmic-comp-kms-illumos.rs")).read() + "\nfn init_libinput(")
open(k, "w").write(s)
# (3) name the GL device at init, at WARN (the release logger keeps smithay and cosmic_comp at warn):
# a seatd client once ran on softpipe unseen (gpu7: libdrm could not reach PCI info). Panel runs gate on this line.
d = os.path.join(root, "src/backend/kms/device.rs")
t = open(d).read()
a = "    let context =\n        EGLContext::new_with_priority(&display, ContextPriority::High)"
if t.count(a) != 1: sys.exit("FATAL: anchor not found in kms/device.rs: %r" % a[:60])
t = t.replace(a, "    tracing::warn!(software = device.is_software(), path = ?path, \"illumos: EGL device\");\n" + a)
open(d, "w").write(t)
shutil.copy(os.path.join(here, "illumos_input.rs"), os.path.join(root, "src/backend/kms/illumos_input.rs"))
shutil.copy(os.path.join(here, "hid2evdev.rs"), os.path.join(root, "src/backend/kms/hid2evdev.rs"))
print("cosmic-comp illumos source fixup: kms/mod.rs + illumos_input.rs + hid2evdev.rs", file=sys.stderr)
