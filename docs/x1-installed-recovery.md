# solnix IS installed on the X1 — and the dead keyboard is recoverable without reflashing

## What happened

The unattended install **succeeded** on real hardware:

```
=== DONE: solnix installed on c1t001B448B485502D1d0 (pool rpool, BE rpool/ROOT/solnix-1, generation 1)
SOLNIX_AUTOINSTALL_RESULT: DONE
boot_archive OK: 26957283 bytes
```

Bootblock written, stage1 written, UEFI loader installed on the ESP. The machine then booted solnix
from its NVMe. **That is the first solnix install on physical hardware.**

## Why the keyboard is still dead — and it is not the same bug

The maintainer used image `h`, which was built **before** the `SOLNIX_TARGET_CONSOLE` fix. Photo 1 shows
the tell:

```
=== ttya console + release stamp ===
```

That is `solnix-install:619`, which hardcodes the *installed* system to `console="ttya"` /
`os_console="ttya"`. The X1 has no serial port, so the loader falls back for **output** (it answers
`no valid consoles!` and picks something usable — recorded in `make-iso-usb.sh:49`), while the kernel's
console **input** stays pointed at `ttya`. Output visible, keyboard dead — exactly as reported.

So the installed system's dead keyboard has a **different cause** from the live media's: this one is the
hardcoded target console, not `consconfig_usb_kb_path`.

## Recovery without reflashing

The loader prompt takes keystrokes — proven repeatedly on this machine (`smap`, `memmap`, `lsdev` were
all typed there). And `console` is a loader **environment variable**
(`usr/src/boot/common/console.c:158-181` reads it with `getenv`/`env_setenv`), so it can be overridden
per boot:

At the installed system's boot menu, press **`3`** for the loader prompt:

```
OK set console=text
OK set os_console=text
OK boot
```

That applies to this boot only and needs no rebuild. If it yields a working keyboard, it confirms the
diagnosis and gives a shell from which `/boot/loader.conf` on the BE can be edited permanently.

## Note on the two photos

Photo 1 is the install completing on the live media. Photo 2 is **also the live media** — it shows
`live-installer service starting` and the `SOLNIX-KBDDIAG` passes, not the installed system. So neither
photo shows the post-install console, and the `set console=text` test is what will.

## What the next image fixes

`SOLNIX_TARGET_CONSOLE` (default `ttya` to keep existing automated tests and serial captures working;
`text` on the auto-install path). Built and verified in the shipped ramdisk, so a fresh install will not
need the loader override at all.
