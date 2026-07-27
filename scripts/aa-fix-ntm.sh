#!/bin/ksh93
# aa-fix-ntm.sh — the proto-only image booted to a panic "Couldn't find major
# number for 'rootnex'": the gate proto's /etc/name_to_major has only 4 entries
# (pkg install would normally assemble the full table; we skipped pkg). This
# generates a name_to_major covering EVERY driver binary in the aarch64 proto,
# reusing the (arch-independent) major numbers from the amd64 host's own
# /etc/name_to_major and assigning fresh high majors to arm-only drivers.
# Then it re-stages the root + rebuilds the boot_archive + re-lays the disk.
#
# This is an EXPLORATORY probe to find the NEXT boot stop point beyond rootnex.
set -e
PROTO=/aarch64/arm64-gate/illumos-gate/proto/root_aarch64
HOSTNTM=/etc/name_to_major
OUT=/aarch64/out
NTM=$OUT/name_to_major.aarch64

echo "=== generate name_to_major covering all proto drivers ==="
# All driver binary names present in the aarch64 proto (platform + kernel).
{ ls $PROTO/platform/armv8/kernel/drv/aarch64/ 2>/dev/null
  ls $PROTO/kernel/drv/aarch64/ 2>/dev/null ; } | sort -u > /tmp/aa-drivers.txt
echo "proto drivers: $(wc -l < /tmp/aa-drivers.txt)"

# Start from the host's arch-independent majors for names that also exist here.
: > $NTM
MAXM=0
while read drv; do
  m=$(/usr/gnu/bin/grep -w "^$drv" $HOSTNTM 2>/dev/null | awk '{print $2}' | head -1)
  if [ -n "$m" ]; then
    echo "$drv $m" >> $NTM
    [ "$m" -gt "$MAXM" ] && MAXM=$m
  fi
done < /tmp/aa-drivers.txt

# Assign fresh majors (above the host max) to proto drivers the host lacks
# (arm-only: rootnex is on the host, but gictwo/arm_gtmr/ns16550a/simple-bus/
# devfdt/efifb/gicthree/gicv2m/gicv3_its etc are aarch64-specific).
next=$((MAXM + 1))
while read drv; do
  if ! /usr/gnu/bin/grep -qw "^$drv" $NTM; then
    echo "$drv $next" >> $NTM
    next=$((next + 1))
  fi
done < /tmp/aa-drivers.txt

# rootnex MUST be present (the panic). Verify.
/usr/gnu/bin/grep -qw '^rootnex' $NTM || { echo "FATAL: rootnex still missing" >&2; exit 1; }
echo "name_to_major entries: $(wc -l < $NTM)  (rootnex -> $(/usr/gnu/bin/grep -w '^rootnex' $NTM | awk '{print $2}'))"
sort -k2 -n $NTM | tail -15

echo "=== also generate a minimal driver_aliases (bind arm platform drivers) ==="
# The devicetree binds drivers by 'compatible' string. The port's platform
# drivers key off DT compatible names. Add the essential aarch64 bindings so
# rootnex/simple-bus/gic/timer/uart attach. (Best-effort; the port's own
# driver .conf + built-in aliases cover most; we seed the obvious ones.)
DA=$OUT/driver_aliases.aarch64
cat > $DA <<'EOF'
asy "pci11c1,480"
ns16550a "arm,pl011"
ns16550a "ns16550a"
ns16550a "arm,sbsa-uart"
gictwo "arm,cortex-a15-gic"
gictwo "arm,gic-400"
gicthree "arm,gic-v3"
arm_gtmr "arm,armv8-timer"
arm_gtmr "arm,armv7-timer"
simple-bus "simple-bus"
efifb "simple-framebuffer"
viommionex "virtio,mmio"
viommionex "virtio-mmio"
EOF
echo "driver_aliases entries: $(wc -l < $DA)"

# vioblk/vioif bind to viommionex CHILDREN via viommionex.conf's device-N-compat
# (virtio-mmio,1,blk / virtio-mmio,1,net). Those aliases must ALSO be in
# driver_aliases so the child nodes bind. Add them.
cat >> $DA <<'EOF'
vioblk "virtio-mmio,1,blk"
vioif "virtio-mmio,1,net"
viorand "virtio-mmio,1,entropy"
vio9p "virtio-mmio,1,9p"
EOF
echo "driver_aliases entries (with virtio children): $(wc -l < $DA)"
echo "NTM-OK"
