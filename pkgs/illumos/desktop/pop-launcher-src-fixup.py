#!/usr/bin/env python3
# pop-launcher-src-fixup.py <src> <out> <fd>: NixOS's postPatch (pkgs/by-name/po/pop-launcher) plus the illumos
# cut, each GUARDED (a missing anchor FAILS, so a tag bump cannot turn a fix into a silent no-op).
import sys, os
root, out, fd = sys.argv[1:4]
def edit(path, old, new, count=1):
    p = os.path.join(root, path); s = open(p).read()
    if s.count(old) != count:
        sys.exit("FATAL: pop-launcher %s: anchor x%d (want %d): %r" % (path, s.count(old), count, old[:80]))
    open(p, "w").write(s.replace(old, new))
# NixOS: plugins and scripts from the store, fd by store path, the terminal fallback from PATH. qalc stays a PATH
# lookup (no libqalculate here: the calc plugin answers "qalc command is not installed").
edit("src/lib.rs", "/usr/lib/pop-launcher", out + "/share/pop-launcher")
edit("plugins/src/scripts/mod.rs", "/usr/lib/pop-launcher", out + "/share/pop-launcher")
edit("plugins/src/find/mod.rs", 'spawn("fd")', 'spawn("%s/bin/fd")' % fd)
edit("plugins/src/terminal/mod.rs", "/usr/bin/gnome-terminal", "gnome-terminal")
# async-pidfd is compile_error! off Linux (pidfd_open). Only the pulse plugin waits on a pidfd: elsewhere it waits
# for the child on tokio's blocking pool. The lock keeps the crate (Cargo.lock is per workspace, all targets).
edit("plugins/Cargo.toml", 'async-pidfd = "0.1.5"\n', "")
edit("plugins/Cargo.toml", "\n[dependencies.reqwest]",
     '\n[target.\'cfg(target_os = "linux")\'.dependencies]\nasync-pidfd = "0.1.5"\n\n[dependencies.reqwest]')
edit("plugins/src/pulse/mod.rs", "use async_pidfd::AsyncPidFd;\n", '#[cfg(target_os = "linux")]\nuse async_pidfd::AsyncPidFd;\n')
edit("plugins/src/pulse/mod.rs", "    let _ = AsyncPidFd::from_pid(child.id() as i32)?.wait().await;\n",
     '    #[cfg(target_os = "linux")]\n    let _ = AsyncPidFd::from_pid(child.id() as i32)?.wait().await;\n'
     '    #[cfg(not(target_os = "linux"))]\n    let _ = tokio::task::spawn_blocking(move || { let mut child = child; child.wait() }).await;\n')
print("pop-launcher illumos source fixup: 6 files", file=sys.stderr)
