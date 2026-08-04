#!/usr/bin/env python3
# Fix scratch/current-system.nix nix.conf: task directive endpoint + pubkeys.
# cache.solnix.io (durable, pubkey 8UNrVA...) + cache.nixos.org fallback.
import re, sys, shutil

p = "/var/tmp/solnix-nix/scratch/current-system.nix"
s = open(p).read()

# Match the whole nixConf = builtins.toFile "nix.conf" '' ... ''; block.
m = re.search(r"nixConf = builtins\.toFile \"nix\.conf\" ''.*?'';", s, re.S)
if not m:
    print("FATAL: nixConf block not found"); sys.exit(1)

new = (
    "nixConf = builtins.toFile \"nix.conf\" ''\n"
    "    # solnix declarative image: durable public cache first, nixos.org fallback.\n"
    "    substituters = https://cache.solnix.io https://cache.nixos.org\n"
    "    trusted-public-keys = cache.solnix.io-1:8UNrVAOSOrI9PGHc8/pD2Yqp265ZeYb3OId+gv4+wm8= cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=\n"
    "    sandbox = false\n"
    "    build-users-group =\n"
    "    max-jobs = auto\n"
    "  '';"
)
if m.group(0) == new:
    print("ALREADY UP TO DATE"); sys.exit(0)
shutil.copyfile(p, p + ".bak")
s = s[:m.start()] + new + s[m.end():]
open(p, "w").write(s)
print("REPLACED OK")
# echo the new block for verification
m2 = re.search(r"nixConf = builtins\.toFile \"nix\.conf\" ''.*?'';", open(p).read(), re.S)
print(m2.group(0))
