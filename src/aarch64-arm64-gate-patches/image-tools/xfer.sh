#!/usr/bin/ksh93
# WHAT: transfer the 8G bootable image to the Linux arm64 helper's raw EBS volume.
# WHY this shape: gzip over ssh into the helper's dd runs ~87MB/s, whereas a raw
# dd from illumos to EBS runs ~1MB/s AND the illumos disk-probe path wedges. The
# image is mostly empty so gzip shrinks the wire transfer enormously.
export PATH=/usr/gnu/bin:/usr/bin:/usr/sbin:/bin
IMG=/aarch64/arm64-gate/qemu-setup/illumos-disk.img
HELPER=172.31.44.88
gzip -c "$IMG" | ssh -o StrictHostKeyChecking=no -o ConnectTimeout=20 \
    ec2-user@$HELPER 'gunzip | sudo dd of=/dev/nvme1n1 bs=1M status=none && sudo sync'
echo "=== XFER_RC=$? ==="
