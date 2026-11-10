// illumos_input.rs -- cosmic-comp's KMS input on illumos: /dev/kbd + /dev/mouse as VUID
// Firm_events (vuid_event.h), not libinput/evdev/udev, which illumos does not have.
// Keyboard: KIOCTRANS(TR_UNTRANS_EVENT) gives one Firm_event per key, id = keyboard station.
// Mouse: VUIDSFORMAT(VUID_FIRM_EVENT) gives LOC_X/Y_DELTA, MS_LEFT..MS_RIGHT, VUID wheel.
// See solnix /scratch/solnix/cosmic2/input-route.md for why this route.
use std::{fs::File, io::Read, path::PathBuf};

use smithay::backend::input::{
    self as bi, Axis, AxisRelativeDirection, AxisSource, ButtonState, DeviceCapability, InputBackend,
    InputEvent, KeyState, Keycode, UnusedEvent,
};
use smithay::reexports::calloop::{generic::Generic, EventSource, Interest, Mode, Poll, PostAction, Readiness, Token, TokenFactory};

// Values MEASURED from the gate headers by a C program (cosmic2/evidence-vuid-const.txt):
// KIOCTRANS = KIOC|30 and VUIDSFORMAT = VUIOC|11 on x86 (the "avoid conflict with VT" arms).
const KIOCTRANS: i32 = 27422;
const KIOCGTRANS: i32 = 27427; // KIOC|35
// conskbd routes key events to the /dev/kbd queue ONLY while directio is set (conskbd.c
// conskbd_override_kbtrans); otherwise they go to the console. kbio.h: KIOCSDIRECT = KIOC|10.
const KIOCSDIRECT: i32 = 27402;
const TR_ASCII: i32 = 1;
const TR_UNTRANS_EVENT: i32 = 3;
const VUIDSFORMAT: i32 = 30219;
const VUIDGFORMAT: i32 = 30220; // VUIOC|12
const VUID_FIRM_EVENT: i32 = 1;
const LOC_X_DELTA: u16 = 32640;
const LOC_Y_DELTA: u16 = 32641;
const MS_LEFT: u16 = 32544; // MS_MIDDLE 32545, MS_RIGHT 32546
const VUID_WHEEL_FIRST: u16 = 30720; // vuid_first(VUID_WHEEL = 0x78)
const VKEY_DOWN: i32 = 1; // VKEY_UP = 0
const FE_SIZE: usize = 16;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum VuidDevice { Keyboard, Mouse }

impl bi::Device for VuidDevice {
    fn id(&self) -> String { format!("{:?}", self) }
    fn name(&self) -> String { match self { Self::Keyboard => "illumos /dev/kbd".into(), Self::Mouse => "illumos /dev/mouse".into() } }
    fn has_capability(&self, c: DeviceCapability) -> bool {
        matches!((self, c), (Self::Keyboard, DeviceCapability::Keyboard) | (Self::Mouse, DeviceCapability::Pointer))
    }
    fn usb_id(&self) -> Option<(u32, u32)> { None }
    fn syspath(&self) -> Option<PathBuf> { None }
}

#[derive(Debug, Clone, Copy)]
pub struct Firm { pub id: u16, pub value: i32, pub usec: u64 }

impl Firm {
    pub fn parse(b: &[u8; FE_SIZE]) -> Firm {
        let id = u16::from_ne_bytes([b[0], b[1]]);
        let value = i32::from_ne_bytes([b[4], b[5], b[6], b[7]]);
        let sec = i32::from_ne_bytes([b[8], b[9], b[10], b[11]]) as u64;
        let usec = i32::from_ne_bytes([b[12], b[13], b[14], b[15]]) as u64;
        Firm { id, value, usec: sec * 1_000_000 + usec }
    }
}

// One event struct carries every kind; the trait impls read the fields that apply.
#[derive(Debug, Clone, Copy)]
pub struct VuidEvent { dev: VuidDevice, usec: u64, code: u32, pressed: bool, dx: f64, dy: f64 }

