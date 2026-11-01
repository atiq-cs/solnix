# btintelfw: provenance and licence

## Vendored, unmodified (`upstream/`, read-only)

FreeBSD `usr.sbin/bluetooth/iwmbtfw` at freebsd-src main 9da2c05a748f (2026-11-01).
Licence: **BSD-2-Clause** (SPDX header in each file; Adrian Chadd 2013, Vladimir Kondratyev
2019, Future Crew LLC 2023). No GPL. Linux btintel.c was not read.

| file | lines | sha256 (first 16) |
|---|---|---|
| main.c | 842 | ebee5557464c4f39 |
| iwmbt_hw.c | 721 | 12d4ef017969b8eb |
| iwmbt_fw.c | 299 | a9ec00b8b724833b |
| iwmbt_fw.h | 158 | 6396555914493ca9 |
| iwmbt_hw.h | 122 | ac55bb37b77369a6 |
| iwmbt_dbg.h | 45 | 20f43241f8fb6b1d |
| iwmbtfw.8 | 104 | 5dc060d85a4721ca |

The upstream files are never edited. `btintelfw.c` `#include`s main.c (with `main` renamed)
and iwmbt_hw.c, so it can call their static helpers, and iwmbt_fw.c compiles on its own.

## New solnix code (CDDL-compatible; no libusb or Linux code copied)

* `ugen_usb.c`, `compat/libusb.h`: the libusb-1.0 calls iwmbtfw makes (17 functions), implemented over
  illumos ugen(4D) nodes `/dev/usb/<vid>.<pid>/<inst>/{cntrl0,if0in1,if0out2,if0in2}`.
* `ugen_evq.[ch]`: rebuilds HCI event boundaries from ugen's coalesced interrupt-IN stream.
* `btintelfw.c`: modes -r (read-only TLV and firmware name), -l (upstream handle_9260),
  -V [-n N] (HCI_Read_Local_Version), and -t (self-test).
* `selftest.c`, `negative-controls.sh`: the self-test runs against a fake ugen directory, and
  5 sabotages must each fail it.
* `compat/`: the FreeBSD sys/endian.h, bluetooth.h (bdaddr_t) and ng_hci.h (one constant)
  subsets, plus timespec/nitems.

## Firmware

Not here. `pkgs/illumos/ibt-firmware.nix` builds it from linux-firmware 20241017
(LICENCE.ibt_firmware: redistributable, unmodified, no reverse engineering) and only with
`acceptFirmwareLicense`.

## Build

`gmake -f Makefile.illumos PROTOINC=<gate proto>/usr/include check`, on an illumos host
(chef). Never on floki.
