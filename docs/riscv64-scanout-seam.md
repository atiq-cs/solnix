# The riscv64 scanout seam: what the kernel must present so a SW-composited COSMIC frame reaches HDMI

Companion to `docs/riscv-jupiter-driver-plan.md` §7 (P5, framebuffer scanout) and
`docs/cosmic-riscv64-feasibility.md`. This file specifies the **contract** between
the solnix riscv64 kernel's scanout driver and the userland compositor, precisely
enough that the kernel side can be finished to match without guessing.

The existing `src/riscv-port/rp64/kernel/virtio_gpu.c` (QEMU-scanout-proven) is the
reference implementation of the *device* half. It is a valid stand-in for the K1's
DPU/HDMI path because both reduce to the same thing: **a linear framebuffer in DRAM
that a scanout engine reads and a monitor displays.**

---

## 1. What the compositor actually needs (measured, not assumed)

The illumos COSMIC substrate is **smallvil** (a smithay software compositor -- see
`docs/cosmic-comp-illumos-finding.md` for why not cosmic-comp). Trace the pixels
end to end:

```
COSMIC app (libcosmic/iced, ICED_BACKEND=tiny-skia)
   -> renders into a wl_shm buffer  (softbuffer, POSIX shm; the illumos leading-'/'
                                     patch applies unchanged on riscv64)
   -> wl_surface.attach + commit    (wayland-client)
smallvil (smithay wayland_frontend + desktop)
   -> composites the surfaces into ONE output-sized RGBX buffer in RAM
      (renderer_pixman, or GlesRenderer on llvmpipe via the riscv64 Mesa)
   -> ONE full-frame blit into the scanout framebuffer
kernel scanout driver
   -> makes those bytes visible on HDMI
```

So the compositor needs **exactly three things** from the kernel, and nothing more:

1. A **mmap-able linear framebuffer** it can `memcpy`/blit into.
2. **Mode info**: width, height, stride-in-bytes, pixel format.
3. A **present/flush** call meaning "the bytes I just wrote are complete; show them."

It does *not* need DRM/KMS, GBM, dmabuf, atomic modeset, planes, cursors, or
GPU command submission. Those are what `cosmic-comp` wants (and why it is not the
substrate). smallvil composites in software and needs only a destination surface.

`virtio_gpu.c` already exposes exactly this shape:
`virtio_gpu_fb()` (the buffer), `virtio_gpu_width()`/`virtio_gpu_height()` (mode),
`virtio_gpu_flush()` (present). The seam below is that same triple, promoted to a
device node.

---

## 2. The concrete seam: `/dev/fb` (illumos `visual_io`), three ioctls + mmap

Use the existing illumos framebuffer interface (`sys/visual_io.h`) -- the same one
`gfx_private`/`vgatext` use -- rather than inventing a new one. That way the node
is idiomatic and a future illumos-native console can share it.

### 2.1 mmap contract

```
fd = open("/dev/fb", O_RDWR);
fb = mmap(NULL, stride * height, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0);
```

- The mapping is **linear and contiguous** in userland VA: row `y` starts at byte
  offset `y * stride`. No tiling, no swizzle, no per-row padding beyond `stride`.
- The mapping is **write-combining/uncached-friendly but plain-cacheable is fine**
  provided the flush ioctl performs the cache maintenance (see 2.3). On RISC-V the
  driver must issue the appropriate `fence`/CMO before telling the scanout engine
  to read; solnix already has `src/riscv/uts/cmo.c` for exactly this.
- Offset 0 must map the byte the scanout engine treats as pixel (0,0).
- The kernel keeps the framebuffer physically contiguous (the scanout engine takes
  a single base PA; `virtio_gpu.c` already does this with one
  `RESOURCE_ATTACH_BACKING` entry).

### 2.2 mode query

