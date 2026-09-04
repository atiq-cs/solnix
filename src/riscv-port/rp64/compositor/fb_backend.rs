//! A smithay/smallvil backend that renders into the solnix `/dev/fb` scanout
//! node instead of DRM/KMS or a winit host window.
//!
//! This is the userland half of the riscv64 scanout seam (see
//! `docs/riscv64-scanout-seam.md` section 4). smithay has **no fbdev backend** --
//! its `src/backend/` has drm, egl, x11, winit, libinput, udev and vulkan, and no
//! `/dev/fb` reference anywhere -- so a compositor that wants to paint a
//! software-composited frame onto a plain linear framebuffer has to bring its
//! own. That is what this file is.
//!
//! WHAT IT REPLACES: smallvil's `winit` backend, which needs an X11 or Wayland
//! host window to present into. Everything above it -- the wayland frontend, the
//! layer-shell handling that already works for cosmic-panel, the space/window
//! management -- is untouched.
//!
//! THE CONTRACT it speaks is `src/riscv-port/rp64/kernel/fbio.h`, kept in sync by
//! the constants below:
//!
//! ```text
//!   fd = open("/dev/fb", O_RDWR)
//!   ioctl(fd, FBIOGMODE, &mode)   -> width, height, stride, format, size
//!   mmap(NULL, size, RW, SHARED, fd, 0)
//!   ... blit a finished frame, row y at byte offset y * stride ...
//!   ioctl(fd, FBIOFLUSH, &damage) -> present (synchronous)
//! ```
//!
//! WHY NO GPU PATH: the target part's GPU (PowerVR BXE-2-32) has no usable open
//! driver, so the desktop is CPU-composited by design. This backend carries
//! finished pixels and deliberately offers no acceleration hook -- adding one
//! would be dead code with nothing to implement it.
//!
//! ## Layering, and what is testable where
//!
//! The file is split so the interesting logic does not require the kernel:
//!
//! * [`FbMode`] / [`FbDamage`] -- the ABI structs, `#[repr(C)]`, layout-asserted.
//! * [`Framebuffer`] -- the blit/damage logic over ANY `&mut [u8]`, with no
//!   syscalls at all. This is where stride handling, clipping and damage
//!   accumulation live, and it is unit-tested on the host.
//! * [`FbDevice`] -- the thin syscall layer (open/ioctl/mmap/close). Only this
//!   part needs a solnix riscv64 kernel underneath.
//!
//! That split is deliberate: stride and clipping bugs are the ones that actually
//! bite (a mis-handled stride shears the whole desktop diagonally), and they are
//! exactly the ones that need no hardware to catch.

#![allow(clippy::needless_range_loop)]

use std::io;
use std::os::unix::io::RawFd;

// ---------------------------------------------------------------------------
// The ABI, mirroring src/riscv-port/rp64/kernel/fbio.h.
// ---------------------------------------------------------------------------

/// `FIOC` -- the illumos framebuffer ioctl family, `('F' << 8)`.
const SOLNIX_FIOC: i32 = 0x4600;

/// Get the current mode. Must succeed on an open `/dev/fb`.
pub const FBIOGMODE: i32 = SOLNIX_FIOC | 100;
/// Present. Synchronous: on return the bytes are committed to the scanout.
pub const FBIOFLUSH: i32 = SOLNIX_FIOC | 101;
/// Set the mode. Documented optional; the driver returns `ENOTSUP`.
pub const FBIOSMODE: i32 = SOLNIX_FIOC | 102;

/// 32bpp, byte order B,G,R,X in memory (little-endian). The only format the
/// seam carries: virtio-gpu `B8G8R8X8_UNORM` == `WL_SHM_FORMAT_XRGB8888` ==
/// smithay pixman XRGB == a K1 DPU XRGB8888 plane, so no conversion exists
/// anywhere in the chain.
pub const FB_FMT_XRGB8888: u32 = 1;