impl bi::Event<VuidInput> for VuidEvent {
    fn time(&self) -> bi::InputTime { bi::InputTime::from_micros(self.usec) } // smithay 8a27023: InputTime, was u64 usec
    fn device(&self) -> VuidDevice { self.dev }
}
impl bi::KeyboardKeyEvent<VuidInput> for VuidEvent {
    fn key_code(&self) -> Keycode { Keycode::new(self.code) } // evdev + 8 (xkb)
    fn state(&self) -> KeyState { if self.pressed { KeyState::Pressed } else { KeyState::Released } }
    fn count(&self) -> u32 { self.pressed as u32 }
}
impl bi::PointerMotionEvent<VuidInput> for VuidEvent {
    fn delta_x(&self) -> f64 { self.dx }
    fn delta_y(&self) -> f64 { self.dy }
    fn delta_x_unaccel(&self) -> f64 { self.dx }
    fn delta_y_unaccel(&self) -> f64 { self.dy }
}
impl bi::PointerButtonEvent<VuidInput> for VuidEvent {
    fn button_code(&self) -> u32 { self.code }
    fn state(&self) -> ButtonState { if self.pressed { ButtonState::Pressed } else { ButtonState::Released } }
}
impl bi::PointerAxisEvent<VuidInput> for VuidEvent {
    fn amount(&self, a: Axis) -> Option<f64> { (a == Axis::Vertical).then_some(self.dy * 15.0) }
    fn amount_v120(&self, a: Axis) -> Option<f64> { (a == Axis::Vertical).then_some(self.dy * 120.0) }
    fn source(&self) -> AxisSource { AxisSource::Wheel }
    fn relative_direction(&self, _: Axis) -> AxisRelativeDirection { AxisRelativeDirection::Identical }
}

#[derive(Debug)]
pub struct VuidInput;
impl InputBackend for VuidInput {
    type Device = VuidDevice;
    type KeyboardKeyEvent = VuidEvent;
    type PointerAxisEvent = VuidEvent;
    type PointerButtonEvent = VuidEvent;
    type PointerMotionEvent = VuidEvent;
    type PointerMotionAbsoluteEvent = UnusedEvent;
    type GestureSwipeBeginEvent = UnusedEvent;
    type GestureSwipeUpdateEvent = UnusedEvent;
    type GestureSwipeEndEvent = UnusedEvent;
    type GesturePinchBeginEvent = UnusedEvent;
    type GesturePinchUpdateEvent = UnusedEvent;
    type GesturePinchEndEvent = UnusedEvent;
    type GestureHoldBeginEvent = UnusedEvent;
    type GestureHoldEndEvent = UnusedEvent;
    type TouchDownEvent = UnusedEvent;
    type TouchUpEvent = UnusedEvent;
    type TouchMotionEvent = UnusedEvent;
    type TouchCancelEvent = UnusedEvent;
    type TouchFrameEvent = UnusedEvent;
    type TabletToolAxisEvent = UnusedEvent;
    type TabletToolProximityEvent = UnusedEvent;
    type TabletToolTipEvent = UnusedEvent;
    type TabletToolButtonEvent = UnusedEvent;
    type SwitchToggleEvent = UnusedEvent;
    type SpecialEvent = UnusedEvent;
}

#[path = "hid2evdev.rs"]
mod hid2evdev; // sibling file src/backend/kms/hid2evdev.rs

/// Firm_event -> smithay event. Pure, so it is unit-testable without a device.
pub fn translate(dev: VuidDevice, f: Firm) -> Option<InputEvent<VuidInput>> {
    let ev = |code, pressed, dx, dy| VuidEvent { dev, usec: f.usec, code, pressed, dx, dy };
    match dev {
        // TR_UNTRANS_EVENT: id = USB HID usage (conskbd sets KB_USB on every lower keyboard,
        // kb8042 maps PS/2 through keytab_pc2usb). xkb keycode = evdev + 8.
        VuidDevice::Keyboard => {
            let k = *hid2evdev::HID2EVDEV.get(f.id as usize)? as u32;
            (k != 0).then(|| InputEvent::Keyboard { event: ev(k + 8, f.value == VKEY_DOWN, 0.0, 0.0) })
        }
        VuidDevice::Mouse => match f.id {
            LOC_X_DELTA => Some(InputEvent::PointerMotion { event: ev(0, false, f.value as f64, 0.0) }),
            // VUID y grows upward (vuid_event.h); Wayland y grows downward.
            LOC_Y_DELTA => Some(InputEvent::PointerMotion { event: ev(0, false, 0.0, -(f.value as f64)) }),
            id if (MS_LEFT..MS_LEFT + 3).contains(&id) => {
                const BTN: [u32; 3] = [0x110, 0x112, 0x111]; // BTN_LEFT, BTN_MIDDLE, BTN_RIGHT
                Some(InputEvent::PointerButton { event: ev(BTN[(id - MS_LEFT) as usize], f.value != 0, 0.0, 0.0) })
            }
            // wheel 0 = vertical; VUID +1 = away from the user = scroll up = negative axis.
            VUID_WHEEL_FIRST => Some(InputEvent::PointerAxis { event: ev(0, false, 0.0, -(f.value as f64)) }),
            _ => None,
        },
    }
}

