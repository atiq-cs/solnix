# X1 Carbon: no keyboard at the console — `hid` rejects the internal keyboard's descriptor

## Try this first

**Plug in a plain wired USB keyboard.** Likely a 30-second fix, and it unblocks everything else.

## What is happening

The console shows, repeatedly:

```
/pci@0,0/pci17aa,2267@14/device@a/input@1 (hid1): Invalid Report Descriptor
```

`0x17aa` is Lenovo; `@14` is the xHCI controller. On this ThinkPad the **internal keyboard is a USB
HID device**, not PS/2.

That message is printed at `usr/src/uts/common/io/usb/clients/hid/hid.c:2156`, and the code path
immediately after it is decisive:

```c
} else {
        USB_DPRINTF_L1(PRINT_MASK_ATTA, hidp->hid_log_handle,
            "Invalid Report Descriptor");
        freemsg(data);

        return (USB_FAILURE);        /* <-- attach ABORTS */
}
```

So `hidparser` cannot parse this keyboard's report descriptor, `hid_attach` fails for that device, and
no keyboard driver ever binds to it. Nothing reaches the login prompt.

**This is not a missing module.** `hid1` appears in the tree, so `hid` loaded and ran; `usba` and
`xhci` obviously work because the USB stick was read and `blkdev0` came online. It is a
descriptor-parsing gap in illumos's `hidparser` against this specific device.

## ⚠️ I called this "harmless noise" and I was wrong

In the previous message I listed `Invalid Report Descriptor` under "lower priority… harmless noise",
because it was repeating and the boot continued to a login prompt. The boot *did* continue — but the
device that failed was the input device needed to use it. **A driver attach failure is never noise,
and "the system kept going" is not evidence a failure was cosmetic.** The repetition should have been
the tell: something was retrying and never succeeding.

## Why QEMU never showed this

Our QEMU boots get a **PS/2** keyboard:

```
8042 device:  keyboard@0, kb8042 # 0
kb80420 is /pci@0,0/isa@1f/i8042@1,60/keyboard@0
```

`kb8042` binds without any HID parsing. The X1 has no PS/2 controller at all, so it takes a code path
QEMU never exercises. Same shape as the 820 MiB staging failure: **the emulator was systematically
easier than the target in exactly the dimension that mattered.**

## Options

| option | verdict |
|---|---|
| external wired USB keyboard | **try this** — presents a standard boot-protocol descriptor |
| USB hub, if ports are full | fine, illumos handles hubs |
| serial console | not viable — no physical serial port on this machine |
| fix `hidparser` | the real fix, but a kernel change and not a tonight job |

If an **external keyboard also fails**, the diagnosis changes completely — that would point at xHCI
rather than descriptor parsing, and is more serious.

## Worth capturing when you have a keyboard

```sh
prtconf -D | grep -i hid          # which hid instances attached
usbconfig                          # or: cfgadm -al
```

That tells us whether the internal keyboard is enumerated-but-unbound, and gives us the descriptor to
compare against `hidparser`'s expectations — the input needed to fix this properly.