/// Bytes per pixel. Fixed by [`FB_FMT_XRGB8888`].
pub const FB_BPP: usize = 4;

pub const FB_DEV_PATH: &str = "/dev/fb";

/// What the compositor must know to blit a frame correctly.
///
/// `stride` is a real field, separate from `width * 4`: real display
/// controllers require row alignment (the K1 DPU wants its plane pitch aligned;
/// QEMU's virtio-gpu does not). **Never recompute it from `width`** -- that is
/// the single most common cause of a diagonally-sheared desktop.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct FbMode {
    pub width: u32,
    pub height: u32,
    /// BYTES per row, `>= width * 4`.
    pub stride: u32,
    pub format: u32,
    /// Bytes to mmap, `== stride * height`.
    pub size: u32,
    pub pad: u32,
}

/// The rect that changed, in pixels. All-zero (or any zero extent) means
/// "the whole screen".
#[repr(C)]
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct FbDamage {
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
}

// The kernel and this file MUST agree byte for byte; a mismatch would be a
// silently misparsed ioctl rather than a compile error, so assert it.
const _: () = {
    assert!(core::mem::size_of::<FbMode>() == 24);
    assert!(core::mem::size_of::<FbDamage>() == 16);
    assert!(core::mem::align_of::<FbMode>() == 4);
};

impl FbMode {
    /// Is this mode self-consistent and usable?
    ///
    /// Checked rather than trusted because a driver that reported, say, an
    /// implied stride would otherwise produce a sheared desktop with no error
    /// anywhere -- much harder to diagnose than a refused mode.
    pub fn is_valid(&self) -> bool {
        self.width > 0
            && self.height > 0
            && self.format == FB_FMT_XRGB8888
            && self.stride as usize >= self.width as usize * FB_BPP
            && self.size as u64 == self.stride as u64 * self.height as u64
    }

    /// Byte offset of pixel `(x, y)`. The seam guarantees row `y` starts at
    /// `y * stride` and that offset 0 is pixel (0,0).
    #[inline]
    pub fn offset_of(&self, x: u32, y: u32) -> usize {
        y as usize * self.stride as usize + x as usize * FB_BPP
    }

    /// A damage rect covering the whole screen.
    pub fn full_damage(&self) -> FbDamage {
        FbDamage { x: 0, y: 0, w: self.width, h: self.height }
    }
}

impl FbDamage {
    fn is_empty(&self) -> bool {
        self.w == 0 || self.h == 0
    }

    /// Smallest rect covering both. Used to coalesce per-surface damage into the
    /// one rect the flush ioctl takes.
    ///
    /// A bounding box, not a region list: a software compositor redraws
    /// rectangles anyway, and the alternative (tracking disjoint regions and
    /// issuing an ioctl per region) trades syscalls for copied pixels at a ratio
    /// that only pays off for pathological damage patterns.
    /// NOTE: bounding-box union; a region list is the upgrade if profiling shows
    /// scattered damage dominating.
    fn union(self, other: FbDamage) -> FbDamage {
        if self.is_empty() {
            return other;
        }
        if other.is_empty() {
            return self;
        }
        let x0 = self.x.min(other.x);
        let y0 = self.y.min(other.y);
        let x1 = (self.x + self.w).max(other.x + other.w);
        let y1 = (self.y + self.h).max(other.y + other.h);
        FbDamage { x: x0, y: y0, w: x1 - x0, h: y1 - y0 }
    }
}

// ---------------------------------------------------------------------------
// The pixel logic: no syscalls, fully host-testable.
// ---------------------------------------------------------------------------

/// A linear XRGB8888 framebuffer plus accumulated damage.
///
/// Borrows the mapping rather than owning it so the same code drives an mmap'd
/// device and a plain `Vec<u8>` in tests. Everything that can shear or clip the
/// desktop lives here, where it can be tested without a kernel.
pub struct Framebuffer<'a> {
    mode: FbMode,
    bytes: &'a mut [u8],
    damage: FbDamage,
}