```c
struct fb_mode {              /* WHAT: what the compositor must know to blit */
	uint32_t width;       /* visible pixels per row                     */
	uint32_t height;      /* visible rows                               */
	uint32_t stride;      /* BYTES per row (>= width * 4)               */
	uint32_t format;      /* FB_FMT_* below                             */
	uint32_t size;        /* bytes to mmap (== stride * height)          */
};
#define FB_FMT_XRGB8888  1   /* 32bpp; byte order B,G,R,X in memory (LE)   */
#define FB_FMT_XBGR8888  2   /* 32bpp; byte order R,G,B,X in memory (LE)   */

ioctl(fd, FBIOGMODE, &mode);   /* get the current mode; MUST succeed        */
```

`stride` is separate from `width * 4` on purpose: real display controllers require
row alignment (the K1 DPU wants its plane pitch aligned; QEMU's virtio-gpu does
not). **The compositor must honor `stride`, never recompute it.** This is the
single most common source of a diagonally-sheared desktop.

### 2.3 present

```c
struct fb_damage {            /* WHAT: the rect that changed, in pixels */
	uint32_t x, y, w, h;
};
ioctl(fd, FBIOFLUSH, &damage); /* damage == NULL or w==0 means "whole screen" */
```

`FBIOFLUSH` is where the kernel does *all* the work the hardware needs and the
compositor must not know about:

- the RISC-V cache maintenance (`fence` + CMO clean of the dirty range) so the
  scanout engine sees the written bytes;
- on virtio-gpu: `TRANSFER_TO_HOST_2D` + `RESOURCE_FLUSH` over the damage rect
  (`virtio_gpu_flush()` today does the whole screen -- accepting a damage rect is
  the one small extension worth making, since a SW compositor's typical damage is
  a fraction of the screen and this is pure win on an 8-core 1.6 GHz part);
- on the K1 DPU: nothing per-frame if the plane is already pointed at the
  framebuffer and the panel self-refreshes from RAM -- but the CMO is still
  required, and a vsync wait belongs here if tearing shows.

The call is **synchronous**: on return, the bytes are committed to the scanout
engine. That is the semantics smallvil's frame loop wants (it submits a frame,
then sends frame callbacks to clients).

### 2.4 optional: mode set

```
ioctl(fd, FBIOSMODE, &mode);   /* MAY return ENOTSUP */
```

Deliberately optional. For the first light on the Jupiter, whatever mode U-Boot
left (§7(a) of the driver plan, "inherit the U-Boot framebuffer") is fine, and
returning `ENOTSUP` is a correct implementation. Do not gate the desktop on mode
setting.

---

## 3. Pixel format: pin it to XRGB8888 and convert nowhere

The whole chain already agrees on 32-bit BGRX little-endian:

| layer | format |
|---|---|
| `virtio_gpu.c` | `VIRTIO_GPU_FORMAT_B8G8R8X8_UNORM`, `FB_BPP 4` |
| wl_shm (Wayland) | `WL_SHM_FORMAT_XRGB8888` = the same bytes |
| smithay pixman / softbuffer | XRGB8888 |
| K1 DPU | supports XRGB8888/ARGB8888 planes |

**So specify `FB_FMT_XRGB8888` as the required format and implement no
conversion path.** A per-frame format conversion on the CPU would cost more than
the compositing does. If a K1 panel comes up in a different order, fix it in the
DPU plane config, not in a userland blit.

Alpha: the framebuffer is the bottom-most surface, so the X byte is ignored.
smallvil composites client alpha itself before the blit.

---

## 4. What the userland side needs (the other half of the seam)

smithay has **no fbdev backend** (verified: `src/backend/` has drm, egl, x11,
winit, libinput, udev, vulkan -- no framebuffer/fbdev, and no `/dev/fb` reference
anywhere in the tree). So a small smallvil-side backend must be written:

- ~200-300 lines: open `/dev/fb`, `FBIOGMODE`, mmap, build a smithay
  `MemoryRenderBuffer`/pixman target over the mapping, and call `FBIOFLUSH` at the
  end of each frame instead of `winit`'s buffer swap.
- It replaces the `winit` backend smallvil uses today (which needs an X11/Wayland
  host window). Everything above it -- the wayland frontend, the layer-shell
  handling that already works for cosmic-panel, the space/window management --
  is untouched.
