#!/usr/bin/env python3
# greetd-illumos.py <greetd-src>: the illumos edits for greetd 0.10.3, each GUARDED (a missing
# anchor FAILS). vt(4I): VTs are /dev/vt/N (N >= 2), VT 1 is /dev/console, the VT ioctls are
# ('V'<<8)|n and KDSETMODE is ('K'<<8)|10 (illumos <sys/vt.h>, <sys/kd.h>, <sys/termios.h>),
# VT_OPENQRY fills an int. No PR_SET_PDEATHSIG: under SMF the session dies with greetd's
# process contract when the service stops, which is what the death signal is for.
import sys, os
root = sys.argv[1]
def edit(path, old, new, count=1):
    p = os.path.join(root, path); s = open(p).read()
    if s.count(old) != count: sys.exit("FATAL: greetd %s: anchor x%d (want %d): %r" % (path, s.count(old), count, old[:80]))
    open(p, "w").write(s.replace(old, new))
I, N = '#[cfg(target_os = "illumos")]\n', '#[cfg(not(target_os = "illumos"))]\n'
io = "greetd/src/terminal/ioctl.rs"
lin = ("pub const KDSETMODE: u16 = 0x4B3A;", "pub const VT_OPENQRY: u16 = 0x5600;", "pub const VT_SETMODE: u16 = 0x5602;",
       "pub const VT_GETSTATE: u16 = 0x5603;", "pub const VT_ACTIVATE: u16 = 0x5606;", "pub const VT_WAITACTIVE: u16 = 0x5607;",
       "pub const TIOCSCTTY: u16 = 0x540E;")
ill = ("pub const KDSETMODE: u16 = (0x4B << 8) | 10;", "pub const VT_OPENQRY: u16 = (0x56 << 8) | 1;",
       "pub const VT_SETMODE: u16 = (0x56 << 8) | 2;", "pub const VT_GETSTATE: u16 = (0x56 << 8) | 100;",
       "pub const VT_ACTIVATE: u16 = (0x56 << 8) | 5;", "pub const VT_WAITACTIVE: u16 = (0x56 << 8) | 6;",
       "pub const TIOCSCTTY: u16 = (0x74 << 8) | 132;")   # tIOC = ('t'<<8), termios.h:403
for l, i in zip(lin, ill):
    edit(io, l + "\n", N + l + "\n" + I + i + "\n")
edit(io, "ioctl_read_bad!(vt_openqry, VT_OPENQRY, i64);",
     N + "ioctl_read_bad!(vt_openqry, VT_OPENQRY, i64);\n" + I + "ioctl_read_bad!(vt_openqry, VT_OPENQRY, i32);")
tm = "greetd/src/terminal/mod.rs"
edit(tm, "        let mut next_vt: i64 = 0;", "        #[cfg(target_os = \"illumos\")]\n        let mut next_vt: i32 = 0;\n"
     "        #[cfg(not(target_os = \"illumos\"))]\n        let mut next_vt: i64 = 0;")
edit(tm, "ioctl::vt_openqry(self.fd, &mut next_vt as *mut i64)", "ioctl::vt_openqry(self.fd, &mut next_vt as *mut _)")
sv = "greetd/src/server.rs"
edit(sv, '    const TTY_PREFIX: &str = "/dev/tty";',
     '    #[cfg(not(target_os = "illumos"))]\n    const TTY_PREFIX: &str = "/dev/tty";\n'
     '    #[cfg(target_os = "illumos")]\n    const TTY_PREFIX: &str = "/dev/vt/";')
edit(sv, 'Terminal::open("/dev/tty0")', 'Terminal::open(if cfg!(target_os = "illumos") { "/dev/console" } else { "/dev/tty0" })', 2)
edit(sv, 'path: format!("/dev/tty{}", vt),', 'path: format!("{}{}", TTY_PREFIX, vt),', 3)
pr = "greetd/src/session/prctl.rs"
edit(pr, "            libc::prctl(PRCTL_SET_PDEATHSIG, sig, 0, 0, 0)",
     "            { #[cfg(not(target_os = \"illumos\"))] { libc::prctl(PRCTL_SET_PDEATHSIG, sig, 0, 0, 0) }\n"
     "              #[cfg(target_os = \"illumos\")] { let _ = sig; 0 } }")
