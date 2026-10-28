#!/usr/bin/env python3
# cosmic-apps-src-fixup.py <app> <src>: illumos source edits for the COSMIC apps in cosmic.nix,
# each GUARDED (a missing anchor FAILS, so an upstream bump cannot silently skip a fix).
import sys, os
app, root = sys.argv[1], sys.argv[2]
done = []
def edit(path, old, new, count=1):
    p = os.path.join(root, path); s = open(p).read()
    if s.count(old) != count:
        sys.exit("FATAL: %s: anchor x%d (want %d) in %s: %r" % (app, s.count(old), count, path, old[:90]))
    open(p, "w").write(s.replace(old, new)); done.append(path)

# illumos libc has no memfd_create(2): the POSIX-shm fallback the apps already carry for
# non-Linux, with the name made absolute (illumos shm_open needs a leading '/').
MEMFD = 'let Ok(fd) = rustix::fs::memfd_create(name, rustix::fs::MemfdFlags::CLOEXEC) else {'
# shm_open + shm_unlink: an anonymous shm fd, as cosmic-workspaces' own create_memfile fallback.
MEMFD_SHM = ('let Ok(fd) = (|| { let n = format!("/{}-{}-{}", name.to_str().unwrap_or("cosmic"), std::process::id(),'
             ' std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0));'
             ' let fd = rustix::shm::open(n.as_str(), rustix::shm::OFlags::CREATE | rustix::shm::OFlags::EXCL'
             ' | rustix::shm::OFlags::RDWR, rustix::fs::Mode::RUSR | rustix::fs::Mode::WUSR)?;'
             ' rustix::shm::unlink(n.as_str()).map(|_| fd) })() else {')

if app == "cosmic-session":
    # autostart without systemd: run the XDG autostart scan unconditionally (no systemd to do it).
    edit("src/main.rs", "\tif !*is_systemd_used() {\n\t\tinfo!(\"looking for autostart folders\");",
         "\t#[cfg(feature = \"systemd\")]\n\tlet run_autostart = !*is_systemd_used();\n"
         "\t#[cfg(not(feature = \"systemd\"))]\n\tlet run_autostart = true;\n"
         "\tif run_autostart {\n\t\tinfo!(\"looking for autostart folders\");")
elif app == "cosmic-applets":
    for f in ("cosmic-app-list/src/wayland_handler.rs", "cosmic-applet-minimize/src/wayland_handler.rs"):
        edit(f, MEMFD, MEMFD_SHM)
    # bluer (BlueZ) is compile_error! on non-Linux: the multicall binary drops the bluetooth applet.
    edit("cosmic-applets/Cargo.toml", 'cosmic-applet-bluetooth = { path = "../cosmic-applet-bluetooth" }\n', "")
    edit("cosmic-applets/src/main.rs", '        "cosmic-applet-bluetooth" => cosmic_applet_bluetooth::run(),\n', "")
elif app == "cosmic-panel":
    # Linux abstract-namespace socket (SocketAddrExt::from_abstract_name) for the applets'
    # privileged wayland socket. illumos has none: a 0700-dir filesystem socket in
    # XDG_RUNTIME_DIR, unlinked once both ends hold fds (as the solnix-pkgs panel patch did).
    f = "cosmic-panel-bin/src/xdg_shell_wrapper/client/handlers/wp_security_context.rs"
    edit(f, "use std::os::linux::net::SocketAddrExt;\n",
         "#[cfg(not(target_os = \"illumos\"))]\nuse std::os::linux::net::SocketAddrExt;\n")
    edit(f, """        let addr = SocketAddr::from_abstract_name(s)?;
        // this also listens on the socket
        let listener = UnixListener::bind_addr(&addr)?;""",
         """        #[cfg(not(target_os = "illumos"))]
        let addr = SocketAddr::from_abstract_name(s)?;
        #[cfg(target_os = "illumos")]
        let addr = SocketAddr::from_pathname(format!(
            "{}/cosmic-panel-sec-{}",
            std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".into()),
            s
        ))?;
        // this also listens on the socket
        let listener = UnixListener::bind_addr(&addr)?;""")
    edit(f, """        let conn = UnixStream::connect_addr(&addr)?;
""", """        let conn = UnixStream::connect_addr(&addr)?;
        #[cfg(target_os = "illumos")]
        if let Some(p) = addr.as_pathname() {
            let _ = std::fs::remove_file(p); // both ends hold fds now
        }
""")
print("%s illumos source fixup: %s" % (app, " ".join(sorted(set(done))) or "none"), file=sys.stderr)
