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
