# netbt in userland: status (phase 1 P4/P5, bluetooth-phase1-plan.md §6-§7)

`hcitest` runs NetBSD's netbt HCI core (hci_unit, hci_event, hci_misc, hci_link,
hci_ioctl, unmodified) in one userland process, over bt1's ugen transport or a recorded
transcript. "Up" is btconfig's path: `SIOCSBTFLAGS` with `BTF_UP` into `hci_ioctl_pcb`,
which runs `hci_enable`. The inquiry is libbluetooth `bt_devinquiry`'s, in RSSI mode.

| piece | state | notes |
|---|---|---|
| hci_unit/hci_event/hci_misc/hci_ioctl | REAL (upstream) | init sequence, Command Status/Complete, inquiry results into the memo cache, SIOCGBTINFO/SIOCSBTFLAGS/SIOCGBTFEAT |
| hci_link | REAL code, unreached | no ACL/SCO link is made in phase 1; an incoming connection is refused because there is no L2CAP listener (upstream behaviour) |
| mbufs | REAL | BSD semantics, unit-tested over chain boundaries |
| mutex / cv / softint | REAL for one thread | lock use is checked (abort on recursion or exit-unheld); no concurrency is exercised. The kernel flavour (P6) maps cv_timedwait_sig to cv_reltimedwait_sig |
| callout, pool | STUB (abort) | only ACL links arm a callout or take an L2CAP PDU |
| L2CAP / SCO functions | STUB (abort) | stubs.c; the lists are real and empty |
| hci_drop | STUB (abort) | raw-socket sockbuf accounting; no socket here |
| hci_mtap | REAL, socket replaced | the tap feeds hcitest's inquiry parser instead of an HCI socket |
| kauth | allow | userland runs under pfexec; the kernel flavour uses secpolicy_net_config |
| Intel bootloader gate | REAL | in the enable hook: refuses with ENODEV (not EAGAIN: on illumos EAGAIN == EWOULDBLOCK, which is hci_enable's own init timeout) unless 0xfc05 reports image type 0x03; no HCI_Reset is sent |
| ugen transport | REAL (bt1) | with the interrupt-IN toggle reset at open; `-C` skips it |

## Tests (chef, and in the Nix build)

* `hcitest -t`: mbuf chain tests, transcript scrubber tests.
* `run-fixtures.sh`: each `fixtures/*.hcx` replayed into the core, plus six sabotaged
  copies whose outcome was written down before the first run (bt3 progress.txt step 25-29):
  N0 bootloader image -> refused, 0 commands sent; N1 an event with a bad length -> dropped
  by hci_event, no credit returns, init times out (EWOULDBLOCK); N2 inquiry Command Status
  0x0c -> refused; N3 no results -> 0 devices; N4 one device's results removed -> N-1;
  N5 Command Complete for the wrong opcode -> init never finishes; N6 the transcript expects
  another command -> the fixture fails (proves the matcher can fail).
* `negative-controls.sh`: 8 sabotages of the shims and harness; each must fail one of the above.

## Transcripts

`xport_fixture.c` describes the format. `rec.c` writes one from a live run (`-W`), scrubbed
as it is written: remote addresses keep their OUI and get a per-device index, EIR data and
the parameters of unrelated events are zeroed. `spec-up-inquiry.hcx` is synthetic (from the
spec and hci_event.c, made-up addresses). A transcript recorded on lixi is added once lixi
can be used.

## Known gaps

* One thread: the lock order between bt_lock and a driver's softc lock (plan §6) is not tested here.
* No HCI socket, no btconfig: those are P7/P8.
* LE events and Intel vendor events (0xff) are dropped by hci_event, as in NetBSD; `hcitest`
  prints the event codes it saw so a missing one can be told apart from a dropped one.
