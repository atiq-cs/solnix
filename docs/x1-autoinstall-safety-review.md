# Safety review: can the unattended installer erase the wrong disk on the X1?

Reviewed before shipping, because an unattended installer that picks the wrong target destroys data
and the maintainer cannot intervene by keyboard.

## The picker

```sh
_tgt=$(cat /etc/solnix-autoinstall)          # "auto"
_media=$(cat /tmp/.solnix-media-disk)        # set only by the media-marker path
for _c in /dev/rdsk/c*t*d0s0 /dev/rdsk/c*d0s0; do
  _d=$(basename "$_c"); _d=${_d%s0}
  [ -n "$_media" ] && [ "$_d" = "$_media" ] && continue      # guard 1
  case "$(fstyp "/dev/rdsk/${_d}p0")" in hsfs) continue;; esac # guard 2
  _tgt=$_d; break
done
```

## Verdict: safe on this machine, with a caveat worth stating

| guard | status when the marker comes from the **ramdisk** |
|---|---|
| 1 — skip `_d == _media` | **INEFFECTIVE.** `_media` is empty; nothing wrote `/tmp/.solnix-media-disk` because the media path never ran |
| 2 — skip any disk whose `p0` is `hsfs` | **effective in principle** — the stick *is* `hsfs` — but only if the stick has `/dev/rdsk` nodes |

And on the X1 **it has none**. Measured from the maintainer's console: `/dev/dsk` contained exactly
`c1t001B448B485502D1d0` and its slices. The USB stick is invisible to the kernel (the same fact that
broke the media-root marker).

So the loop can only ever see the NVMe, and will select `c1t001B448B485502D1d0` — the intended target.
**Safe, but partly for the wrong reason:** guard 1 is inert and guard 2 is unexercised. On a machine
where the stick *does* enumerate (QEMU, where it appears as `c1t0d0`), guard 2 is what catches it. Belt
and braces hold across both cases, just never both at once.

Also checked: the X1 has **no second internal disk** — `lsdev` at the loader showed `disk0` (1 TB) and
`disk1` (removable), nothing else. There is no third candidate for the loop to pick wrongly.

## Remaining protections

* the chosen target and `THIS DISK WILL BE ERASED` print to the console
* `format` output lists the disks it saw
* a **10-second countdown** with a per-second `writing to <disk> in N s` line — powering off during it
  aborts before any write

## What would make this properly safe rather than incidentally safe

Guard 1 should not depend on the media path having run. Either record the boot device independently of
the marker source, or drop guard 1 and rely on an explicit allow-list of non-removable disks. Noted
rather than done — changing target selection while the maintainer is waiting on an install is the wrong
moment, and the current behaviour is verified correct for this machine.

## DONE in `usb-image-20260910i` — this section is superseded

The recommendation above was implemented rather than deferred. Boot-medium identification in
`oi-make-livecd.sh`'s `solnix-live` method is now **unconditional** and keyed on the medium's own
content (a read-only `hsfs` mount containing `/platform/i86pc/amd64/boot_archive`), not on where the
marker was found, so guard 1 is live for every marker source — including the ramdisk-baked one this
image ships. Guard 2 (`fstyp` = `hsfs`) is unchanged, so the two guards still use different mechanisms.

Both are exercised by `scripts/test-autoinstall-picker.sh`, which extracts the picker verbatim from the
build script and runs 7 cases against a stubbed `/dev`. The load-bearing one is the control where
**both guards are disabled and the stick IS selected** — without it, the passing cases would prove
nothing about whether the guards are what excluded the medium. Observed live in QEMU with the media
attached as USB: `boot medium identified as c1t0d0 (solnix ISO9660) -- EXCLUDED from install targets`,
followed by installation to `c2t0d0`, in 4/4 runs.

One further hazard, found while verifying this and **not** a target-selection bug: the installed
system's console was hardcoded to `ttya`, which on a serial-less laptop is a black screen with no
input *after* the disk has been erased. Fixed via `SOLNIX_TARGET_CONSOLE` (default `ttya`; the
unattended path passes `text`). See `docs/usb-install-media.md`.
