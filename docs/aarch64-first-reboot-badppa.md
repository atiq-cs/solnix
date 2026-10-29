# c6gd.metal: an API reboot can come back with no network (ena0 DL_BADPPA). Pre-existing in aa64h, not caused by aa64tls

**Track aa64tls, 2026-10-29. Status: a separate finding, measured; mechanism NOT identified.**

## Symptom

After `aws ec2 reboot-instances`, the box boots to `console login:`, but ena0 never attaches:

```
svc.startd: svc:/system/power:default: Method or service exit timed out.  Killing contract NN.
svc.startd: svc:/system/power:default: Method "/lib/svc/method/svc-power start" failed due to signal KILL.
ena0: DL_ATTACH_REQ failed: DL_BADPPA
ena0: DL_BIND_REQ failed: DL_OUTSTATE   (+ PHYS_ADDR, UNBIND)
```

The box has no network and ssh times out. The console shows no `ena0` attach messages at all. There are 0 `timed out waiting for admin` and 0 panics, so this is not the aa64h admin-queue bug. NVMe and instance-store devices attach normally.

## The control (c6gd.metal, us-west-2a, the same API reboot on both arms)

| | OLD aa64h f1 (kiwi ami-0d829adab130ea81c; raw 0709fc10 = solnix-ami us-east-1 ami-09bf62de40f951648) | NEW aa64tls m2 (ami-0ac943ea6bc027dc3) |
|---|---|---|
| boot after a fresh launch | 1/1 OK | 1/1 OK (and m1 v1 1/1: same kernel, same userland but man) |
| API reboot, first round | **1/1 BADPPA** (07:03Z, out/cold-API-reboot-BADPPA.txt) | **1/1 BADPPA** (07:03Z); m1 v1 **1/1 BADPPA** (05:49Z) |
| API reboot, rbctl3 rounds 1-4 | see out/cold-rbctl.log | see out/cnew-rbctl.log |
| system/power timeout | every reboot boot (power_to=1), with or without BADPPA | the same |

**One more API reboot recovers it,** measured on both arms: rbctl3 cycle 1 started from the BADPPA state.

The `system/power` service is byte-identical in the two images: svc-power sha 8cb5c712, /etc/power.conf 1211 B, the same exec. Only /lib/libc.so.1 (and ld.so.1 and libld) differ.

## What it is not, and what is open

- **Not aa64tls.** The old image fails the same way.
- **Not system/power alone.** Every reboot boot logs the power timeout, including the ones that come up with network.
- **Open:** what makes ena0's DLPI attach fail. The first round of reboots differs from the later ones in two ways:
  - The boxes had just come from a fresh launch, so this was the first warm reboot.
  - My first, broken loop fired 3 reboot-instances in about 3 minutes (06:44-06:47Z), so the reboots overlapped. v1 had a single reboot, ~1 h after launch, and failed too.
- The one-line rate: an API reboot that comes soon after a fresh launch fails 3/3 (v1, cold, cnew). Later reboots of the same boxes succeed 3/3 + 3/3. This needs more samples, and a test of whether the first warm reboot after a launch is the trigger.

## For dixa

dixa has been up since the aa64h launch. Its first API reboot falls exactly into the failing class. Expect to need a second reboot: read the console for DL_BADPPA at about 25 minutes, then send one more `reboot-instances`. Never stop/start: that wipes the instance-store `data` pool.

## 2026-10-29 11:40Z, orchestrator: first warm reboot after a fresh launch (rbfirst), result
The aa64tls agent was lost at a session reset after launching the test. Its run left .out files empty, so the result
comes from get-console-output (out/{fold,fnew}-rbfirst-console.txt):
- fold (OLD aa64h f1) i-034b13ba63046706d: DL_BADPPA, system/power timeout, no ssh, instance status impaired.
- fnew (NEW m2) i-0a81e96524aaa9e86: DL_BADPPA, system/power timeout, no ssh, instance status impaired.
Totals for the FIRST API reboot after a fresh launch: OLD 2/2 fail, NEW 3/3 fail. For later reboots on the same box: 8/8
OK (rbctl3). So: deterministic on the first reboot after launch, with no difference between the images, and one more
reboot recovers. Both instances were terminated after the consoles were saved.
