# compat-illumos/

`sys/mac_wifi.h` copied verbatim from illumos-gate `usr/src/uts/common/sys/mac_wifi.h`
(gate checkout cd9ea253fe43, file last changed in bbf215553c72 (2022-03-10); CDDL, header retained).
The gate does not install it into the proto's `usr/include` (measured: absent from
`/nix/store/s7zkx8nx...-illumos-gate-proto/usr/include/sys` on dixi), because only the
mac_wifi plugin and in-gate wifi drivers include it, through `-I$(UTSBASE)/common`.
It defines the wifi plugin's `wifi_data_t` and `MAC_PLUGIN_IDENT_WIFI`, which a
GLDv3 wifi driver passes to `mac_register`. Only `iwm_gld.c` includes it.
