#!/usr/bin/env python3
# Fix scratch/current-system.nix: envSh via builtins.toFile with ${nix} fails
# (derivation-output context). Replace with a self-resolving login script that
# derives nix's runtime libs from /run/current-system/nix at login time (no
# build-time interpolation needed), written by the builder with a quoted heredoc.
import re, sys, shutil
p = "/var/tmp/solnix-nix/scratch/current-system.nix"
s = open(p).read()

# 1. drop the envSh = builtins.toFile "solnix-env.sh" '' ... ''; let-binding.
s2 = re.sub(r"\n  envSh = builtins\.toFile \"solnix-env\.sh\" ''.*?'';\n", "\n", s, flags=re.S)
if s2 == s:
    print("FATAL: envSh toFile block not found"); sys.exit(1)
s = s2
# 2. drop the `envSh = envSh;` derivation attr.
s = s.replace("\n  envSh = envSh;", "")

# 3. replace the cp line with a quoted heredoc (shell expands NOTHING; the
#    script resolves LD_LIBRARY_PATH from /run/current-system/nix at login).
old_cp = 'cp "$envSh"   "$out/etc/profile.d/solnix-env.sh"'
if old_cp not in s:
    print("FATAL: cp envSh line not found"); sys.exit(1)
# Inside a Nix '' string a literal ' pair '' would end it, so use a heredoc whose
# body has no '' and escape any ${ as ''${. The body below has no ${ or '' so it
# is safe verbatim in a Nix '' string.
new_cp = (
    "cat > \"$out/etc/profile.d/solnix-env.sh\" <<'PROFEOF'\n"
    "# solnix login environment (declarative). sw/bin first on PATH.\n"
    "export PATH=/run/current-system/sw/bin:$PATH\n"
    "export NIX_PROFILES=/nix/var/nix/profiles/default\n"
    "export NIX_PATH=nixpkgs=/dev/null\n"
    "# nix (nix.nix) needs its curated runtime-lib set; the current-system carries\n"
    "# a nix symlink alongside sw, so resolve its libs from there (self-contained,\n"
    "# no /nix-tools dependency).\n"
    "if [ -d /run/current-system/nix/runtime-lib ]; then\n"
    "  export LD_LIBRARY_PATH=/run/current-system/nix/runtime-lib:/run/current-system/nix/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}\n"
    "fi\n"
    "PROFEOF"
)
s = s.replace(old_cp, new_cp)

shutil.copyfile(p, p + ".bak2")
open(p, "w").write(s)
print("PATCHED OK")
print(s[s.index('args = [ "-c"'):])
