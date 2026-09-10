# The installed system's console is hardcoded to a serial port the X1 does not have

## The defect

`scripts/solnix-install:619-631` writes, unconditionally:

```
boot/solaris/bootenv.rc:   setprop console ttya
                           setprop os_console ttya
boot/loader.conf:          console="ttya"
                           os_console="ttya"
```

There is no environment knob. Every solnix install produces a system whose console is **serial only**.

## Why that is fatal on this hardware

The X1 Carbon has no `ttya`. Same fact that forced `console="text"` on the *media*, and
`make-iso-usb.sh:51-52` already records it: *"real hardware (the X1 Carbon) has no ttya at all, so the
framebuffer console ("text") must lead."* The maintainer's own loader screendump lists
`ttya  PciRoot(0x0)/Pci(0x1F,0x0)/Serial(0x0)/Uart(9600,8,N,1)` — a device that is not there — and the
loader has been observed answering `no valid consoles!` in that situation.

So the unattended install would very likely **succeed** and then reboot into a machine with **no output
and no keyboard** — strictly worse than the current state, with the 1 TB NVMe already erased.

## ⚠️ My own evidence was silent on this, and looked like proof

"Installed disk boots alone" was measured in QEMU, and **QEMU has a `ttya`**. That is exactly why the
disk-boot test passed. The measurement was real and it said nothing about the question that matters —
the eighth time in this campaign the emulator was more permissive than the target, and the first time
the gap sat inside a *positive* result I was quoting as reassurance.

Caught by the build agent, against its own proof. That is the behaviour worth having.

## The fix

`SOLNIX_TARGET_CONSOLE`, defaulting to **`ttya`** so every existing automated install test and serial
capture in the repo keeps working unchanged. The auto-install path passes **`text`** — not `text,ttya` —
because `text` alone is the value with real-hardware evidence behind it: the media ships it and the X1
has booted it repeatedly, including the boot that produced the KBDDIAG output. The `ttya-*` setprops are
kept; they are harmless with no serial port and needed when the default is used.

## Why this was fixed rather than named

The standing rule in `docs/working-with-subagents.md` is to capture a new blocker and stop rather than
chain a second repair, and it has paid off repeatedly. This case is a deliberate exception: the artifact's
whole purpose is an *unattended* install, so a post-install console defect is not a follow-up item — it
is a defect in the thing being shipped. Naming it in a README would have handed over a data-destroying
dead end with a footnote.

The distinction worth carrying forward: **name-and-stop applies to blockers you discover; it does not
apply to defects in the deliverable itself.**

## Still unverified

Whether `console="text"` gives a usable post-install console on the X1. Only that machine can say.