use smithay::reexports::rustix::{fs::OFlags, ioctl::{ioctl, Getter, Opcode, Setter}};
use smithay::backend::session::{libseat::LibSeatSession, Session};
use std::os::fd::{AsRawFd, BorrowedFd};
use std::sync::atomic::{AtomicI32, Ordering::SeqCst};

// /dev/kbd and /dev/mouse are conskbd/consms: ONE translation mode / format shared with the
// console (kbtrans upper), and conskbdclose() does not reset it (conskbd.c:598). A compositor
// that exits without restoring leaves the console reading raw Firm_events (garbage). So the
// mode found at open is put back, on the compositor's own fd (a second open of /dev/kbd would
// take the stream over), by Drop, by the panic hook and by the SIGTERM/SIGINT/SIGHUP handler.
static KBD_FD: AtomicI32 = AtomicI32::new(-1);
static KBD_MODE: AtomicI32 = AtomicI32::new(TR_ASCII);
static MOUSE_FD: AtomicI32 = AtomicI32::new(-1);
static MOUSE_FMT: AtomicI32 = AtomicI32::new(VUID_FIRM_EVENT);

/// Put the console modes back (async-signal-safe: two ioctl(2)s on saved fds). Idempotent.
pub fn restore_console_input() {
    let k = KBD_FD.swap(-1, SeqCst);
    if k >= 0 {
        let fd = unsafe { BorrowedFd::borrow_raw(k) };
        let _ = unsafe { ioctl(fd, Setter::<{ KIOCTRANS as Opcode }, i32>::new(KBD_MODE.load(SeqCst))) };
        // directio off = keys back to the console (its only correct value; close resets it too)
        let _ = unsafe { ioctl(fd, Setter::<{ KIOCSDIRECT as Opcode }, i32>::new(0)) };
    }
    let m = MOUSE_FD.swap(-1, SeqCst);
    if m >= 0 {
        let fd = unsafe { BorrowedFd::borrow_raw(m) };
        let _ = unsafe { ioctl(fd, Setter::<{ VUIDSFORMAT as Opcode }, i32>::new(MOUSE_FMT.load(SeqCst))) };
    }
}

// libc's signal(3C)/raise(3C), declared here: cosmic-comp has no libc crate dependency and a
// new one would change Cargo.lock (the vendor FOD). Values from illumos <sys/iso/signal_iso.h>.
unsafe extern "C" {
    fn signal(sig: i32, handler: usize) -> usize;
    fn raise(sig: i32) -> i32;
    fn atexit(f: extern "C" fn()) -> i32;
}

// std::process::exit (main's error path, the kiosk exit code) runs no Drop; atexit(3C) does run.
extern "C" fn restore_at_exit() {
    restore_console_input();
}
const SIG_DFL: usize = 0;
const SIGHUP: i32 = 1;
const SIGINT: i32 = 2;
const SIGQUIT: i32 = 3;
const SIGTERM: i32 = 15;

extern "C" fn restore_on_signal(sig: i32) {
    restore_console_input();
    unsafe {
        signal(sig, SIG_DFL);
        raise(sig);
    }
}

fn install_restore_hooks() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        let prev = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            restore_console_input();
            prev(info);
        }));
        for sig in [SIGTERM, SIGINT, SIGHUP, SIGQUIT] {
            unsafe { signal(sig, restore_on_signal as usize) };
        }
        unsafe { atexit(restore_at_exit) };
    });
}