impl<'a> Framebuffer<'a> {
    /// Wrap a mapping. Fails if the mode is inconsistent or the slice is shorter
    /// than the mode claims -- either would mean writing past the mapping.
    pub fn new(mode: FbMode, bytes: &'a mut [u8]) -> io::Result<Self> {
        if !mode.is_valid() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("inconsistent fb mode: {mode:?}"),
            ));
        }
        if bytes.len() < mode.size as usize {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("mapping {} bytes < mode.size {}", bytes.len(), mode.size),
            ));
        }
        Ok(Self { mode, bytes, damage: FbDamage::default() })
    }

    pub fn mode(&self) -> FbMode {
        self.mode
    }

    /// Damage accumulated since the last [`Self::take_damage`].
    pub fn damage(&self) -> FbDamage {
        self.damage
    }

    /// Take and clear the accumulated damage, for handing to the flush ioctl.
    pub fn take_damage(&mut self) -> FbDamage {
        core::mem::replace(&mut self.damage, FbDamage::default())
    }

    /// Mark a rect dirty, clipped to the screen.
    pub fn add_damage(&mut self, rect: FbDamage) {
        if let Some(clipped) = self.clip(rect) {
            self.damage = self.damage.union(clipped);
        }
    }

    /// Clip a rect to the visible area, or `None` if it falls entirely outside.
    ///
    /// Uses i64 arithmetic: `x + w` on u32 can wrap, and a wrapped rect would
    /// clip to something that looks valid while pointing at the wrong pixels.
    fn clip(&self, r: FbDamage) -> Option<FbDamage> {
        if r.is_empty() {
            return None;
        }
        let (sw, sh) = (self.mode.width as i64, self.mode.height as i64);
        let x0 = (r.x as i64).min(sw);
        let y0 = (r.y as i64).min(sh);
        let x1 = (r.x as i64 + r.w as i64).min(sw);
        let y1 = (r.y as i64 + r.h as i64).min(sh);
        if x1 <= x0 || y1 <= y0 {
            return None;
        }
        Some(FbDamage {
            x: x0 as u32,
            y: y0 as u32,
            w: (x1 - x0) as u32,
            h: (y1 - y0) as u32,
        })
    }

    /// Fill a rect with one XRGB8888 pixel. Records damage.
    pub fn fill_rect(&mut self, rect: FbDamage, px: u32) {
        let Some(r) = self.clip(rect) else { return };
        let le = px.to_le_bytes();
        for y in r.y..r.y + r.h {
            let start = self.mode.offset_of(r.x, y);
            let row = &mut self.bytes[start..start + r.w as usize * FB_BPP];
            for chunk in row.chunks_exact_mut(FB_BPP) {
                chunk.copy_from_slice(&le);
            }
        }
        self.damage = self.damage.union(r);
    }

    /// Clear the screen to one color, damaging everything.
    pub fn clear(&mut self, px: u32) {
        self.fill_rect(self.mode.full_damage(), px);
    }

    /// Blit a client's XRGB8888 buffer to `(dst_x, dst_y)`. Records damage.
    ///
    /// This is the operation a software compositor actually performs: the
    /// compositor composites surfaces into one output-sized buffer, then blits.
    /// `src_stride` is the SOURCE's stride, which has no reason to match the
    /// framebuffer's -- a wl_shm buffer's pitch comes from the client.
    ///
    /// Clips against both buffers, so a client window partly off-screen (or a
    /// short source buffer) is handled rather than panicking or corrupting
    /// memory.
    pub fn blit(
        &mut self,
        src: &[u8],
        src_stride: usize,
        src_w: u32,
        src_h: u32,
        dst_x: i32,
        dst_y: i32,
    ) -> io::Result<()> {
        if src_stride < src_w as usize * FB_BPP {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "src_stride < src_w * 4",
            ));
        }

        // Intersect the destination placement with the screen, in signed space
        // so a negative origin (a window scrolled off the left/top) clips
        // instead of wrapping.
        let (sw, sh) = (self.mode.width as i64, self.mode.height as i64);
        let dx0 = (dst_x as i64).max(0);
        let dy0 = (dst_y as i64).max(0);
        let dx1 = (dst_x as i64 + src_w as i64).min(sw);
        let dy1 = (dst_y as i64 + src_h as i64).min(sh);
        if dx1 <= dx0 || dy1 <= dy0 {
            return Ok(()); // entirely off-screen: nothing to do, not an error
        }

        // Where in the source those destination pixels come from.
        let sx0 = (dx0 - dst_x as i64) as usize;
        let sy0 = (dy0 - dst_y as i64) as usize;
        let w = (dx1 - dx0) as usize;
        let h = (dy1 - dy0) as usize;

        for row in 0..h {
            let s_off = (sy0 + row) * src_stride + sx0 * FB_BPP;
            let s_end = s_off + w * FB_BPP;
            if s_end > src.len() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "source buffer shorter than src_h * src_stride",
                ));
            }
            let d_off = self.mode.offset_of(dx0 as u32, dy0 as u32 + row as u32);
            self.bytes[d_off..d_off + w * FB_BPP].copy_from_slice(&src[s_off..s_end]);
        }

        self.damage = self.damage.union(FbDamage {
            x: dx0 as u32,
            y: dy0 as u32,
            w: w as u32,
            h: h as u32,
        });
        Ok(())
    }

    /// Raw access to the mapping, for a renderer that writes it directly
    /// (smithay's pixman target or a `MemoryRenderBuffer` built over it).
    /// The caller must record damage itself via [`Self::add_damage`].
    pub fn as_bytes_mut(&mut self) -> &mut [u8] {
        self.bytes
    }
}

