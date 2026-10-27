# cosmic2: the input route for cosmic-comp on illumos

## Decision: (b), done as a source patch rather than a feature switch: an illumos VUID input source in cosmic-comp's KMS backend

The keyboard and mouse come from `/dev/kbd` and `/dev/mouse` (the conskbd and consms
multiplexers) as illumos `Firm_event` records. A small smithay `InputBackend`
inside cosmic-comp turns them into events. No libinput, no evdev shim, no udev.

The rest of this file is the evidence. "Measured" means a command was run and its output is
in /scratch/solnix/cosmic2/.

## What each route needs (measured)

| | needs | measured |
|---|---|---|
| (a) libinput + illumos backend | libinput 1.26 `dependency('libudev')`, `dependency('mtdev')`, `dependency('libevdev')` (hard, meson.build:146-148). src/evdev.c: 120 libevdev/EVIOC call sites. udev-seat.c: 118 udev calls, path-seat.c: 40. | All three are Linux-kernel ABIs: evdev ioctls, the udev netlink monitor, mtdev over evdev. A backend means rewriting libinput's device layer (evdev.c is the core, ~3.5k lines), or providing all three. |
| (c) evdev shim | a kernel or CUSE `/dev/input/eventN` speaking `EVIOCG*` plus `input_event`, a libudev with enumerate+monitor, mtdev | illumos has no CUSE. A userland shim cannot be opened by path by libinput. It would be a kernel driver. |
| (b) no libinput | cosmic-comp-epoch-1.5.0 Cargo.toml: features are only `debug/systemd/logind/profile*`. smithay is pinned with `backend_libinput` and `backend_udev` ON. cosmic-comp-config has `input = "0.10.0"` **non-optional**, and src/config uses `input::Device` config calls. | **No feature turns libinput off.** (b) as a feature switch is refuted. As a source patch it is bounded (next section). |

## Why (b) as a patch is bounded (measured in the source)

* libinput is used in **one** backend file: `src/backend/kms/mod.rs`, 20 references
  (`init_libinput`, the `Libinput` context in `KmsState`, `resume`/`suspend`). Everything
  else (src/input/mod.rs `process_input_event<B: InputBackend>`) is **generic over
  smithay's `InputBackend` trait**. The `input::Device` downcasts at src/input/mod.rs:924
  and 2516 and at src/shell/seats.rs:119 are `if let Some(..)`, so a different device type
  skips per-device config instead of failing.
* So `input-sys` still has to **link** (`#[link(name = "input")]`, prebuilt bindings, no
  bindgen). Real libinput calls only happen on a libinput device, and with this route none
  exists. The link needs a `libinput.so.10`. Two ways to get one: (i) a stub library that
  exports the symbols and returns failure (tagged STUB), or (ii) gate the `input` crate out
  with cfg patches across smithay and cosmic-comp-config. (i) is a few hundred lines that
  can be generated from the input-sys bindings. (ii) touches about 30 files.
* udev has the same problem. smithay's `UdevBackend` (device list and hotplug for
  `/dev/dri/card*`) and `primary_gpu()` use libudev. There is no udev on illumos, so the
  KMS backend needs a fixed `/dev/dri/card0` device list instead of `init_udev`.

## The illumos input interface (measured on the EC2 build host, evidence-vuid-ec2.txt)

    open kbd=3(ok) mouse=4(ok)
    KIOCTRANS(TR_UNTRANS_EVENT)=0     <- raw keys as Firm_event (id = USB HID usage, see below)
    VUIDSFORMAT(VUID_FIRM_EVENT)=0    <- mouse deltas/buttons as Firm_event
    sizeof(Firm_event)=16             <- {u16 id; u8 pair_type; u8 pair; i32 value; timeval32}

kb8042 and mouse8042 are attached there (EC2 emulated i8042). On the X1, usbkbm/usbms/hid
feed the same conskbd/consms multiplexers, so the reader is the same. That is NOT measured
on lixi here (the brief keeps lixi with the orchestrator).
Mapping: mouse `LOC_X_DELTA`/`LOC_Y_DELTA` -> PointerMotion, `MS_LEFT..MS_RIGHT` -> BTN_LEFT /
BTN_MIDDLE / BTN_RIGHT, the VUID wheel -> PointerAxis. The keyboard id is a **USB HID usage**, not a
keytable station. I read this in the gate source: conskbd sends CONSSETKBDTYPE=KB_USB to every
lower keyboard (conskbd.c:1446), kb8042 then maps PS/2 through keytab_pc2usb (kb8042.c:1143),
and usbkbm passes usages through. (An earlier draft said "station"; that was wrong.) The
usage->evdev table comes from FreeBSD evdev_utils.c (BSD-2). The constants were checked
against the headers by a C program (evidence-vuid-const.txt: VKEY_UP is 0, not 0x80 as first
guessed).

## Implemented (cosmic-status.md)

1. pkgs/illumos/graphics/cosmic-comp/illumos_input.rs: an `InputBackend` plus calloop source
   over the two fds, wired into kms/mod.rs by cosmic-comp-src-fixup.py. The fixed /dev/dri
   scan replacing udev is in cosmic-comp-udev-illumos.py.
2. STUB libudev.so.1 and libinput.so.10, link only (cosmic-comp-stubs.sh).
3. Unit test of the Firm_event translation: 1/1 ok. Negative control (swap middle/right) FAILS.
   Measured in the built compositor (truss): KIOCTRANS = 0, VUIDSFORMAT = 0.
4. Not done or not measurable here: real key and mouse events (EC2 has no input; lixi stage),
   touchpad gestures / touch / tablets, input hotplug, per-device config.

Status at the end of this track: see progress.txt and the cosmic-comp section of the final report.
