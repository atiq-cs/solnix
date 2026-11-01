/*
 * rvsrv: lwIP options for the uts kernel. NO_SYS=1: lwIP runs on the raw
 * (callback) API under ONE kernel lock (inet.c netlock); no lwIP threads,
 * mailboxes or semaphores. IPv4 only: ARP, ICMP echo, UDP, TCP, DHCP client.
 * Memory is lwIP's own static heap + pools (MEM_SIZE), sized for a handful of
 * TCP connections with 8 KiB windows.
 */
#ifndef LWIP_LWIPOPTS_H
#define	LWIP_LWIPOPTS_H

#define	NO_SYS			1
#define	SYS_LIGHTWEIGHT_PROT	0	/* inet.c holds netlock around every call */
#define	LWIP_NETCONN		0
#define	LWIP_SOCKET		0
#define	LWIP_IPV4		1
#define	LWIP_IPV6		0
#define	LWIP_ARP		1
#define	LWIP_ETHERNET		1
#define	LWIP_ICMP		1
#define	LWIP_RAW		0
#define	LWIP_UDP		1
#define	LWIP_TCP		1
#define	LWIP_DHCP		1
#define	LWIP_ACD		0
#define	LWIP_DHCP_DOES_ACD_CHECK 0
#define	LWIP_AUTOIP		0
#define	LWIP_IGMP		0
#define	LWIP_DNS		0
#define	LWIP_STATS		0
#define	LWIP_NETIF_STATUS_CALLBACK 0
#define	LWIP_SINGLE_NETIF	1
#define	IP_REASSEMBLY		1
#define	IP_FRAG			1
#define	CHECKSUM_GEN_IP		1	/* no virtio-net csum offload negotiated */
#define	CHECKSUM_CHECK_IP	1

#define	MEM_ALIGNMENT		8
#define	MEM_SIZE		(512 * 1024)
#define	MEMP_NUM_PBUF		64
#define	MEMP_NUM_UDP_PCB	8
#define	MEMP_NUM_TCP_PCB	32
#define	MEMP_NUM_TCP_PCB_LISTEN	8
#define	MEMP_NUM_TCP_SEG	128
#define	MEMP_NUM_SYS_TIMEOUT	(LWIP_NUM_SYS_TIMEOUT_INTERNAL + 2)
#define	PBUF_POOL_SIZE		64
#define	PBUF_POOL_BUFSIZE	1536
#define	TCP_MSS			1460
#define	TCP_WND			(8 * TCP_MSS)
#define	TCP_SND_BUF		(8 * TCP_MSS)
#define	TCP_SND_QUEUELEN	(4 * TCP_SND_BUF / TCP_MSS)
#define	TCP_LISTEN_BACKLOG	1
#define	LWIP_TCP_KEEPALIVE	0
#define	TCP_QUEUE_OOSEQ		1
#define	LWIP_NETIF_HOSTNAME	0
#define	LWIP_NOASSERT		0
#define	LWIP_DEBUG		0

#endif	/* LWIP_LWIPOPTS_H */
