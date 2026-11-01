# lwip-objs.sh -- sourced by build-unix.sh / build-k1-payload.sh / build-k3-payload.sh / build-scanout.sh (rvsrv).
# Compiles lwIP 2.2.1 (BSD-3, vendored unmodified under lwip/; our port in lwip/port/) and inet.c with the
# caller's $CC $CFLAGS, and sets LWIPOBJS to the object list to link.
LWIPINC="-Ilwip/port -Ilwip/port/compat -Ilwip/include"
LWIPOBJS=""
for s in lwip/core/def.c lwip/core/inet_chksum.c lwip/core/init.c lwip/core/ip.c \
    lwip/core/mem.c lwip/core/memp.c lwip/core/netif.c lwip/core/pbuf.c \
    lwip/core/tcp.c lwip/core/tcp_in.c lwip/core/tcp_out.c lwip/core/timeouts.c \
    lwip/core/udp.c lwip/core/ipv4/acd.c lwip/core/ipv4/dhcp.c lwip/core/ipv4/etharp.c \
    lwip/core/ipv4/icmp.c lwip/core/ipv4/ip4.c lwip/core/ipv4/ip4_addr.c \
    lwip/core/ipv4/ip4_frag.c lwip/netif/ethernet.c lwip/port/libk.c; do
	o="lwip_$(basename "$s" .c).o"
	"$CC" $CFLAGS -Wno-unused-parameter -Wno-sign-compare $LWIPINC -c "$s" -o "$o"
	LWIPOBJS="$LWIPOBJS $o"
done
"$CC" $CFLAGS $LWIPINC -c inet.c -o inet.o
LWIPOBJS="$LWIPOBJS inet.o"
