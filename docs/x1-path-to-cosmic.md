# X1 Carbon: from "solnix boots" to a COSMIC desktop with a home-manager `gburd`

Written after the maintainer got a **working keyboard and root login on the installed system** by
setting `console=text` + `os_console=text` at the loader prompt. Four asks are outstanding, and they
have very different costs. Ordered by dependency, with what is proven vs projected called out.

## 0. Confirmed on hardware, and it changes the diagnosis

`set console=text` + `set os_console=text` → keyboard works, root logs in.

So the mechanism was `solnix-install:619` hardcoding the installed system to `console="ttya"`: with no
serial port the loader falls back for **output** while the kernel's console **input** stays on a
nonexistent device. Output visible, keystrokes discarded.

⚠️ **This probably also explains the LIVE MEDIA's dead keyboard, and invalidates five hypotheses.**
Media `f` and `i` both set `console="text"` but **neither sets `os_console`**. The maintainer's override
needed **both** lines. `multiboot2.c:468` reads `os_console` via `getenv` and `:598-603` only defaults it
when the variable is unset *and* there are multiple consoles — so the kernel console was never pinned to
the framebuffer. The `consconfig:usb_kb_path` override shipped in image `i` was very likely never
needed: the internal keyboard worked with `console`+`os_console` alone.

**Action (cheap, high value): add `os_console="text"` to the media's `loader.conf` in both stages.**
One line, and it is the only keyboard change with hardware evidence behind it.

## 1. `nix` on the installed system — prerequisite for everything else

There is no `nix` binary, **by design**: the install took the `SELF_INSTALL` path, which the log states
outright (*"skipping generation/switch-tool registration (no nix toplevel)"*). It faithfully copied a
nix-less live root. `/nix-tools224` is **not** in the ramdisk, so it could not have been copied.

Two routes:

| route | cost | notes |
|---|---|---|
| **bootstrap onto the running system** | no reinstall | `scripts/oi-fleet-bootstrap.sh` installs Nix 2.24.15 from the relocatable tarball, **no compile**. Needs networking. |
| **stage `/nix-tools224` into the media** | one rebuild | then every install has nix from first boot. ~185 MB, and boot_archive has 438 MiB of headroom — it fits. |

The second is the right answer for a reusable installer; the first unblocks *this* machine today.

## 2. Networking — and I was wrong about wifi

⚠️ **Correction.** I previously told the maintainer illumos has *zero* wifi drivers. **False.** illumos
ships **15** (`arn ath atu ipw iwh iwi iwk iwn mwl rtw rum ural urtw wpi zyd`) plus the `net80211`
stack. My earlier claim came from grepping the *build host's* `/kernel/drv/amd64` — an EC2 VM with no
wireless hardware — and generalising. Measuring the wrong object, again.

But the honest caveat stands: `iwn`'s device table is Intel **WiFi Link 1000/100/1030/105** era. A
current X1 Carbon has an Intel **AX2xx**, which none of these cover. So:

* **USB-Ethernet dongle for now** — supported and boring.
* wifi needs a driver port (out of scope for the installer).

## 3. Console font — 4× bigger

The loader has a `loadfont` command (`gfx_fb.c:2372`) and the kernel's `set_font()`
(`common/font/font.c:232`) honours `FONT_MANUAL`/`FONT_BOOT`. The loader also exports `screen-height` /
`screen-width` (`tem.c:531-534`).

Simplest lever: the built-in fonts are selected by cell size, and the loader can be told which to use.
Also worth setting `efi-max-resolution` lower — on a 4K panel a lower mode makes every glyph
proportionally larger with no font work at all. **Try at the loader prompt first, before any rebuild.**

## 4. COSMIC desktop + home-manager `gburd`

**Not a media change.** Sequenced honestly:

| step | state |
|---|---|
| `cosmic-term` builds + runs from a derivation | ✅ verified, `ELFOSABI_SOLARIS`, 8/8 under `env -i` |
| `cosmic-files`, `cosmic-edit` build | ✅ ELF-verified, weaker run claim |
| 30-path desktop closure list | ✅ `artifacts/cosmic-desktop-closure.txt` |
| a compositor that **paints** | ❌ **nothing has run against a live compositor** |
| GPU | ⚠️ **`vgatext` only** — no `i915`. Software rendering (llvmpipe) at best |
| home-manager `gburd` | ⚠️ `configurations/gburd.nix` exists; never applied on hardware |

Two committed runtime fixes (wayland-client poll timeout, calloop timer dispatch) were **needed for
runtime, not compilation** — expect **hangs**, not build errors, on the first compositor attempt.

## Recommended order

1. **`os_console="text"` in the media** (one line; likely fixes the live keyboard too)
2. **Stage `/nix-tools224` into the media** so installs get nix from first boot
3. **Font/resolution** via loader knobs — test interactively before rebuilding
4. **Then** COSMIC, on a machine that has nix and a shell — that is where the real work is, and
   `vgatext`-only means llvmpipe software rendering is the realistic target

Steps 1–3 are one rebuild. Step 4 is a project.
