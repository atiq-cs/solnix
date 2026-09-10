# X1 Carbon keyboard: four dead hypotheses, and what the next boot must measure

## Status (image `e`, 2026-09-10)

No keyboard input at `solnix console login:` — internal or external Kensington. Everything else on the
media is now **confirmed working on the X1**: staging allocation fits, ZFS initialises, `/dev/sad`
exists (no `ttymon` error), console flood gone (one summary line, not ten device names).

## Dead hypotheses — do not re-investigate

| # | hypothesis | killed by |
|---|---|---|
| 1 | `hid` rejects every keyboard's descriptor | Kensington attaches: `hid2 (keyboard@0) online`, `hid3 online`. Only `hid1` (internal composite) fails |
| 2 | STREAMS chain (`usbkbm`/`kbtrans`/`conskbd`) missing from media | all present, verified inside the mounted ramdisk |
| 3 | `path_to_inst` pins a PS/2 `kb8042` the X1 lacks | file is **emptied** at `oi-make-livecd.sh:560`; 0 bytes shipped |
| 4 | `console="text,ttya"` makes stdin the (nonexistent) serial port | image `e` shipped `console="text"`; keyboard still dead |

Four for four, each plausible, each with a mechanism, each wrong. The common flaw: **reasoning from
the build inputs instead of instrumenting the machine.**

## What is now known about the input path

A USB keyboard becomes the console keyboard via **DACF**, not by attaching:

```
/etc/dacf.conf:
  driver-minorname="hid:internal_keyboard" consconfig_dacf:kb_config post-attach - pushmod="usbkbm"
```

`hid` creates `internal_keyboard` when its minor name is `keyboard` (`hid.c:712`) → the rule fires
`kb_config` → `do_config` (`consconfig_dacf.c:1580`) → `ldi_open_by_dev` → `consconfig_prepare_dev`
pushes `usbkbm` (`:1110`) → `consconfig_relink_conskbd` (`:1604`).

Verified: the rule text **is** on the shipped ramdisk; `hid2` **is** `keyboard@0`. The X1 console shows
**no** `consconfig_prepare_dev: … I_PUSH failed` and **no** `consconfig_relink_wc:` warning — those are
`cmn_err(CE_WARN)` and would have appeared.

So exactly two possibilities remain, and a photo cannot separate them:

* **(a)** `kb_config` ran and succeeded silently → the keyboard *is* linked under `conskbd`, and the
  fault is downstream in `wc`/`conskbd`/`login`.
* **(b)** `kb_config` was **never invoked** → the DACF rule did not fire for `hid2`'s minor node.

## What the next image does

Instrumentation, not a fifth guess:

* `set consconfig:consconfig_errlevel = 0` in the ramdisk `/etc/system` → `consconfig_print_paths()`
  announces `keyboard path = …` and the `do_config` decisions. (Already in `oi-make-livecd.sh` at HEAD;
  image `e` did **not** get it because `e` was a local re-assembly of `d`'s ramdisk.)
* A short `SOLNIX-KBDDIAG` block on the console after `devfsadm`: `/dev/kbd`, `/dev/conskbd`, the
  `hid` minors, `modinfo` for the STREAMS modules, `strconf < /dev/kbd`, and the `hid:` lines of
  `/etc/dacf.conf`.

That single boot distinguishes (a) from (b).

## And the way around it

`/etc/solnix-autoinstall` already exists (`oi-make-livecd.sh:870-896`). The next image makes it
triggerable from a marker file on the USB stick's own filesystem, so the maintainer can install
**without a keyboard** — opt-in, first non-removable disk, target printed with a countdown before any
write. Viable only because ZFS now works on the media (0/8 faults, verified).

## Update: the instrumentation knob was itself inert, and the fault space is now three paths

### `consconfig_errlevel=0` does nothing on our kernel

`consconfig_dprintf()` (`consconfig_dacf.c:305`) drops **every** `DPRINT_L0` message before it ever
checks `consconfig_errlevel` when the kernel is built without `DEBUG`:

```c
#ifndef DEBUG
	if (!l) {
		return;
	}
#endif
	if (l < consconfig_errlevel) return;
```

Our banner is `Version illumos-… 64-bit` — no `DEBUG`. So the `keyboard path = …` lines I promised
would appear **cannot** appear. Same trap as `dboot_printf` output that never reaches a metal console:
I chose an instrument that structurally could not carry the answer. Caught by reading the printf
before shipping the image, not after.

### Why the X1 has no console keyboard at boot — by design

`plat_kbdpath()` on i86pc (`consplat.c:197-211`) returns the **`kb8042`** path or `NULL`. Nothing
else. A machine with no i8042 therefore has **zero** console keyboards when `dynamic_console_config()`
runs, and `conskbd` has no lower queue. Output works, input does not — **this is normal illumos
behaviour on PS/2-less hardware**, not a bug in our media.

The **only** way a USB keyboard becomes the console keyboard on such a machine is the DACF hotplug
rule `hid:internal_keyboard → consconfig_dacf:kb_config`. QEMU and EC2 both emulate an i8042, so
`kb8042` binds at boot and this path is never exercised there. That is why `dixi` reports
`conskbd_lqueue_nums = 1` and `kbd -t` says "USB keyboard" with no physical keyboard attached — the
emulated PS/2 is the console keyboard. Sixth emulator/target divergence.

### The fault is in one of exactly three SILENT paths

Every step of the DACF chain reports failure with `cmn_err(CE_WARN)` — `I_PUSH usbkbm` (`:1113`),
`relink_conskbd` (`:1161-1190`), `relink_wc` (`:784-804`) — and **none appeared** on the X1. Three
places fail without a message:

| | path | userland test |
|---|---|---|
| **S1** | the DACF rule never matched hid2's post-attach | `internal_keyboard` minor absent under `/devices` for `keyboard@0` |
| **S2** | `kb_config` ran, `space_fetch("consconfig") == NULL` → `DACF_FAILURE`, deliberately silent (`:1657`) | only if hid attached before console config — unlikely, the Kensington attached *after* login |
| **S3** | `do_config`'s `ldi_open_by_dev()` on the hid minor failed → `DACF_FAILURE` at `:1583`, **no message** | the raw hid `:keyboard` minor cannot be opened from userland |

And a single userland probe splits "linked" from "not linked": `conskbd`'s ioctl handler NAKs
`KIOCTYPE` with `EINVAL` when `conskbd_lqueue_nums == 0` (`conskbd.c`, ioctl `default:`), so
**`/usr/bin/kbd -t` errors if nothing is linked** and succeeds if something is. On dixi it succeeds.

Verified in passing: `/etc/dacf.conf` **is** in the boot_archive (dirent and rule body found) and is
opened via `kobj_open_file()` at `dacf_init()`, so the rule table loads early. Not the problem.
