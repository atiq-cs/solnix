# solnix — COSMIC / Wayland session on illumos, viewable over VNC

A live, connectable **software-rendered Wayland session** on x86_64-illumos: the
smithay **`smallvil`** compositor rendering with Mesa **softpipe** (SW GLES2), a
Wayland client composited to pixels, exported over VNC on **`127.0.0.1:5900`**.
All the COSMIC/Wayland toolkit binaries are `/nix/store` builds.

## What renders / what connects

- **`smallvil`** — the smithay SW Wayland compositor. Its winit-x11 backend opens
  a window inside **Xorg :99 (dummy driver)**; EGL `PLATFORM_X11_KHR` initialises
  on Mesa **softpipe** → **OpenGL ES 3.1 Mesa 21.3.9, GL Renderer "softpipe"** (no
  GPU, no DRM). It creates `wayland-1`, advertises the compositor globals, and
  composites client surfaces onto a dark-grey clear.
- **A raw `wl_shm` client** (`/root/wlclient`) anchors an 800×500 surface — four
  colour bands + a white box — which `smallvil` composites. This is the pixel
  proof: the VNC framebuffer shows smallvil's grey `(26,26,26)` clear plus the
  client's `(204,51,51)/(51,204,51)/(51,102,204)/(119,68,170)` bars and a white
  box. Screenshot: `artifacts/solnix-cosmic-wayland-smallvil.png`.
- **The real COSMIC apps connect.** `cosmic-term` (the flagship) and `cosmic-files`
  connect to `wayland-1`, receive smallvil's globals (`wl_compositor` v5,
  `xdg_wm_base` v7, `wl_shm`, `wl_seat` v9, `wl_output` v4,
  `zxdg_output_manager_v1`, `wl_data_device_manager`), bind them, and run the iced
  event loop — a real COSMIC Wayland client on the smallvil compositor. They stop
  at `softbuffer`'s buffer allocation on illumos (see "Known gap").

## Connect (SSH tunnel — VNC is bound to localhost only)

The VNC entry point binds `127.0.0.1:5900` only (a `lo-relay` in front of
`x0vncserver`); it is never on a public interface. Reach it through an SSH
local-forward:

```sh
# on your machine
ssh -N -L 5900:127.0.0.1:5900 root@3.145.77.215
# then, in another terminal / your VNC client:
vncviewer 127.0.0.1:5900          # or Remmina / TigerVNC / macOS Screen Sharing
```

No VNC password (`-SecurityTypes None`); the SSH tunnel + the localhost bind + the
security group (only `:22`, from a fixed /24) are the access control. The security
group is untouched.

## Start / stop

```sh
/root/solnix-cosmic-session.sh                 # Xorg + smallvil + wl_shm client + VNC
/root/solnix-cosmic-session.sh -c PROG         # run PROG as the Wayland client
/root/solnix-cosmic-session.sh --cosmic-term   # cosmic-term (connects; SW-shm gated)

# stop
pkill -9 -f smallvil; pkill -9 x0vncserver; pkill -9 lo-relay; pkill -9 Xorg
```

## The display substrate (why Xorg-dummy, not Xvfb/Xvnc)

smallvil's winit-EGL backend needs an X server that exposes **DRI2** so Mesa's
software `swrast` EGL-X11 path can create a screen. On this host:

- **TigerVNC `Xvnc`** and **Xvfb** do **not** advertise DRI2/DRI3 → Mesa's
  EGL-X11 loader gets `DRI2: failed to create dri screen` → `eglInitialize
  NOT_INITIALIZED`. smallvil dies.
- **Xorg 1.19 with the `dummy` video driver** *does* advertise DRI2 and, via the
  mediated-GL `libglx` + `DRISWRAST`, gives Mesa a working software screen. With
  `GALLIUM_DRIVER=softpipe` (llvmpipe fails the swrast screen on Mesa 21.3.9),
  smallvil's EGL initialises and softpipe renders.

One fresh-AMI fix the launcher applies: `svcadm restart
application/opengl/ogl-select` repopulates `/var/run/opengl/server/amd64/libglx.so`
(the mediated-GL server link), which Xorg needs to load GLX/DRISWRAST.

VNC export: TigerVNC 1.8's `x0vncserver` can only listen on all interfaces, so it
runs on `:5901` and a 40-line `lo-relay` (bind `127.0.0.1:5900` → `127.0.0.1:5901`)
makes the only tunnelable listener localhost-bound.

## Known gap — CLOSED: cosmic-term now PAINTS in smallvil

The COSMIC apps previously panicked at
`softbuffer/wayland/buffer.rs:52 — Failed to create POSIX shm to store buffer:
Os { code: 22, kind: InvalidInput }`. Root cause: softbuffer's non-linux branch
(`create_memfile`) builds its POSIX-shm object name as `"softbuffer-XXXXXXX"`
with **no leading slash**; illumos `shm_open(3C)` requires the name to begin with
`/` and rejects any other name with `EINVAL`. Fix (`rust-patches/`
`softbuffer-illumos-posix-shm.patch`): prepend `/` to the name and drop the exec
bit (`Mode::RWXU` → `Mode::RUSR|Mode::WUSR`, the proven illumos idiom). Relinked
`cosmic-term` — the `wl_shm` pool now allocates, no panic.

A second fix was needed to reach pixels: iced's `fallback::Renderer<iced_wgpu,
iced_tiny_skia>` tries wgpu first, and wgpu 28 **panics** in `Instance::new` on
illumos (no wgpu backend) instead of returning `Err`, so the tiny-skia fallback
never fires. Running with `ICED_BACKEND=tiny-skia` makes `iced_wgpu` return a
clean `Err` (it never calls `Instance::new`) and iced uses the tiny-skia SW path
that blits through the patched softbuffer. `cosmic-term` then creates its window,
gets configured by smallvil, and **paints** — screenshot:
`artifacts/solnix-cosmic-term-painting.png` (the COSMIC Terminal: File/Edit/View
menu, "New terminal" title, "+" tab button, cursor, rounded COSMIC dark window).

Honest remaining item (NOT softbuffer): illumos wayland-client dispatch is very
slow (~8 s per roundtrip — the client-side of the epoll-nesting latency the
smallvil timer-dispatch patch fixes server-side). cosmic-term paints, then its
iced redraw loop spins re-initialising under the slow dispatch and leaks memory
if left running. The paint happens; steady-state needs a client-side dispatch
fix in iced/winit-on-illumos.

## Artifacts on the host (`root@3.145.77.215`)

| file | what |
|---|---|
| `/root/solnix-cosmic-session.sh` | one-command session launcher |
| `/root/solnix-cosmic-wayland.png` | screenshot: wl_shm client composited by smallvil |
| `/root/solnix-cosmic-term-painting.png` | screenshot: **cosmic-term PAINTING** in smallvil (also `artifacts/`) |
| `/root/xorg-dummy.conf` | headless Xorg dummy-driver config (DRI2 software) |
| `/root/wlclient` (+ `.c`) | raw `wl_shm` client (illumos-safe tmpfile shm) |
| `/root/adw-hello` (+ `.c`) | GTK4/libadwaita client (built; GDK wayland backend gated) |
| `/root/lo-relay` (+ `.c`) | `127.0.0.1:5900` → `:5901` localhost VNC relay |
| `/root/nix-gtk-libpath.txt` | the nix `LD_LIBRARY_PATH` for GTK4 clients |
| `/root/cosmic-gcroots/waveB2-bin/` | the 16 COSMIC apps + smallvil (all `/nix/store`) |