# PAM conversation ABI: illumos libpam passes a pointer to an ARRAY of pam_message
# (pam_framework.c:2676-2708, calloc(num_msg, sizeof (struct pam_message)) then &msg), Linux-PAM
# an array of pointers. greetd indexes the Linux way; for num_msg > 1 that reads garbage.
edit("greetd/src/pam/ffi.rs", "        let m: &mut PamMessage = unsafe { &mut **(msg.offset(i)) };",
     "        #[cfg(not(target_os = \"illumos\"))]\n        let m: &mut PamMessage = unsafe { &mut **(msg.offset(i)) };\n"
     "        #[cfg(target_os = \"illumos\")]\n        let m: &mut PamMessage = unsafe { &mut *((*msg).offset(i)) };")
# PAM service lookup: illumos libpam reads pam.conf(5) (no pam.d) and an unlisted service
# uses the "other" stack, so greetd's /etc/pam.d/<service> existence check is skipped.
edit("greetd/src/server.rs", "    let service = if Path::new(&format!(\"/etc/pam.d/{}\", config.file.general.service)).exists() {",
     "    let service = if cfg!(target_os = \"illumos\") || Path::new(&format!(\"/etc/pam.d/{}\", config.file.general.service)).exists() {")
# illumos has /var/run (tmpfs), no /run: the greeter socket and the run file live there.
edit("greetd/src/server.rs", 'let path = format!("/run/greetd-{}.sock", getpid().as_raw());',
     'let path = format!("{}/greetd-{}.sock", if cfg!(target_os = "illumos") { "/var/run" } else { "/run" }, getpid().as_raw());')
edit("greetd/src/config/mod.rs", 'const RUNFILE: &str = "/run/greetd.run";',
     '#[cfg(not(target_os = "illumos"))]\nconst RUNFILE: &str = "/run/greetd.run";\n#[cfg(target_os = "illumos")]\nconst RUNFILE: &str = "/var/run/greetd.run";')
# PAM_TTY: illumos login(1)/ttymon pass the device path (/dev/vt/N); pam_unix_session
# (unix_session.c:124) fails PAM_SESSION_ERR on a NULL tty. Linux greetd passes "ttyN" for logind.
edit("greetd/src/session/worker.rs", '            pam.set_item(PamItemType::TTY, &format!("tty{}", vt))?;',
     '            #[cfg(not(target_os = "illumos"))]\n            pam.set_item(PamItemType::TTY, &format!("tty{}", vt))?;\n'
     '            #[cfg(target_os = "illumos")]\n            pam.set_item(PamItemType::TTY, &path)?;')
# The worker's shutdown(SHUT_RDWR) of its datagram socket races the parent's: on illumos the
# loser gets ENOTCONN (134, measured with dtrace), the ? returns before waitpid, the worker
# exits and its session child dies of SIGHUP. Ignore ENOTCONN there; the socket is done either way.
edit("greetd/src/session/worker.rs", "    SessionChildToParent::FinalChildPid(child.as_raw() as u64).send(sock)?;\n    sock.shutdown(std::net::Shutdown::Both)?;",
     "    SessionChildToParent::FinalChildPid(child.as_raw() as u64).send(sock)?;\n"
     "    if let Err(e) = sock.shutdown(std::net::Shutdown::Both) {\n"
     "        if e.kind() != std::io::ErrorKind::NotConnected { return Err(e.into()); }\n    }")
# XDG_RUNTIME_DIR: on NixOS pam_systemd/logind makes /run/user/<uid> (0700, the user's) for every
# session, the greeter's included; cosmic-comp, the greeter and the session's wayland and dbus
# sockets live there. illumos has no logind, so the worker makes /var/run/user/<uid> (tmpfs) the
# same way, before open_session, and exports it through the PAM environment.
edit("greetd/src/session/worker.rs", "    for e in env.iter().chain(prepared_env.iter()) {\n        pam.putenv(e)?;\n    }",
     "    for e in env.iter().chain(prepared_env.iter()) {\n        pam.putenv(e)?;\n    }\n"
     "    #[cfg(target_os = \"illumos\")]\n    {\n"
     "        use std::os::unix::fs::{DirBuilderExt, PermissionsExt};\n"
     "        let rd = format!(\"/var/run/user/{}\", user.uid);\n"
     "        let _ = std::fs::DirBuilder::new().recursive(true).mode(0o755).create(\"/var/run/user\");\n"
     "        let _ = std::fs::DirBuilder::new().mode(0o700).create(&rd);\n"
     "        nix::unistd::chown(rd.as_str(), Some(user.uid), Some(user.gid))?;\n"
     "        std::fs::set_permissions(&rd, std::fs::Permissions::from_mode(0o700))?;\n"
     "        pam.putenv(&format!(\"XDG_RUNTIME_DIR={}\", rd))?;\n    }")
print("greetd illumos source fixup: ioctl.rs terminal/mod.rs server.rs prctl.rs", file=sys.stderr)
