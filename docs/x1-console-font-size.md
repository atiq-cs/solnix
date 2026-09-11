# Making the X1's console font readable — diagnose from the `OK` prompt

## Why the font is tiny, and what the actual lever is

The loader/kernel ship **one built-in font: 8×16 pixels**. There is no larger built-in to select, so
"use a bigger font" is not directly available. But `set_font()` (`common/font/font.c:232`) computes:

```c
*rows = (height - BORDER_PIXELS) / font->height;
*cols = (width  - BORDER_PIXELS) / font->width;
```

Glyphs are a **fixed pixel size**, so on a high-resolution panel they occupy a smaller fraction of the
screen. **Lowering the framebuffer resolution is the lever** — an 8×16 glyph on a 1280×800 mode is
visually ~3× the size it is on 3840×2400, for free, with no font work.

## Commands to run at the `OK` prompt

The loader has a `framebuffer` command (`efi/loader/framebuffer.c:737`). Its usage string:

```
usage: framebuffer on | off | get | list [depth] | set <display or GOP mode number>
```

So:

```
OK framebuffer get
OK framebuffer list
```

`list` prints every GOP mode the firmware offers with its dimensions. Pick a **low** one — 1024×768 or
1280×720/800 if offered — and:

```
OK framebuffer set <number>
OK boot
```

That is non-destructive and applies to this boot only.

Note `framebuffer set` calls `reset_font_flags()` before `efifb_set_mode()`, so the font is re-selected
for the new geometry — exactly the path we want.

### Also worth capturing

```
OK mode
```

`command_mode` (`efi/loader/main.c:1145`) prints `Current mode: N` and then `Mode N: C columns, R rows`
for every EFI **text** mode. Cheap, and tells us what the firmware thinks it can do.

## What to send back

* the `framebuffer list` output (or a photo)
* the `mode` output
* which mode number you set, and whether the text got bigger

With the mode list I can bake the right choice into the media's `loader.conf` so it is readable from
first boot, instead of you setting it every time.

## The permanent fix, once a good mode is known

`loader.conf` accepts the same setting, so the media can ship it. Combined with the two lines already
proven on this hardware:

```
console="text"
os_console="text"        # ← currently MISSING from the media; this was the keyboard bug
efi-max-resolution="1280x800"   # or the chosen mode
```

## If no low mode is offered

Then the fallback is a real font change: add a larger built-in (e.g. 16×32) to the kernel font list, or
use the loader's `loadfont` command (`gfx_fb.c:2372`) with a font file on the media. That is a code
change, so it is worth checking `framebuffer list` first — one command against a rebuild.
