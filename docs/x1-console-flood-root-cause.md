# "No keyboard" was never the keyboard — the login prompt was being fed device names

## What the photo proved

The third X1 photo settles it, and refutes two of my earlier claims.

### 1. The Kensington keyboard ATTACHED SUCCESSFULLY

```
NOVATEK Kensington U+P Keyboard
hid2 is /pci@0,0/pci17aa,2267@14/device@2/keyboard@0
/pci@0,0/pci17aa,2267@14/device@2/keyboard@0 (hid2) online
hid3 is .../device@2/input@1  (hid3) online
```

`hid` **does** bind an external USB keyboard on this machine. My claim that "every keyboard fails
identically, so `hid` rejects all of them" was **wrong**.

### 2. Only ONE device fails, and it is not the external keyboard

Every `Invalid Report Descriptor` line names the *same* device: `hid1` at `.../device@a/input@1`. The
Kensington is `device@2`. So one internal composite device (keyboard/trackpoint) is retrying forever
while the external keyboard is online and fine.

### 3. ⚠️ The login prompt is consuming disk device names as usernames

```
solnix console login: c1t001B448B485502D1d0p0
c1t001B448B485502D1d0p1
c1t001B448B485502D1d0p2
...d0s0 ... d0s12
```

Those are `/dev/dsk` entries being **typed into `login`**.

## Root cause

`scripts/oi-make-livecd.sh`, the `solnix-live` SMF method:

* line 937: `echo "[solnix] disks visible:"; ls /dev/dsk 2>/dev/null | head`
* line 956: `} > /dev/console 2>&1` — the **entire block** is redirected to the console

And `ttymon`/`login` **reads that same device**. So `ls /dev/dsk` output is delivered to `login` as
input. `login` loops rejecting device names as usernames, `hid1` keeps scrolling, and real keystrokes
are interleaved into a firehose and lost.

**The keyboard works. The prompt was drowning.**

The `hid1` spam compounds it: `USB_LOG_L1` is "errors, syslog buffer", but live media has no `syslogd`,
so kernel messages surface on the console too.

## The fix

`devfsadm` output and the disk listing now go to `/var/log/solnix-live.log`, not `/dev/console`. One
short line is printed to the console instead. Applied to **both** the minimal and graphical methods.

**Principle:** nothing chatty may share a device with an interactive login.

## ⚠️ My in-flight fix would have made this WORSE

The `/dev`-staging patch adds *more* nodes — so `ls /dev/dsk` would print *more* lines into the login
prompt. I was about to ship an image that aggravated the reported symptom while believing I was fixing
it. Worth stating plainly: I had a plausible cause (`/dev/zfs` absent), a real defect to point at, and
a patch — and the actual mechanism was somewhere else entirely.

## Also changed: the boot screen says `solnix`

Requested. Two independent sources, **both** required:

* `loader.conf` — `loader_brand`/`loader_menu_title`
* `boot/forth/menu.4th` — hardcodes `s" Welcome to illumos"`, which overrides `loader.conf`

The `menu.4th` patch is **guarded**: if the expected string is absent it fails loudly rather than
silently shipping illumos branding — the silent-no-op class that has bitten this script repeatedly
(`readlink`, `stat`, the `/dev` allowlist).

## Still open

* `hid1` (internal keyboard/trackpoint) genuinely fails `hidparser`. With the console readable and an
  external keyboard attaching, this drops from blocking to cosmetic — but it is a real illumos gap.
* Whether `dev(7FS)` makes the staged `/dev` nodes inert. Unresolved and still worth answering.

## ⚠️ Severity correction: the flood was in EVERY boot, not a third of them

I reported the flood at **3/8** boots on image `c`. **Wrong — it is 8/8.**

My grep was `console login: c[0-9]t`, which only matches when a device name lands *immediately* after
the literal prompt string. Grepping for the device names themselves (`^c[0-9]t...d0`) finds **9–10
typed device names in every one of image `c`'s logs**. Re-verified:

```
before-usb.clean.txt     10 device names
usb-1.log.clean           9
usb-2.log.clean           9
usb-3.log.clean          10
```

So the maintainer's "no keyboard" symptom was present on **every** boot, and the honest comparison is
**8/8 before versus 0/8 after** — not 3/8.

**The error shape:** I measured a *narrower pattern than the phenomenon*. A device name interleaved
three lines below the prompt is just as fatal to typing as one directly after it, and my pattern scored
those as clean. Same family as the NUL-delimited driver grep that falsely reported `eedev` missing —
an approximate instrument reported as a count.

## A second defect found before the rebuild

`scripts/make-iso-usb.sh` step 0 **rewrites `loader.conf` from its own heredoc**, and that heredoc
lacked `loader_brand` / `loader_menu_title`. So the ISO assembler would have **silently reverted half
the branding fix** — `menu.4th` patched correctly on the build host, `loader.conf` overwritten
afterwards. Fixed, plus a **hard gate** that aborts the assembly if `menu.4th` still says
`Welcome to illumos`.

That is a two-stage pipeline where stage 2 quietly undoes stage 1's work. Worth remembering for
anything else `oi-make-livecd.sh` authors and `make-iso-usb.sh` regenerates.
