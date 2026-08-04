#!/usr/bin/env python3
# Harden scratch/current-system.nix env.sh: resolve nix runtime libs from
# whichever current-system path form exists (/run/current-system slash OR
# /run-current-system hyphen), so LD_LIBRARY_PATH is set regardless of which
# symlink the installer created. Fixes nix-store 'not found' when only the
# hyphen form exists.
import re, sys, shutil
p = "/var/tmp/solnix-nix/scratch/current-system.nix"
s = open(p).read()

old = (
    "if [ -d /run/current-system/nix/runtime-lib ]; then\n"
    "  export LD_LIBRARY_PATH=/run/current-system/nix/runtime-lib:/run/current-system/nix/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}\n"
    "fi\n"
)
new = (
    "for _cs in /run/current-system /run-current-system; do\n"
    "  if [ -d \"$_cs/nix/runtime-lib\" ]; then\n"
    "    export LD_LIBRARY_PATH=$_cs/nix/runtime-lib:$_cs/nix/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}\n"
    "    break\n"
    "  fi\n"
    "done\n"
)
if old not in s:
    print("FATAL: env.sh LD_LIBRARY_PATH block not found"); sys.exit(1)
shutil.copyfile(p, p + ".bak3")
s = s.replace(old, new)
open(p, "w").write(s)
print("PATCHED OK")
print(s[s.index("PROFEOF"):s.index("PROFEOF")+400] if "PROFEOF" in s else "?")
