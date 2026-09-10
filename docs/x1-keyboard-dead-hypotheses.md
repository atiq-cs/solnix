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
