# The ZFS/ttymon fault on USB is a RACE, not a missing node — and three of my claims were wrong

## Corrected claims

### ⚠️ 1. "QEMU reproduces the hardware failure" — WITHDRAWN

I told the maintainer that the USB bus gives us a QEMU-reproducible proxy, based on 2/2 USB boots
failing versus 0/16 on other buses. **That 2/2 was a burst, not a rate.** Fresh USB boots measured
`usb-1` clean and `usb-2` faulting. The fault is **intermittent on USB**.

This is precisely the hazard already documented in this project's own sub-agent rules — *flaky things
here are bursty, so a small sample lies* — measured earlier on the riscv64 gates as 1/4 then 8/8 on an
identical tree. I read a 2-sample burst as a deterministic signal, having written the warning myself.

So: QEMU reproduces this **sometimes**. Useful, but not the closed iteration loop I claimed.

### ⚠️ 2. "The keyboard may have the same cause" — REFUTED (negative result)

On **both** USB and virtio boots the console keyboard attaches identically:

```
8042 device:  keyboard@0, kb8042 # 0
```

QEMU supplies a **PS/2 `kb8042` regardless of the storage bus**, so no QEMU boot exercises the X1's
USB-HID keyboard path at all. **The keyboard remains unexplained.**

Untried and worth a future run: `-device usb-kbd` on the xhci bus, which *would* exercise
`hid → usbkbm → kbtrans → conskbd`. That is the missing instrument.

### ⚠️ 3. "`eedev` is missing from the media" — MEASUREMENT ARTIFACT

See `docs/install-media-driver-coverage.md`. My NUL-delimited byte matcher was the unreliable part.

## The actual mechanism: a race

Post-login on a **failing** USB boot, everything the errors complained about **exists**:

* `/dev/zfs` and `/dev/sad/{admin,user}` present
* `zpool list` works
* `truss` shows `open("/dev/zfs", O_RDWR) = 3` succeeding
* `zfs mount -a` returns rc=0

So `filesystem/local` and `ttymon` run **before** `devfsadm` has created those nodes. The slower
`scsa2usb` + `sd` enumeration on USB widens the window, which is why the bus correlates without being
deterministic.

That reframes the `/dev` staging patch: it is **race-closing, not gap-filling**. Staged nodes exist at
time zero, so an early consumer cannot lose the race.

## ⚠️ The objection that could make the fix inert

`/dev` is a **`dev(7FS)` mount** — verified on a live host:

```
$ mount -p | grep /dev
/dev - /dev dev - no
```

If the filesystem is mounted over the staged directory at runtime, **staged nodes are invisible and the
patch does nothing.** This must be tested before the fix is claimed to work. The agent raised this
against its own patch, which is the behaviour worth having.

If the objection holds, the fix has to be different in kind — e.g. ordering `filesystem/local` and
`ttymon` after `devfsadm` completes, rather than pre-creating nodes.

## Standing lesson

Three of the four corrections here are mine, and all three share a shape: **I accepted a small sample
or a lossy instrument as a settled fact.** 2 boots read as a rate; a byte-grep read as an inventory; a
bus correlation read as a cause. The project rules already name every one of these traps.
