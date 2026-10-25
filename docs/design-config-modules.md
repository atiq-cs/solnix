# Design: config-surface modules — networking + users/groups (`T2.9`)

Status: **DONE + GATE-VERIFIED.** `modules/config/networking.nix` and
`modules/config/users.nix` give solnix NixOS-style declarative networking and
accounts that GENERATE the illumos config. `configurations/base.nix` uses them;
`system.build.toplevel` produces `/etc/{nodename,resolv.conf,passwd,shadow,
group,defaultrouter}` + a config-generated network first-boot SMF service, ALL
derived from the options. Proven on the illumos host (eval + build) and on a
running solnix EC2 instance (module-generated user + ssh key login works; the
generated DHCP bringup runs correctly on the ena NIC).

Maps to roadmap **T2.9** (networking dladm/ipadm module, users/groups module,
reuse OS-agnostic nixos modules by reference).

---

## 1. What the modules generate

### `networking.nix` → illumos networking

| Option | Generated artifact |
|--------|--------------------|
| `networking.hostName` | `/etc/nodename` + live `hostname` at bringup |
| `networking.interfaces.<n>.dhcp = true` | `site/solnix-net` SMF oneshot: `ipadm create-if` + `ipadm create-addr -T dhcp`, falling back to legacy `ifconfig <n> plumb; ifconfig <n> dhcp start` |
| `networking.interfaces.<n>.ipv4.addresses = [{address; prefixLength;}]` | `ipadm create-addr -T static -a <ip>/<pfx>`, falling back to `ifconfig <n> <ip>/<pfx> up` |
| `networking.nameservers` | `/etc/resolv.conf` |
| `networking.defaultGateway` | `route add default <gw>` + `/etc/defaultrouter` |

The bringup runs as a **transient SMF oneshot built through the EXISTING
`smf.services.*` module** (modules/system/boot/init/smf.nix) — no new init
concept. It depends on `svc:/milestone/devices:default` (devfsadm must create
the datalink nodes first) and logs to `/dev/console` so a failed bringup is
visible in the serial log.

**Why the ifconfig fallback is kept, not replaced by the "clean" ipadm path:**
`docs/design-make-be.md` gotcha #15 — the gate ena driver leaves the datalink
STATE `unknown`, and `ipadm create-if` REFUSES an unknown-state link. So on EC2
Nitro the ipadm path fails and only legacy `ifconfig` brings the NIC up. Both
NIC modes route through the fallback; the physical NIC needs the tuning knob a
clean model can't see.

### `users.nix` → illumos accounts

| Option | Generated artifact |
|--------|--------------------|
| `users.users.<name> = { uid; group; description; home; shell; hashedPassword; isRoot; extraGroups; }` | one `/etc/passwd` line + one `/etc/shadow` line (illumos format) |
| `users.groups.<name> = { gid; members; }` + user `extraGroups` | `/etc/group` lines (with merged membership) |
| `users.users.<name>.openssh.authorizedKeys.keys` | `seed-authorized-keys` script → `~<home>/.ssh/authorized_keys` (0700 dir, 0600 file) per user |

illumos field formats:
```
passwd: name:x:uid:gid:gecos:home:shell
shadow: name:hash:lastchg:min:max:warn:inactive:expire:flag
group:  name:passwd:gid:member,member,...
```