pub fn open_kbd(s: &mut Option<LibSeatSession>) -> std::io::Result<File> {
    let f = open_seat(s, "/dev/kbd")?; // KIOCTRANS/KIOCGTRANS take an int* (kbio.h)
    let mode = unsafe { ioctl(&f, Getter::<{ KIOCGTRANS as Opcode }, i32>::new()) }.unwrap_or(TR_ASCII);
    // a compositor that died before this one may have left raw mode set: restore the console's
    let mode = if mode == TR_UNTRANS_EVENT { TR_ASCII } else { mode };
    KBD_MODE.store(mode, SeqCst);
    KBD_FD.store(f.as_raw_fd(), SeqCst);
    install_restore_hooks();
    let set = || -> smithay::reexports::rustix::io::Result<()> { unsafe {
        ioctl(&f, Setter::<{ KIOCTRANS as Opcode }, i32>::new(TR_UNTRANS_EVENT))?;
        ioctl(&f, Setter::<{ KIOCSDIRECT as Opcode }, i32>::new(1))
    } };
    // on failure put the console back and forget the fd before it closes (no restore on a reused fd)
    if let Err(e) = set() { restore_console_input(); return Err(e.into()); }
    Ok(f)
}
pub fn open_mouse(s: &mut Option<LibSeatSession>) -> std::io::Result<File> {
    let f = open_seat(s, "/dev/mouse")?; // VUIDSFORMAT/VUIDGFORMAT take an int* (vuid_event.h)
    let fmt = unsafe { ioctl(&f, Getter::<{ VUIDGFORMAT as Opcode }, i32>::new()) }.unwrap_or(VUID_FIRM_EVENT);
    MOUSE_FMT.store(fmt, SeqCst);
    MOUSE_FD.store(f.as_raw_fd(), SeqCst);
    install_restore_hooks();
    unsafe { ioctl(&f, Setter::<{ VUIDSFORMAT as Opcode }, i32>::new(VUID_FIRM_EVENT))? };
    Ok(f)
}
// /dev/kbd and /dev/mouse are root-only (or the console user's, logindevperm), so a greeter or
// a greetd user session gets them from seatd, which opens them as root (seatd illumos-vuid
// patch), as it does /dev/dri/card0. A direct open stays as the fallback (root, no seatd).
fn open_seat(s: &mut Option<LibSeatSession>, path: &str) -> std::io::Result<File> {
    if let Some(s) = s {
        match s.open(std::path::Path::new(path), OFlags::RDWR | OFlags::NONBLOCK) {
            Ok(fd) => return Ok(File::from(fd)),
            Err(e) => tracing::warn!(?e, "illumos input: libseat open of {} failed, opening directly", path),
        }
    }
    open_nb(path)
}
fn open_nb(path: &str) -> std::io::Result<File> {
    use std::os::unix::fs::OpenOptionsExt;
    std::fs::OpenOptions::new().read(true).custom_flags(OFlags::NONBLOCK.bits() as i32).open(path)
}

/// Drain whole Firm_events from a non-blocking VUID fd.
pub fn read_events(f: &mut File, dev: VuidDevice, out: &mut Vec<InputEvent<VuidInput>>) -> std::io::Result<()> {
    let mut buf = [0u8; FE_SIZE * 64];
    loop {
        match f.read(&mut buf) {
            Ok(0) => return Ok(()),
            Ok(n) => for c in buf[..n - n % FE_SIZE].chunks_exact(FE_SIZE) {
                out.extend(translate(dev, Firm::parse(c.try_into().unwrap())));
            },
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => return Ok(()),
            Err(e) => return Err(e),
        }
    }
}

/// calloop source over /dev/kbd + /dev/mouse. A missing device is skipped with a warning
/// (a headless box has neither); the source still registers, so a later hotplug is the gap.
pub struct VuidSource { kbd: Option<Generic<File>>, mouse: Option<Generic<File>>, added: bool }

impl Drop for VuidSource {
    fn drop(&mut self) {
        restore_console_input(); // before the fds close
    }
}

