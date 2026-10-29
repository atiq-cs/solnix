#!/bin/bash
# bh-proto.sh : on bh. New aarch64 proto = the banked proto (R2 ami/aarch64-proto-20260912, sha 40596bc1, gate 6cd2521c1e)
# with ONLY the three objects whose source aa64tls changed, from the t1 build: lib/libc.so.1 (libc diff), lib/ld.so.1
# (rtld diff; it also links libc_pic), lib/libld.so.4 (ld diff). Same layout as the banked tarball (root_aarch64/...).
# Out: /stage/proto-root_aarch64-aa64tls.tar.gz + .sha256. Log /stage/proto.log
exec >/stage/proto.log 2>&1
set -eux; date
cd /stage; N=/stage/nproto; [ -d $N ] && find $N -depth -delete; mkdir -p $N
gzip -dc proto-root_aarch64.tar.gz | (cd $N && tar xpf -)
for f in lib/libc.so.1 lib/ld.so.1 lib/libld.so.4; do
  ls -l $N/root_aarch64/$f; cp x1/$f $N/root_aarch64/$f; chmod 755 $N/root_aarch64/$f; chown root:bin $N/root_aarch64/$f
  cmp x1/$f $N/root_aarch64/$f; done
digest -a sha256 $N/root_aarch64/lib/libc.so.1 $N/root_aarch64/lib/ld.so.1 $N/root_aarch64/lib/libld.so.4
cd $N && tar cf - root_aarch64 | gzip -9 > /stage/proto-root_aarch64-aa64tls.tar.gz
cd /stage; digest -a sha256 proto-root_aarch64-aa64tls.tar.gz | tee proto-root_aarch64-aa64tls.tar.gz.sha256
ls -l proto-root_aarch64-aa64tls.tar.gz; echo PROTO_OK; date