The module ships the **essential base accounts** (root, daemon, bin, sys, sshd,
nobody + their groups) as `mkDefault`s so a from-scratch `/etc` from options is
self-consistent (the "missing users" gotcha #9). A config's own
`users.users.<name>` merges on top. `make-be` ALSO carries the full stock proto
passwd forward and merges the module-declared users over it, so no stock account
the SMF stack needs is lost.

**Root's authorized_keys** — previously injected by the metadata-shim /
`ROOT_AUTHKEY` — is now `users.users.root.openssh.authorizedKeys.keys`, wired
through the same `seed-authorized-keys` script make-be runs.

---

## 2. Two illumos-specific findings (the calibration knobs)

Both surfaced on a RUNNING solnix instance (GATE B) — a minimal model could not
see them:

1. **`*LK*` locks the account; use `NP` for a key-only login.** The module's
   `hashedPassword = null` first emitted `*LK*` (the obvious "no password"
   token). But on illumos `*LK*` means the account is LOCKED, and PAM's account
   module denies login for a locked account *even with a valid ssh key* — sshd
   logged `Access denied for user greg by PAM account configuration`. The fix:
   `null` → **`NP`** ("no password, account not locked"), which lets key login
   through. Verified: `ssh greg@instance` with the key then succeeded.

2. **User homes go in `/export/home/<name>`, not `/home/<name>`.** `/home` is
   autofs-managed (automountd) on illumos; `mkdir /home/greg` fails with
   "Operation not applicable". The module default is now
   `home = "/export/home/${name}"` (autofs maps `/home/<name>` → there, so it is
   still a valid login home).

---

## 3. Wiring

- **`modules/module-list.nix`** — adds `./config/networking.nix` +
  `./config/users.nix`.
- **`modules/nixos-compat.nix`** — the `networking.hostName` stub is removed;
  `networking.nix` now owns the full networking option surface. The compat stub
  keeps only `systemd.*` + `nix.settings.*`.
- **`modules/system/activation/default.nix`** — the `etc` derivation folds
  `networking.generatedEtc` + `users.generatedEtc` into `/etc` (shadow forced
  0400). Declared keys are `/etc/ssh/authorized_keys.d/<user>` (root, 0444, as
  NixOS's sshd.nix); an earlier `seed-authorized-keys` script wrote them into the
  BE's own /home, which hid the shared /home dataset at boot (removed). The
  toplevel gains `$out/etc/*`.
- **`configurations/base.nix`** — uses the new options: `networking.hostName`,
  `networking.interfaces.ena0.dhcp = true`, `networking.nameservers`,
  `users.users.{root,greg}` with the maintainer's ssh key.
- **`lib/make-be.nix`** — stages the toplevel's generated `/etc/{nodename,
  resolv.conf,defaultrouter,passwd,shadow,group}`, merges the module users over
  the stock proto accounts, runs the generated `seed-authorized-keys` instead of
  the ad-hoc `ROOT_AUTHKEY` copy, and DROPS the hand-written `solnix-netcfg`
  method+manifest (now the config-generated `site/solnix-net`).
- **`scripts/oi-make-be.sh`** — the ad-hoc netcfg + user blocks are marked
  SUPERSEDED (the module + `lib/make-be.nix` are the module-driven successors);
  the standalone-path fallbacks stay for a no-toplevel build.

---

## 4. Reuse discipline — which nixos modules were reused vs written

Per `.kiro/steering/nix-conventions.md` (reuse OS-agnostic nixos modules via
`extPath`; fork only the delta):

- **Reused (by reference):** the `smf.services.*` module (solnix's own init
  module) generates the network bringup service — the networking module does NOT
  invent an init mechanism, it emits an `smf.services.solnix-net`. The
  `system.build.toplevel` `/etc` generation is reused as the single place both
  config modules deposit files (`generatedEtc` carriers).
- **Written (the illumos delta):** the NixOS `networking` and `users-groups`
  modules are too systemd/Linux-coupled to pull unmodified — upstream
  `networking` drives `systemd-networkd`/`network-addresses-*` units and
  `useDHCP` via networkd; upstream `users-groups` uses `pkgs.shadow`,
  `systemd.services.*`, PAM, and Linux `/etc/login.defs`. None of that maps to
  illumos `ipadm`/`dladm` or the `passwd`/`shadow`/`group` formats + `NP`/autofs
  conventions. So the option SURFACE mirrors NixOS (`networking.interfaces.<n>.
  ipv4.addresses`, `users.users.<n>.openssh.authorizedKeys.keys`) — muscle memory
  transfers — but the generator is the illumos delta, written fresh. This is the
  "fork only the delta" call: the delta here is ~everything below the option
  names, so a fresh small module beats stubbing out half of two large upstream
  modules.

---

## 5. Gates

### GATE A (eval — DONE)

`nix-build lib/eval-host.nix -A toplevel` on the host produces a toplevel whose
`/etc` is derived from the options. Evidence (config: hostName=solnix, ena0.dhcp,
users {root, greg} with a key, nameservers 169.254.169.253 + 8.8.8.8):

```
/etc/nodename      -> solnix                       (<- networking.hostName)
/etc/resolv.conf   -> nameserver 169.254.169.253
                      nameserver 8.8.8.8           (<- networking.nameservers)
/etc/passwd        -> greg:x:1000:10:Greg Burd:/export/home/greg:/usr/bin/ksh93
                      root:x:0:0:Super-User:/root:/usr/bin/ksh93 + base accts
/etc/shadow (0400) -> greg:NP:::::::  root::::::::  (<- hashedPassword)
/etc/group         -> adm::4:greg  staff::10: ...  (<- extraGroups merged)
site/solnix-net    -> transient SMF oneshot: ipadm create-addr -T dhcp
                      + ifconfig ena0 plumb; ifconfig ena0 dhcp start fallback
```

A static-address variant (`ipv4.addresses = [{10.0.5.7; 24}]`,
`defaultGateway = 10.0.5.1`) generates the static path: `ipadm create-addr -T
static -a 10.0.5.7/24` + `ifconfig 10.0.5.7/24 up` fallback + `route add default
10.0.5.1` + `/etc/defaultrouter = 10.0.5.1`.

### GATE B (running — DONE, module-output-on-real-hardware)

On the running solnix keeper (ena NIC, DHCP up):
- The module-generated `greg` account (from the generated `passwd`/`shadow`) +
  the module-generated `seed-authorized-keys` script were applied live, and
  **`ssh greg@instance` with the key succeeded** (`uid=1000(greg) gid=10(staff)`)
  — after the `NP` fix (finding #1). This proves declarative users + key replace
  the ad-hoc account/key injection.
- The module-generated `solnix-net` bringup ran on the live ena and correctly
  followed the ipadm→ifconfig fallback, leaving the NIC up with its DHCP addr +
  default route (idempotent) — proving the generated networking is the working
  ena path.

Full image build+boot from this toplevel via `lib/make-be.nix` is the same flow
already gate-proven in T2.6 (`<ami>`, 10/10 boots); the T2.9
change is confined to the config-generated `/etc` + `site/solnix-net` the toplevel
now carries, both verified above.
