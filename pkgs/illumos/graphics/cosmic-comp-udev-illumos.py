#!/usr/bin/env python3
# cosmic-comp-udev-illumos.py <smithay/src/backend/udev.rs>: an illumos arm for smithay's
# udev backend. GUARDED: each anchor must exist exactly as expected or this exits non-zero.
#   UdevBackend::new  -> devices from /dev/dri/card*, `monitor` = the read end of a pipe whose
#                        write end is held open, so it is never readable (no hotplug events).
#   gpus/primary_gpu/all_gpus/driver -> /dev/dri/card* scan, no udev Device objects.
import sys
p = sys.argv[1]; s = open(p).read()
def rep(old, new):
    global s
    if s.count(old) != 1: sys.exit("FATAL: udev.rs anchor x%d (want 1): %r" % (s.count(old), old[:80]))
    s = s.replace(old, new)
I, N = '#[cfg(target_os = "illumos")]', '#[cfg(not(target_os = "illumos"))]'
rep("use udev::{Device, Enumerator, EventType, MonitorBuilder, MonitorSocket};",
    N + "\nuse udev::{Device, Enumerator, EventType, MonitorBuilder, MonitorSocket};\n" + I +
    "\ntype MonitorSocket = std::fs::File;")
rep("    monitor: MonitorSocket,\n", "    monitor: MonitorSocket,\n    " + I + "\n    _hold: std::fs::File,\n")
rep('            .field("monitor", &format!("MonitorSocket ({:?})", self.monitor.as_raw()))\n',
    '            .field("monitor", &"MonitorSocket")\n')
rep("        use udev::AsRaw;\n", "")
rep("""        let monitor = MonitorBuilder::new()?.match_subsystem("drm")?.listen()?;
""", N + """
        let monitor = MonitorBuilder::new()?.match_subsystem("drm")?.listen()?;
        """ + I + """
        let (monitor, _hold) = {
            let (r, w) = rustix::pipe::pipe()?;
            (std::fs::File::from(r), std::fs::File::from(w))
        };
""")
rep("            monitor,\n            token: None,", "            monitor,\n            " + I + "\n            _hold,\n            token: None,")
rep("        for event in self.monitor.iter() {", "        " + N + "\n        for event in self.monitor.iter() {")
# Device scans: the illumos versions go before the udev ones, which become not-illumos.
for f in ("pub fn primary_gpu<", "pub fn all_gpus<", "fn gpus_for_seat<", "pub fn driver("):
    rep(f, N + "\n" + f)
s += '''
''' + I + '''
fn illumos_cards() -> io::Result<Vec<PathBuf>> {
    let mut v: Vec<PathBuf> = std::fs::read_dir("/dev/dri")?.flatten().map(|e| e.path())
        .filter(|p| p.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.starts_with("card")))
        .collect();
    v.sort();
    Ok(v)
}
''' + I + '''
/// illumos: the first /dev/dri/card* (no udev, so no boot_vga attribute to read).
pub fn primary_gpu<S: AsRef<str>>(_seat: S) -> io::Result<Option<PathBuf>> {
    Ok(illumos_cards().unwrap_or_default().into_iter().next())
}
''' + I + '''
/// illumos: every /dev/dri/card*, sorted.
pub fn all_gpus<S: AsRef<str>>(_seat: S) -> io::Result<Vec<PathBuf>> {
    Ok(illumos_cards().unwrap_or_default())
}
''' + I + '''
/// illumos: no udev driver lookup.
pub fn driver(_dev: dev_t) -> io::Result<Option<OsString>> {
    Ok(None)
}
'''
open(p, "w").write(s)
print("smithay udev.rs: illumos arm applied", file=sys.stderr)
