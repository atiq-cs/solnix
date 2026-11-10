#!/usr/bin/bash
# zero-checksum.sh <dir> <failfile> -- set DT_CHECKSUM to 0 in every ELF under <dir> that has one.
# illumos ld sums every alloc section into DT_CHECKSUM, $out's hash included (RUNPATH), and an unsandboxed
# `nix build --rebuild` / `nix-store --check` builds at a scratch out and rewrites only the hash STRING back,
# so the sum always differed (measured on jq/expat/gdbm, repro2 2026-10-30). GNU ld (NixOS) writes no
# DT_CHECKSUM; its only reader in the gate is libproc's file-vs-image match, which treats 0 like a match.
set -u
find "$1" -type f | while read -r f; do
  /usr/bin/elfdump -d "$f" 2>/dev/null | awk '$2=="CHECKSUM"{e=1} END{exit !e}' || continue
  chmod u+w "$f"; /usr/bin/elfedit -e 'dyn:value DT_CHECKSUM 0' "$f" || echo "elfedit checksum $f" >> "$2"
done
