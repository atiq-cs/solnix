# netbt (userland, phase 1 P4/P5): provenance and licence

## Vendored, unmodified (`upstream/netbt/`, read-only)

NetBSD `sys/netbt` at NetBSD src trunk 26c769bcf6ba (git mirror, 2026-11-01).
Licence: BSD (Iain Hibbert 2005; Itronix Inc. 2006; Maksim Yevmenkin 2001-2003 in hci.h,
l2cap.h, rfcomm.h). Each file keeps its own copyright block. `grep -c 'advertising materials'` is 0 on
every file: there is no advertising clause. No GPL. Linux btusb, btintel and BlueZ were
not read.

| file | lines | $NetBSD$ revision | sha256 |
|---|---|---|---|
| hci_unit.c | 579 | 1.16 2021/08/07 | 3d44eb7e7d162c5981d4acd9f77490e2ba3eb9ed4c09b4e51ce0d23b3044e6de |
| hci_event.c | 1331 | 1.26 2019/09/28 | 6e3d1e2d6329f24192a071808d328fae0edd9f54cf57de96c0532b5d59e1e959 |
| hci_misc.c | 183 | 1.4 2021/11/22 | 15b8ead44f60328d0deaa32f15338cee4d177c2ecdcc6e2a56c21eb29b5edcb6 |
| hci_link.c | 1061 | 1.27 2024/07/05 | d822f80dfda40ba87042d85ea81fd8ea85fd32d4118f3692fb96f930fa12fd87 |
| hci_ioctl.c | 325 | 1.15 2021/09/21 | 687fdb984f33df06dc294a85ccb44c5a6a2f842ad3a288139c2595cde1196693 |
| hci.h | 2631 | 1.47 2025/08/19 | bc47865c76062a1573898a4e735b66f6924bb8287da461be0a03357489d25fd8 |
| bluetooth.h | 161 | 1.12 2014/05/18 | f1050c82b52010c6977b239ed3ac5a4927daf11436cf67206ed30d6bc26e92f4 |
| l2cap.h | 484 | 1.19 2015/11/28 | 53fc489c983ab8b764a02847f1b29e4aa6f591b17dc0df1c8ac0e3418ae472c6 |
| sco.h | 85 | 1.11 2014/08/05 | 9f84f364a28deae8d068eee384949a84edf300127eab398cd27ce3d720462bc1 |
| rfcomm.h | 425 | 1.20 2025/09/07 | 74643a64346e84e64e87dfe512566f99744f490d018b1d7661a38d33054a58b1 |

No upstream file is edited and there is no patch file: everything the core needs from the
platform comes from the shims below. (l2cap.h, sco.h and rfcomm.h are only compiled for
the struct and list declarations hci_link.c and hci_ioctl.c name.)

Also used, unmodified: FreeBSD `iwmbtfw/iwmbt_fw.c` (`iwmbt_parse_tlv`, for the bootloader
gate) and bt1's ugen transport, both from `../iwmbtfw` (see ../iwmbtfw/PROVENANCE.md).

## New solnix code (CDDL-compatible; no NetBSD code copied outside upstream/)

* `compat/kshim.h`, `compat/kshim2.h`: the NetBSD KPI the core names (malloc/free with
  types, mutex/cv, softint, callout, pool, kauth, device_xname, config_found,
  aprint_error_dev, KASSERT), as macros over `kshim.c`. Also a corrected
  `SIMPLEQ_REMOVE_AFTER`: the illumos `<sys/queue.h>` one passes one argument to
  `SIMPLEQ_NEXT` and does not compile.
* `compat/kern/sys/*.h`: empty shadows of NetBSD-only headers; `sys/mbuf.h` -> `compat/mbuf.h`.
* `compat/mbuf.h`, `mbuf.c`, `mbuf_ops.c`, `mbuf_test.c`: a small BSD mbuf (MLEN 64, so
  real events span chains in the tests) and its unit test.
* `kshim.c`: one-thread KPI. Mutexes are held flags that abort on misuse; `cv_timedwait_sig`
  runs the event pump until a broadcast or the deadline. callout/pool are STUB (abort).
* `core.c`, `core_io.c`, `core.h`: the `hci_if` a ubt driver gives netbt (enable = transport
  open + Intel gate; output_cmd strips the H4 byte, as NetBSD ubt.c does), `hci_mtap` (the
  raw-socket tap, replaced by a function pointer) and `hci_drop` (STUB).
* `stubs.c`: STUB L2CAP/SCO functions hci_link.c names, and their real, empty lists.
* `gate.c`: Intel Read Version (0xfc05) through the transport; refuses unless image type
  0x03 (FreeBSD ng_ubt_intel.c's rule, reimplemented, no code copied).
* `xport.h`, `xport_ugen.c`, `xport_fixture.c`, `rec.c`: transports (ugen, a transcript
  replayer with a virtual clock, a tee that records a scrubbed transcript).
* `raw.c`: a recorder that does not use the core (an independent reading of the init order).
* `hcitest.c`, `hcitest.h`, `scrub_test.c`, `run-fixtures.sh`, `negative-controls.sh`,
  `fixtures/*.hcx`, `Makefile.illumos`.