- This is the **only new Rust code the scanout path needs**, and it is
  cross-buildable (no board required to write it; a QEMU virtio-gpu target
  exercises it, which is exactly what `virtio_gpu.c` already provides).

There is a cheaper first light: point `FBIOFLUSH` at the existing R-P64 GPU
harness and blit a static PPM to prove the node before wiring smallvil.

---

## 5. Gap list for the kernel side (what to finish in `virtio_gpu.c` / the DPU driver)

| # | item | status today | what to add |
|---|---|---|---|
| 1 | linear contiguous fb | DONE (`static unsigned int fb[]`, 4 KiB aligned) | expose its PA + size to the fb node |
| 2 | mode discovery | DONE (`GET_DISPLAY_INFO` -> `scan_w`/`scan_h`) | report `stride` explicitly, not implied |
| 3 | `stride` | IMPLIED (`scan_w * 4`) | make it a real field; the K1 DPU will need alignment |
| 4 | present | DONE (`virtio_gpu_flush()`, whole screen) | accept a damage rect |
| 5 | `/dev/fb` node | **MISSING** | the `visual_io` cb_ops: open/close/mmap (segmap/devmap) + the 3 ioctls |
| 6 | mmap of the fb into userland | **MISSING** | `devmap`/`segmap` over the fb pages |
| 7 | RISC-V cache maintenance on flush | **MISSING** | `fence` + CMO clean of the damage range (`src/riscv/uts/cmo.c`) |
| 8 | fb size vs real mode | CAPPED at 1024x768 (`FB_MAX_W/H`) | allocate from the mode, not a compile-time cap -- a 1920x1080 desktop needs 8.3 MB |
| 9 | K1 DPU variant | NOT STARTED | same node, different back end: inherit the U-Boot plane base (§7(a)) or program the DPU (§7(b)) |

Items 5-8 are the real work and they are **generic** (not K1-specific): finishing
them against QEMU virtio-gpu means the K1 DPU driver only has to supply a
different `flush`/plane-base implementation behind the same node.

---

## 6. Why this is the right seam (and the honest limits)

**Right:** it is the smallest interface that carries a finished frame to the
display, it matches what a software compositor actually does, it works identically
on QEMU virtio-gpu and on a DPU that inherits U-Boot's plane, and it needs no DRM
stack -- which solnix does not have on riscv64 and does not need for a
software-rendered desktop.

**Limits, stated plainly:**

- **No GPU acceleration, ever, through this seam.** It carries CPU-composited
  pixels. That is the accepted scoping (the PowerVR BXE has no driver path).
- **No page flipping / double buffering** in the spec above, so a fast-moving
  window can tear. The upgrade is a second framebuffer plus a "flip" ioctl; add it
  only if tearing is visible, since on a scanout engine reading from RAM the
  tear window is small.
  <!-- NOTE: single-buffer + full flush; add a flip ioctl if tearing shows -->
- **Full-screen flush is O(width*height) per frame** even for a blinking cursor.
  The damage rect in `FBIOFLUSH` is what keeps that honest; a compositor that
  always passes NULL will burn CPU on a 1080p panel.
- **No hardware cursor**, so the pointer is composited into the frame and its
  latency equals the frame time. Acceptable for a software desktop; a K1 DPU
  cursor plane would be a later win.

---

## 7. First-light order

1. Extend `virtio_gpu.c`: real `stride`, mode-sized fb allocation, damage-rect flush.
2. Add the `/dev/fb` node (`visual_io` cb_ops + devmap + the 3 ioctls) over it.
3. Prove it with a C test that mmaps and paints a gradient, under QEMU -- no Rust,
   no compositor.
4. Write the smallvil fb backend (~250 lines) and run the *existing*, proven
   COSMIC session on it under QEMU riscv64.
5. Only then move to the board: swap the virtio-gpu back end for the K1 DPU
   (inherit U-Boot's plane first; program the DPU only if that fails).

Steps 1-4 need **no hardware** and are the highest-value scanout work available
right now.