// ---------------------------------------------------------------------------
// The syscall layer: the only part that needs a solnix kernel.
// ---------------------------------------------------------------------------

/// `/dev/fb` opened, mode queried, framebuffer mapped.
///
/// Separate from [`Framebuffer`] so the pixel logic above stays testable on any
/// host. `Drop` closes the fd; the kernel reclaims the mapping at process exit
/// (the seam deliberately lets the mapping outlive `close`, which is what a
/// compositor expects from a framebuffer it has mmap'd).
pub struct FbDevice {
    fd: RawFd,
    mode: FbMode,
    map: *mut u8,
    map_len: usize,
}

// SAFETY: the handle is an fd plus a device mapping with no thread-affine state;
// the compositor owns it exclusively and `&mut` gates all mutation.
unsafe impl Send for FbDevice {}

#[cfg(target_os = "illumos")]
mod sys {
    use super::*;

    extern "C" {
        fn open(path: *const libc::c_char, flags: libc::c_int, ...) -> libc::c_int;
        fn close(fd: libc::c_int) -> libc::c_int;
        fn ioctl(fd: libc::c_int, request: libc::c_int, ...) -> libc::c_int;
        fn mmap(
            addr: *mut libc::c_void,
            len: libc::size_t,
            prot: libc::c_int,
            flags: libc::c_int,
            fd: libc::c_int,
            off: libc::off_t,
        ) -> *mut libc::c_void;
    }

    pub const O_RDWR: libc::c_int = 2;
    pub const PROT_READ: libc::c_int = 1;
    pub const PROT_WRITE: libc::c_int = 2;
    pub const MAP_SHARED: libc::c_int = 1;
    pub const MAP_FAILED: *mut libc::c_void = usize::MAX as *mut libc::c_void;

    pub unsafe fn fb_open(path: &std::ffi::CStr) -> libc::c_int {
        open(path.as_ptr(), O_RDWR)
    }
    pub unsafe fn fb_close(fd: libc::c_int) -> libc::c_int {
        close(fd)
    }
    pub unsafe fn fb_ioctl<T>(fd: libc::c_int, req: i32, arg: *mut T) -> libc::c_int {
        ioctl(fd, req as libc::c_int, arg)
    }
    pub unsafe fn fb_mmap(fd: libc::c_int, len: usize) -> *mut libc::c_void {
        mmap(
            std::ptr::null_mut(),
            len,
            PROT_READ | PROT_WRITE,
            MAP_SHARED,
            fd,
            0,
        )
    }
}

