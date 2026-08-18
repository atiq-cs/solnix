# solnix desktop cold-launch network — investigation + honest verdict

## TL;DR (verdict = (b))
The DHCP-failure mode was addressed, but a fresh cold launch still does NOT
reliably SSH in. Root cause of the remaining failures is the **ena data path**
(link enumerates, but no packets flow on many cold boots) — that is the ena
DRIVER, NOT something the metadata shim can fix. Static-IP-from-IMDS is
architecturally impossible to bootstrap here (see below), and DHCP / reboots
are non-deterministic on the affected instances.

## AMIs built (all from the failing desktop AMI ami-000a59cf344644604 /
## snapshot snap-05edfce498172fc2e)
- v2  ami-03081d83a7d0bd410  clean single-addrobj DHCP, keep-lease, no reboot
- v3  ami-0870478cf2ea34604  + bounded reboot on DHCP loss
- v4  ami-095543f0de750dc33  + static-from-DHCP-OFFER (dhcpinfo) recovery, bounded reboot  <-- latest
(v1 ami-0d91ba781fc5e637f was an early cut; superseded.)

## What was PROVEN (verified on live cold instances)
1. ipfilter breaks the IMDSv2 token PUT: the shipped default-deny ruleset
   ("pass out ... keep state; block in log all") drops the token-PUT response
   even though the outbound state should allow it. VERIFIED: token PUT times
   out (code 000, 6s) with ipf on; adding
     pass in quick proto tcp from 169.254.169.254 to any keep state
   makes it return a 56-char token. (Baked into the shim + ipf.conf.)
2. STATIC-IP-FROM-IMDS CANNOT BOOTSTRAP. EC2 IMDS at 169.254.169.254 only
   answers packets sourced from the instance's REAL VPC private IP. A
   self-assigned link-local (169.254.x.y) is REJECTED — VERIFIED:
     curl --interface <link-local> PUT .../api/token  -> code 000 (timeout)
     same request sourced from the real DHCP IP        -> code 200 (0.008s)
   So to query IMDS for the IP you must already have the IP: chicken-and-egg.
   IMDS is therefore NOT a usable bootstrap when DHCP has not produced an IP.
3. In-OS DHCP recovery does not work: ipadm delete/create-addr, refresh-addr,
   restart network/physical, aggressive multi-attempt re-DHCP all leave a
   wedged dhcpagent wedged. Only a fresh boot yields a fresh negotiation.
4. Fresh-boot DHCP is a genuine dice-roll and frequently FAILS on the ena
   link: multiple fresh cold batches produced 0/3 and 4/4 failures as well as
   some successes — high variance, not deterministic.
5. On the FAILING boots dhcpagent gets NO OFFER at all (dhcpinfo Yiaddr empty,
   console shows "Hostname: unknown" and IPv4LL 169.254.0.1 autoconf). No
   OFFER => nothing for the static-from-OFFER path to use, and reboots do not
   help because the ena data path stays dead across boots. This is the ena
   DRIVER / a deeper Nitro-ena issue, not the shim.

## What the v4 shim now does (scripts/metadata-shim.sh)
- Collapses any dual DHCP addrobj to a single ena0/dhcp (idempotent).
- Adds the ipf IMDS pass rule (persistent + live reload).
- Waits ~100s for a DHCP lease; if it lands, ensures the deterministic default
  route (gateway = subnet base + 1 of the /prefix) and is done.
- If no lease: reads the DHCP server's OFFER via `dhcpinfo` (Yiaddr/Subnet/
  Router) and configures it STATICALLY — deterministic when an OFFER exists.
- If there is no OFFER at all (dead ena data path): bounded reboot (cap 4) for
  a fresh dice-roll; a host that never gets an OFFER after the cap has a dead
  ena data path and must be RELAUNCHED (hardware lottery).

## Honest blocker
The shim removes every failure mode that is fixable in software (dual-addrobj,
missing route, ipf-blocked IMDS, wedged-agent detection, OFFER-based static
recovery). The dominant remaining failure is the ena data path producing no
packets on a cold boot — no DHCP OFFER, no IMDS, unrecoverable in-OS and
often across reboots. That is the ena driver, not the metadata shim. The
deterministic fix belongs in the ena driver (or use an instance/AMI combo
whose ena path is reliable), not in /usr/lib/metadata.

## Cost hygiene
All throwaway cold-launch test instances and the ZFS-patch helper were
terminated; the patch EBS volume was deleted. Only the 3 m5.4xlarge build
nodes + the pre-existing wasm-emcc-builder remain.
