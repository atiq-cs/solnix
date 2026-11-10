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
    # cosmic-greeter run as the user is the screen locker. Without logind (NixOS's build waits for logind's
    # Lock signal) it locks at once (locker.rs), and its PAM unlock runs unprivileged, which illumos
    # pam_unix_auth refuses (no unix_chkpwd): a lock at login that cannot be unlocked (measured on lixi).
    edit("src/main.rs", '\tlet span = info_span!(parent: None, "cosmic-greeter");\n\tstart_component("cosmic-greeter", span, &process_manager, &env_vars).await;\n',
         '\t#[cfg(not(target_os = "illumos"))]\n\t{\n\t\tlet span = info_span!(parent: None, "cosmic-greeter");\n'
         '\t\tstart_component("cosmic-greeter", span, &process_manager, &env_vars).await;\n\t}\n')
elif app == "cosmic-settings-daemon":
    # cosmic-pipewire (the audio server's backend) is a PipeWire client; illumos has no PipeWire. Gate the
    # client (pipewire/libspa deps, the registry service, the pod parsers) off illumos and keep the data
    # types: run() logs and returns without a Sender, so the audio server has no devices -- what Linux
    # does with no PipeWire daemon. NixOS ships the daemon (services.desktopManager.cosmic corePkgs).
    NI = '#[cfg(not(target_os = "illumos"))]\n'
    c = "cosmic-pipewire/Cargo.toml"
    edit(c, 'libspa = "0.10.0"\nlibspa-sys = "0.10.0"\npipewire = "0.10.0"\n', "")
    edit(c, 'tracing = "0.1.44"\n', 'tracing = "0.1.44"\n\n[target.\'cfg(not(target_os = "illumos"))\'.dependencies]\n'
         'libspa = "0.10.0"\nlibspa-sys = "0.10.0"\npipewire = "0.10.0"\n')
    l = "cosmic-pipewire/src/lib.rs"
    for u in ("use libspa::param::ParamType;", "use libspa::param::format::FormatProperties;",
              "use libspa::pod::serialize::PodSerializer;", "use libspa::pod::{self, Pod};", "use libspa::utils::SpaTypes;",
              "use pipewire::device::{DeviceChangeMask, DeviceListener};", "use pipewire::main_loop::MainLoopWeak;",
              "use pipewire::metadata::MetadataListener;", "use pipewire::node::NodeListener;",
              "use pipewire::proxy::{ProxyListener, ProxyT};", "use pipewire::registry::{GlobalObject, Registry};",
              "use pipewire::types::ObjectType;", "use std::cell::RefCell;", "use std::rc::Rc;", "use std::time::Duration;"):
        edit(l, "\n" + u + "\n", "\n" + NI + u + "\n")
    for item in ("pub fn run(\n", "fn run_service(\n", "fn bind_device<P>(", "fn bind_node<P>(", "fn bind_metadata<P>(",
                 "struct Proxies {\n", "struct State {\n", "impl State {\n", "pub struct Sender(pipewire",
                 "impl Sender {\n", "impl Drop for Sender {\n", "impl std::fmt::Debug for Sender {\n"):
        edit(l, "\n" + item, "\n" + NI + item)
    edit(l, "\npub mod volume {", """
#[cfg(target_os = "illumos")]
pub fn run(_on_event: impl FnMut(Event) + Send + 'static, _on_sender: impl FnMut(Sender) + Send + 'static) {
    tracing::warn!("no PipeWire on illumos: the audio server has no devices");
}

/// illumos: never constructed (run() hands none out); requests have nowhere to go.
#[cfg(target_os = "illumos")]
#[derive(Debug)]
pub struct Sender(());

#[cfg(target_os = "illumos")]
impl Sender {
    pub fn send(&self, request: Request) -> Result<(), Request> {
        Err(request)
    }
}

pub mod volume {""")
    edit(l, "\npub mod device;\n", "\n" + NI + "pub mod device;\n" + NI + "pub use device::Device;\n"
         '#[cfg(target_os = "illumos")]\n#[derive(Clone, Debug)]\npub struct Device { pub id: u32, pub name: String, '
         'pub description: String, pub icon_name: String }\n')
    edit(l, "\npub use device::Device;\n\npub mod node;", "\n\npub mod node;")
    for f, items in (("cosmic-pipewire/src/node.rs", ("use libspa::pod::Pod;", "use libspa::utils::Id;",
                       "use pipewire::node::{NodeInfoRef, NodeState};", "use crate::spa_utils::array_from_pod;",
                       "impl Node {", "impl NodeProps {")),
                     ("cosmic-pipewire/src/profile.rs", ("use std::ffi::c_int;", "use crate::spa_utils::{array_from_pod, string_from_pod};",
                       "use libspa::pod::Pod;", "impl Profile {")),
                     ("cosmic-pipewire/src/route.rs", ("use std::ffi::{c_float, c_int};", "use crate::spa_utils::{array_from_pod, string_from_pod};",
                       "use libspa::pod::Pod;", "use libspa::utils::Id;", "impl Route {")),
                     ("cosmic-pipewire/src/spa_utils.rs", ("use libspa::pod::Pod;", "use std::ffi::CStr;",
                       "pub fn string_from_pod(", "pub unsafe fn array_from_pod<"))):
        for it in items:
            edit(f, "\n" + it, "\n" + NI + it)
elif app == "cosmic-applets":
    for f in ("cosmic-app-list/src/wayland_handler.rs", "cosmic-applet-minimize/src/wayland_handler.rs"):
        edit(f, MEMFD, MEMFD_SHM)
    # bluer (BlueZ) is compile_error! on non-Linux: the multicall binary drops the bluetooth applet.
    edit("cosmic-applets/Cargo.toml", 'cosmic-applet-bluetooth = { path = "../cosmic-applet-bluetooth" }\n', "")
    edit("cosmic-applets/src/main.rs", '        "cosmic-applet-bluetooth" => cosmic_applet_bluetooth::run(),\n', "")
elif app == "cosmic-greeter":
    # epoch-1.11.0 asks image for avif-native (dav1d-sys -> a system libdav1d via pkg-config); solnix has no dav1d, so
    # the greeter's wallpaper decoder drops AVIF, as cosmic-bg and cosmic-settings already do (png/jpeg/webp/hdr/jxl stay).
    if "    \"avif-native\",\n" in open(os.path.join(root, "Cargo.toml")).read():
        edit("Cargo.toml", '    "avif-native",\n    "jpeg",\n', '    "jpeg",\n')
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
