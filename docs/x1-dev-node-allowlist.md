# The real defect: a hardcoded 12-name `/dev` allowlist with no verification

## What it is

`scripts/oi-make-livecd.sh:450`:

```sh
for n in console msglog null zero tty syscon systty sysmsg random urandom poll dld dlpi; do
  [ -L "/dev/$n" ] || continue
  _t=$(ls -ld "/dev/$n" 2>/dev/null | sed -n 's/.* -> //p')
  [ -n "$_t" ] || continue
  rm -f "$RDROOT/dev/$n" 2>/dev/null || true
  ln -s "$_t" "$RDROOT/dev/$n" 2>/dev/null || true
done
```

Twelve names, fixed. Measured in the **shipped** `usb-image-20260909b` ramdisk: exactly **12 symlinks**,
and **neither `/dev/zfs` nor `/dev/sad`** is present.

That maps directly onto two errors from the X1 boot:

| console error | missing node |
|---|---|
| `internal error: failed to initialize ZFS` | `libzfs_init()` opens **`/dev/zfs`** |
| `ttymon: open /dev/sad/user failed: No such file or directory` | **`/dev/sad/user`** |

## ⚠️ Two different shapes — the loop silently skips one

Measured on a working illumos host:

```
/dev/zfs   SYMLINK   -> ../devices/pseudo/zfs@0:zfs
/dev/sad   DIRECTORY containing:
             admin -> ../../devices/pseudo/sad@0:admin
             user  -> ../../devices/pseudo/sad@0:user
```

So adding `zfs` to the list works. **Adding `sad` does not** — `[ -L /dev/sad ]` is false for a
directory, `continue` fires, and the loop does nothing, silently. `ttymon` wants `/dev/sad/user`
specifically, so the directory and both symlinks inside it must be created explicitly.

## The root defect is the pattern, not the two names

This is the **same allowlist** whose preceding comment apologises for the `readlink` bug — where
`/usr/bin/readlink` does not exist on illumos, so `ln -sf ""` silently no-oped and the ramdisk got
**zero** of its 13 nodes, blocking ~52 services via missing `dld`. That fix corrected the *derivation
idiom*. **Nobody questioned the list's contents.**

`dld` itself was only added after it silently broke those ~52 services. So the history is: a hardcoded
list, grown reactively, each addition prompted by a production failure.

**The durable fix is a verification step** — assert that the built ramdisk contains every `/dev` node
the media's services actually open, and **fail the build loudly** if one is missing. Adding two names
fixes today's boot; a check stops the next one.

## What this does and does not explain

* ✅ `libzfs` failing to initialise — `/dev/zfs` absent. Testable in QEMU (`zpool list`).
* ✅ the `ttymon` error — `/dev/sad/user` absent.
* ❓ **the dead keyboard: still unexplained.** Do not assume this fixes it. `ttymon` being degraded is
  consistent with a keyboard problem but is not proof of causation, and the STREAMS modules and `hid`
  binding were all verified present.

## Two hypotheses this replaces

Both refuted by inspecting the shipped artifact rather than reading the build script:

1. **`/etc/path_to_inst` shipping a PS/2 `kb8042` pin** — the file is *emptied* at `:560`; it is 0 bytes
   in the shipped image. See `docs/x1-path-to-inst-hypothesis.md`.
2. **Missing STREAMS keyboard modules** — `usbkbm`, `usbms`, `usb_ah`, `kbtrans`, `consconfig`,
   `consconfig_dacf`, `sad`, `hid`, `conskbd`, `consms` are all present.

The method lesson: **the shipped `boot_archive` is the ground truth about what the machine booted.**
Mounting it settled in one step what two rounds of source reading got wrong.
