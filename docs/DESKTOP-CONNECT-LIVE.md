# solnix desktop over VNC — connect from your laptop

**Node IP:** `18.117.248.120`  (fred v3, us-east-2, x86_64 illumos / SunOS 5.11)

## What renders
A **software-rendered X11 desktop**: an `Xvfb` virtual X server (no GPU),
the `twm` window manager, and native illumos X clients (two `xterm`s showing
`SunOS solnix 5.11 illumos-fb435c17bd`). Served over VNC by `x11vnc`.

- **Rendering:** host mesa 21.3.9 software rasteriser (`swrast_dri.so` /
  llvmpipe). No GPU, no DRM. `LIBGL_ALWAYS_SOFTWARE=1`, `GALLIUM_DRIVER=llvmpipe`.
  GTK4 is pinned to the cairo (CPU) renderer (`GSK_RENDERER=cairo`) so software
  GL never pegs the CPU.
- **Compositor/display:** `Xvfb :1 1280x800x24` + `twm`.
- **VNC server:** `x11vnc 0.9.17`, bound **127.0.0.1:5900 ONLY** (`-localhost`,
  never `0.0.0.0`). Reachable only through an SSH tunnel.

## Connect (from your laptop)

1. Open the SSH tunnel (forwards your local 5900 to the node's loopback 5900):

   ```
   ssh -L 5900:localhost:5900 root@18.117.248.120
   ```

   (add `-i <your-key>` if your key isn't the default.)

2. Leave that SSH session open. In a VNC viewer on your laptop, connect to:

   ```
   localhost:5900
   ```

   **VNC password:** `solnix`

You will see the solnix (illumos) desktop: teal-titlebar twm windows with
`xterm`s running on `SunOS solnix 5.11`.

## Start / restart the desktop on the node

```
/root/solnix-desktop-vnc.sh
```

One command: starts Xvfb (software), twm, the xterms, and x11vnc on
127.0.0.1:5900. Idempotent (kills its own old `:1` session first). Log:
`/root/solnix-desktop.log`.

## How it was verified (server-side)
- `netstat -an -f inet | grep 127.0.0.1.5900` → `LISTEN` (loopback only; not
  0.0.0.0 — never exposed to the internet).
- Server-side screenshot proving pixels render:
  `import -display :1 -window root /root/solnix-desktop.png`
  → a valid 1280x800 PNG showing two twm xterms on `SunOS solnix 5.11`.

## Security
VNC binds **127.0.0.1 only**. No security group was modified; SSH (port 22) is
the sole ingress. VNC is reachable exclusively via the `ssh -L` tunnel above.

## Notes / coexistence
Another agent runs a separate Xvfb on `:99` + a server on `127.0.0.1:5999`.
This desktop uses `:1` + `5900` to stay out of its way. Both `pkill` only their
own display. If your `:1` session ever disappears (a broad cleanup elsewhere),
just re-run `/root/solnix-desktop-vnc.sh`.

## nix-pure upgrade path (documented, not the delivered artifact)
The delivered desktop uses the host OpenIndiana X11 packages (fastest working
path). The nix-pure COSMIC stack at `/root/tranche-stage4.nix` builds GTK4/
libadwaita/wayland/mesa-softpipe for `x86_64-solaris` natively. cosmic-comp's
software backend is DRM-walled (render path hardwires the GBM/GL backend), so
it is **not** the SW path. The viable nix-pure Wayland path is smithay's
`smallvil` compositor (winit backend + wayland-frontend, EGL/GL dlopen'd to
llvmpipe/softpipe) with a GTK4/libadwaita client, viewed via x11vnc (winit-in-X)
or wayvnc. That is a follow-on, not required for this VNC deliverable.
