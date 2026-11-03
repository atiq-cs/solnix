# src/boot-brand: the loader menu's "Solnix" wordmark

`boot/` is laid over every boot environment's `/boot` by install-be (`lay_brand`) when `boot.loader.brand = "solnix"`
(the default), and copied into the live media's `iso/boot` by `scripts/make-installer-image.sh` and
`scripts/oi-make-livecd.sh`:

- `conf.d/solnix-brand`: `loader_brand="solnix"`, so the stock `brand.4th` includes `forth/brand-solnix.4th`.
- `forth/brand-solnix.4th`: draws `solnix-brand.png` where the stock brand goes, or a figlet "Solnix" without a framebuffer.
- `solnix-brand.png`: made by `art.nix`; `scripts/test-boot-brand.sh` checks the committed copy is byte-identical.

The stock `brand-illumos.4th`, `illumos-brand.png`, and the "powered by illumos" logo (`logo-illumos.4th`,
`illumos-logo.png`) are left as the gate ships them; `boot.loader.brand = "illumos"` gives the stock wordmark back.

`favicon.svg` is the solnix logo, a byte copy of the site's `site/favicon.svg` (solnix.io, infra team), sha256
576a703499b1d528abe272b2f33e7b3c731a2a6ca4f73f4c3d1b22345c66d4f9, copied 2026-11-03. If the site's logo changes,
copy it again and rebuild the PNG.
