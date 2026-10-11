/* iwx compat: OpenBSD-style struct sockaddr_dl, absent from illumos net/if_dl.h path used here. */
#ifndef _IWX_COMPAT_NET_IF_DL_H
#define _IWX_COMPAT_NET_IF_DL_H
struct sockaddr_dl { unsigned char sdl_len, sdl_family, sdl_stub[46]; };
#endif
