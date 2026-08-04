# GATE A — declarative-Nix solnix AMI (extend bootable BE)
Started: $(date -u)

## Substrate
- OI build host: root@18.218.136.61 (i-015cdcda1fee421b1) — build toplevel+closure
- solnix-beef-boot: i-0e3f7de8ddb47b9e5 @ 18.116.63.79, scott@ (pfexec->root) — bootable minimal BE
- minimal AMI (known-good uefi/ena/hvm): ami-018e48f7b470c9788
- SG: sg-056af80635c09aa5b (devbox 73.4.58.126/32 ONLY)
- subnet: subnet-0dbc3dc75358df5d2, keypair: beef-key, profile: beef, region: us-east-2

## Progress log

### Mon Aug  3 06:29:53 PM UTC 2026 — toplevel/current-system BUILT
- REDUCED current-system (no systemPath/kernel — gate proto absent, target already boots):
  /nix/store/9yv48r2mqszy6ng90fwwg0p2vyvk9jjs-solnix-current-system
- starter pkgs: coreutils file gnugrep gnused bzip2 xz zlib pcre2 + nix 2.3.16
