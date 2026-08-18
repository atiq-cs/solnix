# solnix — nix-pure Wayland desktop, viewable over VNC

A live, connectable **nix-pure Wayland session**: a real Wayland compositor
(smithay `smallvil`) with a real GTK4 4.22.4 / libadwaita 1.9.2 client, rendered
in **software** (llvmpipe/softpipe), exported over VNC on `127.0.0.1:5900`.

This is the /nix/store Wayland toolkit — **not** the OpenIndiana-pkg X11 stack the
AMI ships. The compositor, GTK4, libadwaita, pango, glib, cairo, harfbuzz,
gdk-pixbuf, graphene and the wayland libraries are all `/nix/store` builds.

## What renders

![solnix nix-pure Wayland desktop](solnix-gtk4-libadwaita-wayland.png)

- `smallvil` — nix-pure smithay Wayland compositor. Its winit-x11 backend opens a
  window inside Xvfb; EGL/GL is dlopen'd -> softpipe SW GL. It composites client
  surfaces and clears to dark grey `0.1`.
- `adw-hello` — a nix-pure GTK4/libadwaita client: `AdwApplicationWindow` +
  `AdwHeaderBar` + `AdwStatusPage` + a suggested-action pill button. Rendered with
  the GSK **cairo** software renderer (`GSK_RENDERER=cairo`), connected to the
  compositor over `wayland-1`.
- A raw `wl_shm` test client (`--shm`) is also included as the minimal-dependency
  proof (colored bars + a white box), useful if a client under test misbehaves.

## Connect (SSH tunnel — VNC is bound to localhost only)

The VNC server binds `127.0.0.1:5900` (and `::1`). It is **never** exposed on a
public interface; reach it through an SSH local-forward:

```sh
# on your machine
ssh -N -L 5900:127.0.0.1:5900 root@<this-host>
# then, in another terminal / your VNC client:
vncviewer 127.0.0.1:5900          # or Remmina / TigerVNC / macOS Screen Sharing
```

No VNC password is set (`-nopw`); the tunnel + localhost bind are the access
control. Add a password with `x11vnc -storepasswd` and drop `-nopw` if you want one.

## Start / stop the session

```sh
/root/solnix-cosmic-session.sh            # Xvfb + smallvil + GTK4 client + x11vnc
/root/solnix-cosmic-session.sh -c PROG    # run PROG as the Wayland client instead
/root/solnix-cosmic-session.sh --shm      # run the raw wl_shm test client

# stop
pkill -9 -f smallvil; pkill -9 -f x11vnc; pkill -9 -f adw-hello
```

The launcher backgrounds Xvfb, smallvil (nice 19), the client (nice 19) and
x11vnc, then prints the pids and the `127.0.0.1:5900` listen line.

## Is it nix-pure?

**The Wayland toolkit is nix-pure.** ldd of the GTK4 client resolves 73 of 81
libraries to `/nix/store` (gtk-4, libadwaita, pango, glib, cairo, harfbuzz,
gdk-pixbuf, graphene, fontconfig, freetype, the wayland libs, ...). smallvil links
only libxkbcommon + illumos base libs.

**The non-nix remainder is unavoidable on illumos:**

- illumos base system libraries: `libc`, `libm`, `libpthread`, `librt`,
  `libsocket`, `libnsl`, `libumem`, `libgcc_s`, `libresolv` — there is no
  nix-pure illumos libc.
- The Mesa **softpipe** `libGL.so.1` / `libEGL.so.1` that smallvil's winit-EGL
  backend dlopens are the OI-pkg Mesa (21.3.9). No nix-pure Mesa is realised on
  this host yet (the mesa derivations exist only as `.drv`). Building nix-pure
  Mesa for illumos is the remaining purity gap.

So: a **nix-pure Wayland compositor + nix-pure GTK4/libadwaita client**, on the
illumos base libc and OI Mesa softpipe for GL, SW-rendered, viewable over VNC.

## Why software rendering / why Xvfb

There is no GPU/DRM on this host and no nix-pure Mesa; softpipe/llvmpipe is the SW
GL. smallvil's winit backend needs a windowing system to open its EGL window;
Xvfb is the virtual X server it opens into, and x11vnc exports that framebuffer.
(smallvil's headless/DRM backends are not usable here — no DRM on illumos.)

## The one illumos fix that made clients work

Out of the box, GTK4 (and any Wayland client) hung at the display handshake:
requests were sent but no reply came back. smallvil dispatched its wayland display
via a calloop `Generic` FD source (level-triggered on the display poll FD). On
illumos the **nested-epoll readiness of the per-client FDs does not propagate to
the outer display poll FD**, so that source never fired for client traffic.

Fix (in `smallvil/src/state.rs`): dispatch the display from a periodic calloop
`Timer` instead of the `Generic` FD source — a **time-based** poll of
`dispatch_clients` + `flush_clients` every few ms, which does not depend on epoll
readiness. With that, the handshake completes and clients render.

## Artifacts on this host

| file | what |
|---|---|
| `/root/solnix-cosmic-session.sh` | one-command session launcher |
| `/root/solnix-gtk4-libadwaita-wayland.png` | screenshot: GTK4/libadwaita in smallvil |
| `/root/solnix-wayland-desktop.png` | screenshot: wl_shm client in smallvil |
| `/root/adw-hello` (+ `.c`) | the nix-pure GTK4/libadwaita client |
| `/root/wlclient` (+ `.c`) | the raw wl_shm test client |
| `/root/xgrab` (+ `.c`) | X11 root-window -> PPM screengrab |
| `/root/ppm2png` (+ `.c`) | PPM -> PNG (zlib) |
| `/root/nix-gtk-libpath.txt` | the nix-pure LD_LIBRARY_PATH for GTK4 clients |
| `/root/smithay/smallvil/` | the patched compositor source + build |