impl VuidSource {
    pub fn new(mut session: Option<LibSeatSession>) -> Self {
        let g = |r: std::io::Result<File>, what: &str| match r {
            Ok(f) => Some(Generic::new(f, Interest::READ, Mode::Level)),
            Err(e) => { tracing::warn!(?e, "illumos input: {} unavailable", what); None }
        };
        VuidSource { kbd: g(open_kbd(&mut session), "/dev/kbd"), mouse: g(open_mouse(&mut session), "/dev/mouse"), added: false }
    }
}

impl EventSource for VuidSource {
    type Event = InputEvent<VuidInput>;
    type Metadata = ();
    type Ret = ();
    type Error = std::io::Error;

    fn process_events<F>(&mut self, r: Readiness, t: Token, mut cb: F) -> Result<PostAction, Self::Error>
    where F: FnMut(Self::Event, &mut ()) {
        let mut evs = Vec::new();
        if !self.added {
            self.added = true;
            if self.kbd.is_some() { evs.push(InputEvent::DeviceAdded { device: VuidDevice::Keyboard }); }
            if self.mouse.is_some() { evs.push(InputEvent::DeviceAdded { device: VuidDevice::Mouse }); }
        }
        for (src, dev) in [(&mut self.kbd, VuidDevice::Keyboard), (&mut self.mouse, VuidDevice::Mouse)] {
            if let Some(g) = src {
                g.process_events(r, t, |_, f| { read_events(unsafe { f.get_mut() }, dev, &mut evs)?; Ok(PostAction::Continue) })?;
            }
        }
        for e in evs { cb(e, &mut ()); }
        Ok(PostAction::Continue)
    }
    fn register(&mut self, p: &mut Poll, tf: &mut TokenFactory) -> smithay::reexports::calloop::Result<()> {
        if let Some(g) = &mut self.kbd { g.register(p, tf)?; }
        if let Some(g) = &mut self.mouse { g.register(p, tf)?; }
        Ok(())
    }
    fn reregister(&mut self, p: &mut Poll, tf: &mut TokenFactory) -> smithay::reexports::calloop::Result<()> {
        if let Some(g) = &mut self.kbd { g.reregister(p, tf)?; }
        if let Some(g) = &mut self.mouse { g.reregister(p, tf)?; }
        Ok(())
    }
    fn unregister(&mut self, p: &mut Poll) -> smithay::reexports::calloop::Result<()> {
        if let Some(g) = &mut self.kbd { g.unregister(p)?; }
        if let Some(g) = &mut self.mouse { g.unregister(p)?; }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fe(id: u16, value: i32) -> [u8; FE_SIZE] {
        let mut b = [0u8; FE_SIZE];
        b[0..2].copy_from_slice(&id.to_ne_bytes()); b[4..8].copy_from_slice(&value.to_ne_bytes());
        b[8..12].copy_from_slice(&2i32.to_ne_bytes()); b[12..16].copy_from_slice(&5i32.to_ne_bytes()); b
    }
    #[test]
    fn keys_buttons_motion() {
        use smithay::backend::input::{Event, KeyboardKeyEvent, PointerButtonEvent, PointerMotionEvent};
        let Some(InputEvent::Keyboard { event }) = translate(VuidDevice::Keyboard, Firm::parse(&fe(4, 1))) else { panic!() };
        assert_eq!((event.key_code().raw(), KeyboardKeyEvent::state(&event), event.time().micros()), (30 + 8, KeyState::Pressed, 2_000_005)); // HID 'a'
        let Some(InputEvent::PointerButton { event }) = translate(VuidDevice::Mouse, Firm::parse(&fe(MS_LEFT + 2, 1))) else { panic!() };
        assert_eq!(event.button_code(), 0x111); // MS_RIGHT -> BTN_RIGHT
        let Some(InputEvent::PointerMotion { event }) = translate(VuidDevice::Mouse, Firm::parse(&fe(LOC_Y_DELTA, 3))) else { panic!() };
        assert_eq!(event.delta_y(), -3.0);
        assert!(translate(VuidDevice::Keyboard, Firm::parse(&fe(0, 1))).is_none()); // HID 0 = none
    }
}
