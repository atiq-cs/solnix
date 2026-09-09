x1: the FULL memmap says we missed by 41.7 MiB (5.1%) -- a near-miss, not a wall. I was wrong to stop the fix.

The maintainer photographed the complete memmap output. ConventionalMemory regions BELOW 4 GiB:

  0x000000100000   0x00030a50 (199248) pages   816,119,808 B   778.3 MiB   <- the big one
  0x000038350000   0x00002115                   34,689,024 B    33.1 MiB
  0x000034b70000   0x000020b9                   34,312,192 B    32.7 MiB
  0x00003a6a6000   0x00000301                    3,149,824 B     3.0 MiB
  0x000058000000   0x00000200                    2,097,152 B     2.0 MiB   <- the line first reported
  + four smaller (0.8, 0.6, 0.2, 0.0 MiB)

  largest free below 4 GiB : 816,119,808 B = 778.3 MiB
  loader requested         : 859,832,320 B = 820.0 MiB
  SHORTFALL                :  43,712,512 B =  41.7 MiB  -> 5.1% short

⚠️ I STOPPED THE FIX ON A MISREADING. When the single 0x58000000 / 0x200-pages line came back I
computed 2 MiB, concluded RD_MB sizing could never work at any size, and told the agent to stand down
after it had ALREADY chosen the correct value (RD_MB=340). Everything that run did was right; only my
intervention was wrong. It has been re-dispatched with 340 unchanged.

What should have stopped me: I ran the consistency check that disproves 2 MiB -- a NORMAL installed
illumos boot_archive on dixi is 140,771,328 B (134 MiB), so a 2 MiB ceiling would mean no illumos
could boot on this machine at all -- and I wrote that down, and still let the stop stand instead of
treating my own reading as the thing most likely to be wrong. The check was right there.

RD_MB=340 -> 356,515,840 B, which holds the measured 195.0 MiB of real content and leaves ~438 MiB of
headroom inside the 778 MiB block. Margin is deliberate: this is ONE machine's memory map and another
will differ.

ALSO CONFIRMED from the same photo, so nobody re-derives it:
  * lsdev shows BOTH disks -- disk0 1953525168x512 (1 TB internal SSD) and disk1 120176640x512
    "(removable) ISO9660" (the USB stick). USB enumeration and ISO9660 both work on real X1 firmware.
  * ls /platform/i86pc/amd64 lists boot_archive + boot_archive.hash -- filesystem reads work.
  * The smap line "type=01 base=...58000000 len=...200000" is that same 2 MiB region. smap collapses
    five EFI types into one and merges adjacent runs, which is exactly why it misled; memmap is the
    correct instrument. Photo committed as artifacts/install-media/x1-memmap-photo.jpg.

The multiboot2 uint32_t constraint recorded earlier still stands and is still the reason the NixOS
layout cannot be copied -- but it is no longer a blocker, because 778 MiB below 4 GiB is plenty once
the ramdisk is honestly sized.
