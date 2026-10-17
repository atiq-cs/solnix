# lib-core-scrub.sh — remove stray core files + set the coreadm policy in a BE root.
# Sourced by the image builders before snapshot/media assembly so no build-time
# core dump ever ships (no core files in images/first-run systems).
# Usage: BEROOT=/path/to/be/root scrub_cores
scrub_cores() {
  local r="${1:-${BEROOT:?set BEROOT}}"
  # 1. delete every stray core file in the image (build-time crashes leave these).
  # NOTE: no -xdev — /export/home and other child datasets are separate ZFS
  # filesystems; -xdev would skip them and leave cores behind (the v3 image bug).
  # The grep finds nothing when there are no cores (the normal case) and exits 1,
  # which under a caller's pipefail aborted the whole image build here.
  find "$r" -type f -name core -exec file {} \; 2>/dev/null | { grep -i "core file" || true; } | cut -d: -f1 | while read -r c; do
    rm -f "$c" && echo "  scrubbed core: ${c#$r}"
  done
  # also the classic 'core' + core.<pid> patterns without the file(1) check (belt+braces)
  find "$r" \( -name 'core' -o -name 'core.[0-9]*' \) -type f -delete 2>/dev/null || true
  # 2. ensure the managed cores dir exists + persist the coreadm policy
  mkdir -p "$r/var/cores"; chmod 1777 "$r/var/cores" 2>/dev/null || true
  cat > "$r/etc/coreadm.conf" <<EOF
COREADM_GLOB_PATTERN=/var/cores/core.%f.%p.%t
COREADM_GLOB_CONTENT=default
COREADM_INIT_PATTERN=/var/cores/core.%f.%p.%t
COREADM_INIT_CONTENT=default
COREADM_GLOB_ENABLED=yes
COREADM_PROC_ENABLED=no
COREADM_GLOB_SETID_ENABLED=no
COREADM_PROC_SETID_ENABLED=no
COREADM_GLOB_LOG_ENABLED=yes
EOF
  echo "  coreadm policy written; cores routed to /var/cores (no CWD litter)"
}