impl FbDevice {
    /// Open [`FB_DEV_PATH`], query the mode, and map the framebuffer.
    ///
    /// Errors mean a real condition the caller should report, not retry:
    /// `ENXIO` = no scanout engine on this boot (a serial-only kernel), and an
    /// inconsistent mode = a driver bug.
    #[cfg(target_os = "illumos")]
    pub fn open() -> io::Result<Self> {
        let path = std::ffi::CString::new(FB_DEV_PATH).unwrap();
        // SAFETY: `path` is a valid NUL-terminated string that outlives the call.
        let fd = unsafe { sys::fb_open(&path) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }

        let mut mode = FbMode::default();
        // SAFETY: fd is open; `&mut mode` is a valid writable FbMode the kernel
        // copyouts exactly size_of::<FbMode>() bytes into.
        if unsafe { sys::fb_ioctl(fd, FBIOGMODE, &mut mode) } != 0 {
            let e = io::Error::last_os_error();
            unsafe { sys::fb_close(fd) };
            return Err(e);
        }
        if !mode.is_valid() {
            unsafe { sys::fb_close(fd) };
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("driver reported an inconsistent mode: {mode:?}"),
            ));
        }

        let len = mode.size as usize;
        // SAFETY: fd is an open /dev/fb; the driver maps exactly `len` bytes of
        // physically contiguous scanout memory at offset 0.
        let map = unsafe { sys::fb_mmap(fd, len) };
        if map == sys::MAP_FAILED {
            let e = io::Error::last_os_error();
            unsafe { sys::fb_close(fd) };
            return Err(e);
        }

        Ok(Self { fd, mode, map: map.cast::<u8>(), map_len: len })
    }

    /// On a non-illumos host there is no `/dev/fb` to open. Kept so the crate
    /// compiles and the pixel logic can be exercised anywhere.
    #[cfg(not(target_os = "illumos"))]
    pub fn open() -> io::Result<Self> {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "/dev/fb is a solnix illumos node; build for target_os=illumos",
        ))
    }

    pub fn mode(&self) -> FbMode {
        self.mode
    }

    /// Borrow the mapping as a [`Framebuffer`] for one frame's drawing.
    pub fn framebuffer(&mut self) -> Framebuffer<'_> {
        // SAFETY: `map` is a live MAP_SHARED mapping of exactly `map_len` bytes,
        // owned by self and unmapped only in Drop; `&mut self` makes the borrow
        // exclusive.
        let bytes = unsafe { std::slice::from_raw_parts_mut(self.map, self.map_len) };
        Framebuffer { mode: self.mode, bytes, damage: FbDamage::default() }
    }

    /// Present a damage rect. Synchronous: on return the bytes are committed to
    /// the scanout engine, which is the semantics a frame loop wants (submit a
    /// frame, then send frame callbacks to clients).
    ///
    /// A zero-extent rect is a no-op rather than a whole-screen flush: the
    /// kernel treats zero extents as "everything", so passing an empty
    /// accumulated damage straight through would silently turn "nothing changed"
    /// into a full-screen transfer every frame.
    #[cfg(target_os = "illumos")]
    pub fn flush(&mut self, damage: FbDamage) -> io::Result<()> {
        if damage.is_empty() {
            return Ok(());
        }
        let mut d = damage;
        // SAFETY: fd is open; `&mut d` is a valid FbDamage the kernel copyins.
        if unsafe { sys::fb_ioctl(self.fd, FBIOFLUSH, &mut d) } != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }

    #[cfg(not(target_os = "illumos"))]
    pub fn flush(&mut self, _damage: FbDamage) -> io::Result<()> {
        Err(io::Error::new(io::ErrorKind::Unsupported, "no /dev/fb on this host"))
    }

    /// Present the whole screen.
    pub fn flush_all(&mut self) -> io::Result<()> {
        self.flush(self.mode.full_damage())
    }
}

impl Drop for FbDevice {
    fn drop(&mut self) {
        #[cfg(target_os = "illumos")]
        // SAFETY: fd was opened by Self::open and is closed exactly once here.
        unsafe {
            sys::fb_close(self.fd);
        }
    }
}

// ---------------------------------------------------------------------------
// Tests: the pixel logic, on the host, with no kernel.
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    /// A mode with stride != width * 4, which is the case that shears a desktop
    /// when the stride is recomputed instead of honored. Padding every row by 16
    /// bytes makes any width-derived addressing visibly wrong.
    fn padded_mode(w: u32, h: u32) -> (FbMode, Vec<u8>) {
        let stride = w * FB_BPP as u32 + 16;
        let mode = FbMode {
            width: w,
            height: h,
            stride,
            format: FB_FMT_XRGB8888,
            size: stride * h,
            pad: 0,
        };
        (mode, vec![0u8; mode.size as usize])
    }

    fn pixel(fb: &Framebuffer<'_>, x: u32, y: u32) -> u32 {
        let o = fb.mode.offset_of(x, y);
        u32::from_le_bytes(fb.bytes[o..o + 4].try_into().unwrap())
    }

    #[test]
    fn mode_validation_rejects_inconsistent_modes() {
        let (good, _) = padded_mode(64, 32);
        assert!(good.is_valid());

        // stride < width * 4 would overlap rows.
        let mut m = good;
        m.stride = m.width * 4 - 4;
        assert!(!m.is_valid());

        // size disagreeing with stride * height means mmap length is wrong.
        let mut m = good;
        m.size += 4;
        assert!(!m.is_valid());

        // A format we do not carry must be refused, not silently misread.
        let mut m = good;
        m.format = FB_FMT_XRGB8888 + 1;
        assert!(!m.is_valid());

        let mut m = good;
        m.width = 0;
        assert!(!m.is_valid());
    }

    #[test]
    fn framebuffer_rejects_short_mapping() {
        let (mode, mut bytes) = padded_mode(64, 32);
        bytes.truncate(mode.size as usize - 1);
        assert!(Framebuffer::new(mode, &mut bytes).is_err());
    }

    #[test]
    fn rows_are_addressed_by_stride_not_width() {
        let (mode, mut bytes) = padded_mode(8, 4);
        let mut fb = Framebuffer::new(mode, &mut bytes).unwrap();

        // One pixel per row at x=0; with stride honored these land exactly
        // stride bytes apart, and the padding stays untouched.
        for y in 0..4 {
            fb.fill_rect(FbDamage { x: 0, y, w: 1, h: 1 }, 0x00ff0000 | y);
        }
        for y in 0..4 {
            assert_eq!(pixel(&fb, 0, y), 0x00ff0000 | y, "row {y}");
            let o = y as usize * mode.stride as usize;
            assert_eq!(&fb.bytes[o..o + 4], &(0x00ff0000u32 | y).to_le_bytes());
        }
        // The 16 padding bytes at the end of row 0 must be untouched: writing
        // into them is exactly what a width*4 stride assumption would do.
        let pad_start = mode.width as usize * FB_BPP;
        assert!(fb.bytes[pad_start..mode.stride as usize].iter().all(|&b| b == 0));
    }

    #[test]
    fn fill_rect_clips_to_screen() {
        let (mode, mut bytes) = padded_mode(16, 8);
        let mut fb = Framebuffer::new(mode, &mut bytes).unwrap();

        // Oversized rect: must clip, not panic or write past the mapping.
        fb.fill_rect(FbDamage { x: 12, y: 6, w: 999, h: 999 }, 0x00ffffff);
        assert_eq!(fb.damage(), FbDamage { x: 12, y: 6, w: 4, h: 2 });
        assert_eq!(pixel(&fb, 15, 7), 0x00ffffff);

        // Entirely off-screen: no damage, no write.
        let before = fb.take_damage();
        assert!(!before.is_empty());
        fb.fill_rect(FbDamage { x: 100, y: 100, w: 4, h: 4 }, 0x00ff0000);
        assert!(fb.damage().is_empty());
    }

    #[test]
    fn clip_does_not_wrap_on_huge_rects() {
        let (mode, mut bytes) = padded_mode(16, 8);
        let mut fb = Framebuffer::new(mode, &mut bytes).unwrap();
        // x + w overflows u32; i64 clipping must still produce a sane rect.
        fb.fill_rect(FbDamage { x: 4, y: 2, w: u32::MAX, h: u32::MAX }, 0x00abcdef);
        assert_eq!(fb.damage(), FbDamage { x: 4, y: 2, w: 12, h: 6 });
    }

    #[test]
    fn damage_union_is_a_bounding_box_and_ignores_empties() {
        let a = FbDamage { x: 10, y: 10, w: 5, h: 5 };
        let b = FbDamage { x: 100, y: 0, w: 10, h: 3 };
        assert_eq!(a.union(b), FbDamage { x: 10, y: 0, w: 100, h: 15 });
        // An empty rect must not drag the box to the origin.
        assert_eq!(a.union(FbDamage::default()), a);
        assert_eq!(FbDamage::default().union(a), a);
    }

    #[test]
    fn blit_places_a_client_buffer_and_damages_exactly_it() {
        let (mode, mut bytes) = padded_mode(32, 16);
        let mut fb = Framebuffer::new(mode, &mut bytes).unwrap();

        // A 4x4 client buffer whose own stride is padded differently.
        let (sw, sh, src_stride) = (4u32, 4u32, 4 * FB_BPP + 8);
        let mut src = vec![0u8; src_stride * sh as usize];
        for y in 0..sh as usize {
            for x in 0..sw as usize {
                let v = 0x00010000u32 * (y as u32 + 1) + x as u32;
                let o = y * src_stride + x * FB_BPP;
                src[o..o + 4].copy_from_slice(&v.to_le_bytes());
            }
        }

        fb.blit(&src, src_stride, sw, sh, 5, 3).unwrap();
        assert_eq!(fb.damage(), FbDamage { x: 5, y: 3, w: 4, h: 4 });
        for y in 0..sh {
            for x in 0..sw {
                let want = 0x00010000u32 * (y + 1) + x;
                assert_eq!(pixel(&fb, 5 + x, 3 + y), want, "({x},{y})");
            }
        }
        // Outside the blit is untouched.
        assert_eq!(pixel(&fb, 4, 3), 0);
        assert_eq!(pixel(&fb, 9, 3), 0);
    }

    #[test]
    fn blit_clips_negative_and_offscreen_placements() {
        let (mode, mut bytes) = padded_mode(16, 8);
        let mut fb = Framebuffer::new(mode, &mut bytes).unwrap();

        let (sw, sh) = (8u32, 8u32);
        let src_stride = sw as usize * FB_BPP;
        let src = vec![0xAAu8; src_stride * sh as usize];

        // Half off the left/top edge: the visible part lands at the origin.
        fb.blit(&src, src_stride, sw, sh, -4, -4).unwrap();
        assert_eq!(fb.damage(), FbDamage { x: 0, y: 0, w: 4, h: 4 });
        assert_eq!(pixel(&fb, 0, 0), 0xAAAAAAAA);
        assert_eq!(pixel(&fb, 4, 0), 0);

        // Fully off-screen is a no-op, not an error: a scrolled-away window is
        // normal, not a failure.
        let _ = fb.take_damage();
        fb.blit(&src, src_stride, sw, sh, 999, 999).unwrap();
        assert!(fb.damage().is_empty());
        fb.blit(&src, src_stride, sw, sh, -99, 0).unwrap();
        assert!(fb.damage().is_empty());
    }

    #[test]
    fn blit_rejects_a_short_source_or_bad_stride() {
        let (mode, mut bytes) = padded_mode(16, 8);
        let mut fb = Framebuffer::new(mode, &mut bytes).unwrap();

        let src = vec![0u8; 4 * 4 * FB_BPP];
        // stride smaller than a row: would read rows overlapping.
        assert!(fb.blit(&src, 4, 4, 4, 0, 0).is_err());
        // buffer shorter than src_h rows: must error, not read out of bounds.
        assert!(fb.blit(&src, 4 * FB_BPP, 4, 99, 0, 0).is_err());
    }

    #[test]
    fn clear_damages_the_whole_screen() {
        let (mode, mut bytes) = padded_mode(16, 8);
        let mut fb = Framebuffer::new(mode, &mut bytes).unwrap();
        fb.clear(0x00123456);
        assert_eq!(fb.damage(), FbDamage { x: 0, y: 0, w: 16, h: 8 });
        assert_eq!(pixel(&fb, 15, 7), 0x00123456);
        assert_eq!(pixel(&fb, 0, 0), 0x00123456);
    }

    #[test]
    fn take_damage_clears_so_an_idle_frame_flushes_nothing() {
        let (mode, mut bytes) = padded_mode(16, 8);
        let mut fb = Framebuffer::new(mode, &mut bytes).unwrap();
        fb.fill_rect(FbDamage { x: 1, y: 1, w: 2, h: 2 }, 1);
        assert!(!fb.take_damage().is_empty());
        // Nothing drawn since: the next frame must present nothing, which is
        // what keeps an idle desktop from burning a full-screen transfer.
        assert!(fb.take_damage().is_empty());
    }

    /// The pattern fbtest.c paints, reproduced through this backend. Renders the
    /// same RGBW quadrants + diagonal and checks the same points the screendump
    /// verifier checks, so the Rust and C sides are known to agree.
    #[test]
    fn paints_the_reference_pattern_identically_to_fbtest_c() {
        let (w, h) = (64u32, 40u32);
        let (mode, mut bytes) = padded_mode(w, h);
        let mut fb = Framebuffer::new(mode, &mut bytes).unwrap();

        const RED: u32 = 0x00ff0000;
        const GREEN: u32 = 0x0000ff00;
        const BLUE: u32 = 0x000000ff;
        const WHITE: u32 = 0x00ffffff;

        for y in 0..h {
            for x in 0..w {
                let px = if x * h == y * w {
                    WHITE
                } else if y < h / 2 {
                    if x < w / 2 { RED } else { GREEN }
                } else if x < w / 2 {
                    BLUE
                } else {
                    WHITE
                };
                fb.fill_rect(FbDamage { x, y, w: 1, h: 1 }, px);
            }
        }

        assert_eq!(pixel(&fb, w / 4, h / 3), RED);
        assert_eq!(pixel(&fb, 3 * w / 4, h / 4), GREEN);
        assert_eq!(pixel(&fb, w / 4, 3 * h / 4), BLUE);
        assert_eq!(pixel(&fb, 3 * w / 4, 2 * h / 3), WHITE);

        // The diagonal, which is what a stride bug shears. `x * h == y * w` is
        // satisfied only at exact rational points, and `y * w / h` does NOT
        // round-trip through integer division, so derive the sample points from
        // the painter's own predicate rather than recomputing a position and
        // hoping it lands on the line. (Recomputing is what made the first draft
        // of this test -- and of verify-scanout.py -- sample a quadrant pixel
        // and call it a diagonal failure.)
        let mut diag = 0;
        for y in 0..h {
            for x in 0..w {
                if x * h == y * w {
                    assert_eq!(pixel(&fb, x, y), WHITE, "diagonal at ({x},{y})");
                    diag += 1;
                }
            }
        }
        assert!(diag >= 8, "expected a real diagonal, found {diag} points");
        assert_eq!(fb.damage(), FbDamage { x: 0, y: 0, w, h });
    }
}
