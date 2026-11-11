# Design: SMF init module (`smf.services.*`)

Status: design, Phase 1. Maps to roadmap **T1.11** (`smf.services.<name>` →
manifest XML + method script generator) and **T1.12** (activation: `svccfg
import` + `svcadm` to target milestone). Requirements R6.1–R6.3, design note D5.

This is the solnix analog of nixbsd's
`modules/system/boot/init/freebsd-rc.nix`. Where nixbsd renders `rc.conf` +
`/etc/rc.d` scripts and drives them through FreeBSD `rc`, solnix renders **SMF
XML manifests** + **method scripts** and drives them through **`svc.startd` /
`svc.configd`** via `svccfg`/`svcadm`.

`VERIFY` tags mark facts to confirm against a live OpenIndiana Hipster 2025.06
system before relying on them.

---

## 0. Ground truth recap

- Service = **FMRI** `svc:/<category>/<name>:<instance>`, e.g.
  `svc:/system/sshd:default`.
- A **manifest** is XML under `/lib/svc/manifest/<category>/<name>.xml`
  conforming to `service_bundle.dtd.1`
  (`/usr/share/lib/xml/dtd/service_bundle.dtd.1`).
- Method scripts live under `/lib/svc/method/`.
- `svc:/system/manifest-import:default` scans the manifest dirs at boot and
  imports anything new/changed; `svccfg import <file>` does it explicitly.
- **Milestones** are pseudo-services: `svc:/milestone/single-user`,
  `.../multi-user`, `.../multi-user-server`. The Phase 1 gate target is
  `multi-user-server`.
- Repository lives in SQLite at `/etc/svc/repository.db`, owned by
  `svc.configd`.

The whole design leans on one asymmetry with NixOS: **SMF is already running**
when our activation script executes. We are not the init system; we feed the
init system. That keeps Phase 1 small.

---

## 1. Module interface — `smf.services.<name>`

An attrset of submodules, keyed by service short-name. This mirrors
`freebsd.rc.services` / `systemd.services` shape so muscle memory and (some)
upstream porting transfer.

### 1.1 The submodule

```nix
# modules/system/boot/init/smf.nix  (option surface excerpt)
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption mkEnableOption types literalExpression;

  # A single dependency group (SMF <dependency>).
  depType = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = "Dependency group name (unique within the service).";
      };
      grouping = mkOption {
        type = types.enum [ "require_all" "require_any" "optional_all" "exclude_all" ];
        default = "require_all";
        description = "SMF dependency grouping.";
      };
      restartOn = mkOption {
        type = types.enum [ "none" "error" "restart" "refresh" ];
        default = "none";
        description = "SMF restart_on: when this dep changes, what happens to us.";
      };
      fmris = mkOption {
        type = types.listOf types.str;
        example = literalExpression ''[ "svc:/milestone/network:default" ]'';
        description = ''
          Target FMRIs (or file:// paths) this group depends on.
          Milestones and files are both valid SMF dependency targets.
        '';
      };
    };
  };

  methodType = types.submodule {
    options = {
      exec = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Command line for the method. Either a literal shell fragment,
          or the SMF tokens ":true"/":kill"/":kill -SIGNAL" for stop.
          Rendered verbatim into exec_method/@exec (XML-escaped).
        '';
      };
      timeoutSeconds = mkOption {
        type = types.ints.unsigned;
        default = 60;
        description = "Method timeout. 0 = infinite (SMF convention).";
      };
    };
  };

  serviceType = types.submodule ({ name, config, ... }: {
    options = {
      enable = mkEnableOption "this SMF service (sets the enabled property)";

      category = mkOption {
        type = types.str;
        default = "system";
        description = ''
          FMRI category segment: svc:/<category>/<name>. Common: system,
          network, application, milestone, site.
        '';
      };

      instance = mkOption {
        type = types.str;
        default = "default";
        description = "Instance name (the :<instance> part of the FMRI).";
      };

      description = mkOption {
        type = types.str;
        default = name;
        description = "Human-readable template/common_name.";
      };

      # --- service model → startd/duration -----------------------------
      model = mkOption {
        type = types.enum [ "contract" "transient" "wait" ];
        default = "contract";
        description = ''
          SMF service model, written as the startd/duration property:
            contract  = long-running daemon under a process contract (default);
            transient = run-once, no lingering process (oneshots);
            wait      = svc.startd waits on a child in the foreground.
        '';
      };

      # --- methods ------------------------------------------------------
      start = mkOption {
        type = methodType;
        description = "Start method (exec_method name=start).";
      };
      stop = mkOption {
        type = methodType;
        default = { exec = ":kill"; };
        description = ''
          Stop method. Default ":kill" lets svc.startd tear down the
          contract. Set exec = ":true" for transient services that need
          no explicit stop.
        '';
      };
      refresh = mkOption {
        type = types.nullOr methodType;
        default = null;
        description = "Optional refresh method (SIGHUP-style reconfigure).";
      };

      # --- credentials (SMF method_credential) --------------------------
      user = mkOption {
        type = types.str;
        default = "root";
        description = "method_credential/user.";
      };
      group = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "method_credential/group.";
      };

      # --- environment & cwd (method_context) ---------------------------
      environment = mkOption {
        type = types.attrsOf types.str;
        default = { };
        example = { PATH = "/nix/store/.../bin"; TZ = "UTC"; };
        description = "method_environment name=value pairs.";
      };
      workingDirectory = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "method_context/@working_directory.";
      };

      # --- dependencies -------------------------------------------------
      dependencies = mkOption {
        type = types.listOf depType;
        default = [ ];
        description = "SMF <dependency> groups this service declares.";
      };

      # Sugar: most services just want 'after multi-user network'. This is
      # expanded in config into a single require_all group. Not a new concept,
      # just a shortcut over `dependencies`.
      requires = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Convenience: FMRIs folded into one require_all/restart_on=none
          dependency group named "solnix-requires".
        '';
      };

      # --- application config -------------------------------------------
      properties = mkOption {
        type = types.attrsOf (types.attrsOf types.str);
        default = { };
        example = { config = { port = "22"; listen = "0.0.0.0"; }; };
        description = ''
          Property groups of type "application". Outer key = pg name,
          inner attrs = property name→value (all rendered as astring).
          Typed values (count/boolean) are a later refinement.
        '';
      };

      # --- escape hatch -------------------------------------------------
      extraManifestXML = mkOption {
        type = types.lines;
        default = "";
        description = ''
          Raw XML spliced into <instance> before </instance>. Escape hatch
          for SMF features the typed interface does not cover yet
          (template blocks, notification params, extra property groups).
        '';
      };

      # --- computed (read-only) -----------------------------------------
      fmri = mkOption {
        type = types.str;
        readOnly = true;
        default = "svc:/${config.category}/${name}:${config.instance}";
        description = "Full FMRI, computed.";
      };
    };
  });
in
{
  options.smf.services = mkOption {
    type = types.attrsOf serviceType;
    default = { };
    description = "SMF services managed by solnix.";
  };

  # ... config section renders manifests + method scripts + activation, §2/§3.
}
```

### 1.2 Field → SMF mapping (the whole table)

| Nix field                | SMF manifest concept                                             |
|--------------------------|-----------------------------------------------------------------|
| attr key + `category`+`instance` | FMRI `svc:/<category>/<name>:<instance>`                |
| `enable`                 | `<instance ... enabled='true'>`                                 |
| `description`            | `common_name` template + `<instance>` comment                   |
| `model`                  | `startd/duration` = `contract`/`transient`/`wait`               |
| `start.exec`             | `<exec_method type='method' name='start' exec='...'>`           |
| `stop.exec`              | `<exec_method ... name='stop' exec='...'>` (`:kill` default)     |
| `refresh.exec`           | `<exec_method ... name='refresh' ...>` (omitted if null)        |
| `*.timeoutSeconds`       | `exec_method/@timeout_seconds`                                  |
| `user`/`group`           | `<method_credential user=... group=...>`                        |
| `environment`            | `<method_environment><envvar .../></method_environment>`        |
| `workingDirectory`       | `<method_context working_directory=...>`                        |
| `dependencies[]`         | `<dependency name grouping restart_on type='service'>`          |
| `requires[]`             | one folded `require_all` dependency group                       |
| `properties.<pg>.<k>`    | `<property_group name=<pg> type='application'><propval .../>`   |
| `extraManifestXML`       | raw splice before `</instance>`                                 |

`model` → `startd/duration` is the load-bearing mapping. It is what makes a
oneshot a oneshot: `transient` tells `svc.startd` the start method returning
`$SMF_EXIT_OK` means "online, done", not "the daemon died".

### 1.3 Example: sshd (contract daemon)

```nix
smf.services.sshd = {
  enable = true;
  category = "network";
  description = "OpenSSH server";
  model = "contract";
  requires = [
    "svc:/milestone/network:default"
    "svc:/system/filesystem/local:default"
  ];
  start.exec = "${pkgs.openssh}/sbin/sshd -f /etc/ssh/sshd_config";
  stop.exec = ":kill";           # svc.startd kills the contract
  refresh.exec = ":kill -HUP";   # reload config
  properties.config = { listen_addr = "0.0.0.0"; port = "22"; };
};
# → svc:/network/sshd:default
```

### 1.4 Example: a transient oneshot (mount /tmp cleanup)

```nix
smf.services.cleantmp = {
  enable = true;
  category = "system";
  description = "Clean /tmp at boot";
  model = "transient";
  requires = [ "svc:/system/filesystem/minimal:default" ];
  start.exec = "${pkgs.coreutils}/bin/rm -rf /tmp/*";
  start.timeoutSeconds = 30;
  stop.exec = ":true";           # nothing to stop
};
# → svc:/system/cleantmp:default
```

`requires` is pure sugar. In `config` it folds into `dependencies`:

```nix
config.smf.services = lib.mapAttrs (_: svc: svc // {
  dependencies = svc.dependencies ++ lib.optional (svc.requires != [ ]) {
    name = "solnix-requires";
    grouping = "require_all";
    restartOn = "none";
    fmris = svc.requires;
  };
}) config.smf.services;
```

The `properties` values are all `astring`; typed props (count/boolean/
time) deferred until an actual service needs a non-string typed property.

---

## 2. Manifest generation

### 2.1 Strategy

Each enabled service produces two store paths:

1. A method wrapper script (only if `start.exec` is a real command, not an SMF
   `:token`). We always wrap so the method runs under a fixed `PATH`, sources
   `/lib/svc/share/smf_include.sh`, and `exec`s the command — mirrors how
   illumos ships method scripts and how nixbsd wraps `rc.d` command bodies.
2. The XML manifest, referencing that method script by absolute store path.

These are assembled into one manifest directory derivation
(`smfManifests`) that activation points `svccfg`/`manifest-import` at (§3, §5).

### 2.2 Escaping — the one place to be careful

XML attribute values must be entity-escaped. SMF `exec` strings additionally go
through the method-script shell, so we split responsibilities:

- **Command bodies** (`start.exec` etc.) go into a **method script file**, not
  into an XML attribute. The XML `exec` attribute then just names that script
  (`/nix/store/…-sshd-start`). This sidesteps quoting hell: arbitrary shell
  lives in a file, XML only ever carries a store path + SMF tokens.
- **Everything that does land in XML** (descriptions, property values, env
  values, FMRIs) passes through an `xmlEscape`:

```nix
xmlEscape = s:
  builtins.replaceStrings
    [ "&"     "<"    ">"    "'"      "\"" ]
    [ "&amp;" "&lt;" "&gt;" "&apos;" "&quot;" ]
    s;
```

Escape `&` first (already handled by ordering above — `replaceStrings` is
single-pass left-to-right per position, so listing `&` first is correct).
`VERIFY` on a value containing a literal `&` that the single pass does not
double-escape the entities it just introduced (Nix `replaceStrings` does not
re-scan replacements, so this is safe).

### 2.3 Method script template

> **IMPLEMENTED (lib/smf/xml.nix) with two corrections — see §8.** `mkMethod`
> takes the whole `svc` (not just `method`) so it can reach
> `svc.workingDirectory`; and the returned value may be a *derivation* (the
> `writeScript` store path), so callers stringify it (`"${exec}"`) before
> `xmlEscape`. Signature shipped: `mkMethod = svcName: svc: kind: method:`.

```nix
mkMethod = svcName: kind: method:
  # SMF :tokens pass straight through as the exec attr; no script needed.
  if method.exec == null || lib.hasPrefix ":" method.exec
  then method.exec
  else pkgs.writeScript "smf-${svcName}-${kind}" ''
    #!${pkgs.runtimeShell}
    . /lib/svc/share/smf_include.sh
    ${lib.optionalString (svc.workingDirectory != null)
        "cd ${lib.escapeShellArg svc.workingDirectory}"}
    ${method.exec}
  '';
```

The returned value is either an SMF token (`:kill`) or an absolute store path.
Both are valid `exec_method/@exec` contents.

### 2.4 Manifest XML template

```nix
mkManifest = name: svc:
let
  esc = xmlEscape;
  startExec = mkMethod name "start" svc.start;
  stopExec  = mkMethod name "stop"  svc.stop;

  renderMethod = kind: exec: timeout: ''
        <exec_method type='method' name='${kind}'
                     exec='${esc exec}'
                     timeout_seconds='${toString timeout}'>
          <method_context${lib.optionalString (svc.workingDirectory != null)
              " working_directory='${esc svc.workingDirectory}'"}>
            <method_credential user='${esc svc.user}'${
              lib.optionalString (svc.group != null) " group='${esc svc.group}'"}/>
            ${lib.optionalString (svc.environment != { }) ''
            <method_environment>
              ${lib.concatStringsSep "\n              " (lib.mapAttrsToList
                (k: v: "<envvar name='${esc k}' value='${esc v}'/>")
                svc.environment)}
            </method_environment>''}
          </method_context>
        </exec_method>'';

  renderDep = dep: ''
        <dependency name='${esc dep.name}'
                    grouping='${dep.grouping}'
                    restart_on='${dep.restartOn}'
                    type='service'>
          ${lib.concatStringsSep "\n          " (map
            (f: "<service_fmri value='${esc f}'/>") dep.fmris)}
        </dependency>'';

  renderPg = pgName: props: ''
        <property_group name='${esc pgName}' type='application'>
          ${lib.concatStringsSep "\n          " (lib.mapAttrsToList
            (k: v: "<propval name='${esc k}' type='astring' value='${esc v}'/>")
            props)}
        </property_group>'';
in
pkgs.writeText "${name}.xml" ''
  <?xml version="1.0"?>
  <!DOCTYPE service_bundle SYSTEM "/usr/share/lib/xml/dtd/service_bundle.dtd.1">
  <service_bundle type='manifest' name='solnix:${esc name}'>
    <service name='${esc svc.category}/${esc name}'
             type='service' version='1'>

      <!-- single_instance: solnix generates one instance per service -->
      <single_instance/>

      ${lib.concatStringsSep "\n      " (map renderDep svc.dependencies)}

      ${renderMethod "start" startExec svc.start.timeoutSeconds}
      ${renderMethod "stop"  stopExec  svc.stop.timeoutSeconds}
      ${lib.optionalString (svc.refresh != null)
          (renderMethod "refresh" (mkMethod name "refresh" svc.refresh)
             svc.refresh.timeoutSeconds)}

      <!-- service model → startd/duration -->
      <property_group name='startd' type='framework'>
        <propval name='duration' type='astring' value='${svc.model}'/>
      </property_group>

      <instance name='${esc svc.instance}' enabled='${
        if svc.enable then "true" else "false"}'>
        ${lib.concatStringsSep "\n        "
            (lib.mapAttrsToList renderPg svc.properties)}
        ${svc.extraManifestXML}
      </instance>

      <template>
        <common_name>
          <loctext xml:lang='C'>${esc svc.description}</loctext>
        </common_name>
      </template>
    </service>
  </service_bundle>
'';
```

Concrete rendered output for `smf.services.sshd` (§1.3):

```xml
<?xml version="1.0"?>
<!DOCTYPE service_bundle SYSTEM "/usr/share/lib/xml/dtd/service_bundle.dtd.1">
<service_bundle type='manifest' name='solnix:sshd'>
  <service name='network/sshd' type='service' version='1'>
    <single_instance/>
    <dependency name='solnix-requires' grouping='require_all'
                restart_on='none' type='service'>
      <service_fmri value='svc:/milestone/network:default'/>
      <service_fmri value='svc:/system/filesystem/local:default'/>
    </dependency>
    <exec_method type='method' name='start'
                 exec='/nix/store/xxxx-smf-sshd-start'
                 timeout_seconds='60'>
      <method_context>
        <method_credential user='root'/>
      </method_context>
    </exec_method>
    <exec_method type='method' name='stop' exec=':kill' timeout_seconds='60'>
      <method_context><method_credential user='root'/></method_context>
    </exec_method>
    <exec_method type='method' name='refresh' exec=':kill -HUP'
                 timeout_seconds='60'>
      <method_context><method_credential user='root'/></method_context>
    </exec_method>
    <property_group name='startd' type='framework'>
      <propval name='duration' type='astring' value='contract'/>
    </property_group>
    <instance name='default' enabled='true'>
      <property_group name='config' type='application'>
        <propval name='listen_addr' type='astring' value='0.0.0.0'/>
        <propval name='port' type='astring' value='22'/>
      </property_group>
    </instance>
    <template>
      <common_name>
        <loctext xml:lang='C'>OpenSSH server</loctext>
      </common_name>
    </template>
  </service>
</service_bundle>
```

### 2.5 The manifest directory derivation

```nix
smfManifests = pkgs.runCommand "solnix-smf-manifests" { } ''
  mkdir -p $out/manifest/solnix
  ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: svc:
    "cp ${mkManifest name svc} $out/manifest/solnix/${name}.xml")
    (lib.filterAttrs (_: s: s.enable) config.smf.services))}
'';
```

### 2.6 Validation gate (build-time)

Validate every generated manifest against the DTD at build time so a bad
manifest fails the build, not the boot. On the Linux cross-builder we do not
have illumos `svccfg`, so use `xmllint` for the DTD check; `svccfg validate`
runs on-target during a smoke test (§6).

```nix
# build-time: structural DTD validation only
checkedManifests = pkgs.runCommand "solnix-smf-manifests-checked"
  { nativeBuildInputs = [ pkgs.buildPackages.libxml2 ]; } ''
  cp -r ${smfManifests} $out
  for m in $out/manifest/solnix/*.xml; do
    xmllint --noout --dtdvalid \
      ${dtdFile} "$m"   # dtdFile = the illumos service_bundle.dtd.1, §5.4
  done
'';
```

`VERIFY` the illumos DTD parses cleanly under GNU `xmllint`; if not, downgrade
to `xmllint --noout` (well-formedness only) at build time and rely on on-target
`svccfg validate` for the DTD check.

---

## 3. Activation

`svc.startd` and `svc.configd` are already up (they come from `pkgs.illumos.*`
and are launched by the kernel/`init`, not by us). Activation's job is only:
tell `configd` about our manifests, apply enable/disable deltas, and nudge the
milestone.

### 3.1 Strategy (a): import-at-activation — **recommended for Phase 1**

`switch-to-configuration` (forked from NixOS) calls an SMF activation snippet:

```bash
# system/activation/smf-activate.sh (rendered by smf.nix)
set -eu

MANIFEST_DIR="@out@/manifest/solnix"       # store path of checkedManifests
OLD_DIR="/run/solnix/current-smf-manifests"

# 1. Import / reconcile changed manifests.
for m in "$MANIFEST_DIR"/*.xml; do
  svccfg import "$m"     # idempotent: creates or updates the service
done

# 2. Disable + delete services present in the OLD closure but gone now.
if [ -d "$OLD_DIR" ]; then
  for m in "$OLD_DIR"/*.xml; do
    base=$(basename "$m")
    [ -e "$MANIFEST_DIR/$base" ] && continue
    fmri=$(svccfg -f - <<EOF 2>/dev/null || true
select-by-file $m
EOF
)
    # simpler: derive FMRI from the manifest name at build time (see below)
  done
fi

# 3. Apply enabled/disabled state (svccfg import sets initial enabled;
#    enforce explicitly so a config flip takes effect on switch).
@enableCommands@   # e.g. svcadm enable  svc:/network/sshd:default
@disableCommands@  # e.g. svcadm disable svc:/system/oldthing:default

# 4. Bring the system to the target milestone (idempotent).
svcadm milestone "@targetMilestone@"   # svc:/milestone/multi-user-server:default

# 5. Record what we imported for the next switch's delta.
mkdir -p /run/solnix
ln -sfn "$MANIFEST_DIR" "$OLD_DIR"
```

Deriving the FMRI for delete is easier at Nix-build time than by re-parsing
XML on-target: we know each service's `fmri` (§1.1, read-only option), so the
`@disableCommands@`/removal list is generated from
`(oldConfig.smf.services keys) − (newConfig.smf.services keys)`. But
`switch-to-configuration` compares against the *previously booted* generation,
which solnix already tracks via the boot-environment/generation model
(roadmap P2.1). For Phase 1, the delete path can be a no-op (only
add/enable handled; removal-on-switch deferred to P2.1 when generation diff
exists) — a stale service left enabled does not block the milestone gate.

Trade-offs:

- **Pro:** matches illumos norms exactly; debuggable with stock tools
  (`svcs -x`, `svccfg`); no need to reproduce `configd`'s SQLite schema; works
  identically whether the manifest arrived via `manifest-import` at boot or our
  activation script.
- **Con:** import cost paid at every switch and (via `manifest-import`) at boot.
  For a base config (tens of services) this is milliseconds-to-seconds. Only a
  problem at hundreds/thousands of services.

### 3.2 Strategy (b): prebuilt `repository.db`

Build `/etc/svc/repository.db` at Nix build time by running `svccfg import`
against a scratch repository in the sandbox, then ship the finished SQLite file
in the image. Boot skips import entirely.

- **Pro:** faster, deterministic boot; no per-boot `manifest-import` scan.
- **Con:** (1) requires `svc.configd`/`svccfg` to run in the *build* sandbox,
  which on a Linux cross-builder means an illumos emulation or a build-on-target
  step — a real complication given the cross-build mandate (R8). (2) Couples the
  build to `configd`'s on-disk schema version; a `configd` upgrade can require a
  repo rebuild. (3) Loses the "just drop a manifest and re-import" debuggability.
  (4) Mixing a prebuilt repo with runtime `svccfg` changes (admin overrides)
  needs a merge story.

**Recommendation:** ship **(a)** for Phase 1. It is the smaller diff and the
only one that cleanly satisfies "cross-build from Linux" (R8) without an
in-sandbox illumos. Revisit **(b)** only if boot-time import is measured too
slow on real configs — matching design note D5 (naive import first,
precompiled repo only if measured too slow). If we do (b) later, do the repo
build in a `make-be`-adjacent on-target step, not in the generic cross sandbox.

### 3.3 Interaction with `switch-to-configuration`

NixOS `switch-to-configuration` diffs units and restarts what changed. Our SMF
analog:

- **Added service:** `svccfg import` creates it; `svcadm enable` if `enable`.
- **Changed service:** `svccfg import` upgrades the service; then the declared
  state is put back over anything an admin changed (below, "The declared state
  wins"), `svcadm refresh <fmri>` re-reads, and `svcadm restart <fmri>` if the
  start method changed.
- **Removed service:** `svcadm disable -s <fmri>` then `svccfg delete <fmri>`
  (Phase 1: deferred, §3.1).
- **Milestone:** `svcadm milestone <target>` last, idempotently.

`VERIFY` that `svcadm refresh` is enough to pick up changed properties
without a manual `restart` for the properties services actually read at
start-method time.

**The declared state wins (measured 2026-11-11).** On NixOS a unit's state is
the generation's: /etc/systemd/system comes from the store, `systemctl disable`
of a declared unit can't persist, and only `systemctl --runtime` changes, gone
at reboot, are possible. solnix does the same. illumos SMF has no admin layer to
drop (Solaris 11's `svccfg listcust`/`delcust` came after the fork; illumos
svccfg has neither): `svcadm enable/disable` writes `general/enabled` and
`svccfg setprop/setenv` the property itself, a `beadm create` clone copies that
repository, an upgrade import never changes `general/enabled` and keeps the
current value of a property that differs from the last import ("Conflict
upgrading"), and manifest-import never applies a profile it holds a hash for
(manifest_hash.c, "we do not reread a profile"). So a service disabled once
booted disabled in every later BE (dixi, fleet11), and lixi's builder kept an
old start/environment for generations. `smf-declared` (modules/system/activation/
smf-declared.sh) therefore runs at every activation, for each `smf.services`
instance only: it logs what differs from the instance's last-import snapshot,
`svccfg revert last-import`, and sets `general/enabled` to the declaration.
`activate` runs it after the import (switch, test); install-be runs it offline
on a BE cloned by `switch-to-configuration boot`, and also forgets the site
profile's hash so the BE's first manifest-import applies it. revert keeps
non-persistent groups, so `svcadm disable -t` (general_ovr) still holds until
reboot, like `--runtime`. Services the toplevel doesn't declare (the stock
illumos ones) keep their admin state, apart from what the site profile names.
To change a declared service, change the configuration; the state before a
revert is in the instance's `previous` snapshot. Test: scripts/test-smf-declared.sh.

---

## 4. The `systemd`-compat stub (`nixos-compat.nix`)

Upstream nixpkgs modules pulled by reference (T1.10, `extPath`) reference
`systemd.*`, `boot.loader.*`, etc. We need those options to *exist and
type-check* so evaluation succeeds, without pulling systemd semantics.

### 4.1 Two tiers

**Tier 1 — accept-and-ignore (Phase 1).** Declare the option so the module
evaluates; do nothing with the value. Grow lazily: stub only what an actually
evaluated module touches (design note D4, task T1.9 "grow lazily").

```nix
# modules/nixos-compat.nix  (excerpt)
{ lib, ... }:
let inherit (lib) mkOption mkSinkUndeclaredOptions types; in
{
  options.systemd = {
    # The big one: swallow whole systemd.services.* without modelling it.
    services = mkOption {
      type = types.attrsOf (types.submodule { config._module.freeformType = types.attrs; });
      default = { };
      description = "IGNORED compat stub. See nixos-compat.nix.";
    };
    tmpfiles.rules = mkOption { type = types.listOf types.str; default = [ ]; };
    # ...only what evaluated modules actually read...
  };

  # Belt-and-suspenders: silently swallow stray systemd.* leaves so a newly
  # pulled module does not hard-fail on an unstubbed sub-option.
  config._module.check = true;
}
```

`VERIFY` the exact freeform mechanism (`_module.freeformType` vs a permissive
`types.attrs`) evaluates cleanly against our forked `eval-config.nix`. The goal
is "unknown `systemd.services.foo.bar = …` does not throw."

**Tier 2 — translate (selective, Phase 1 hand-port; general case deferred).**
Some services we *want* running are only defined upstream as
`systemd.services.foo`. Options:

- **Auto-translate** `systemd.services.<n>` → `smf.services.<n>`? The fields
  line up superficially (`serviceConfig.ExecStart` → `start.exec`,
  `Type=oneshot` → `model="transient"`, `Type=simple/forking` → `contract`,
  `after`/`requires` → `dependencies`, `Restart=` → restart behavior). **But**
  systemd semantics that have no clean SMF analog (socket activation, timers,
  `RuntimeDirectory`, cgroup resource limits, `PartOf`/`BindsTo` nuance,
  templated `@` units, `ExecStartPre` chains) make general auto-translation a
  trap: it will silently produce subtly-wrong services. **Not recommended as a
  general mechanism.**
- **Hand-port** the handful of services the base config needs (sshd, ntp,
  cron-equiv, getty/console-login analog) directly as `smf.services.*`, and
  *ignore* their `systemd.services.*` definitions via Tier 1.

**Recommendation (Phase 1 scope):**

1. Tier-1 accept-and-ignore for **all** `systemd.*` so upstream modules
   evaluate.
2. Hand-port the ~5 services the base config actually needs as native
   `smf.services.*`.
3. Optionally write a **best-effort** `systemd.services → smf.services`
   translator behind an explicit opt-in flag
   (`smf.translateSystemd = true`) covering only `ExecStart`/`Type`/`after`,
   loudly warning (`lib.warn`) on any field it drops. Do **not** enable it by
   default. This is the pragmatic middle: cheap wins for trivial units, no
   silent breakage for complex ones. The translator is opt-in and
   partial by design; the honest path for a nontrivial service is a hand-port.

---

## 5. Bootstrap interaction

### 5.1 Add, don't replace

The base image already ships the world's stock manifests under
`/lib/svc/manifest` (from `pkgs.illumos.*`, which stages the illumos proto
area). solnix **adds** its manifests in a dedicated subtree and lets SMF compose
them; it does **not** rewrite the stock manifest set.

- Stock manifests: `/lib/svc/manifest/{system,network,milestone,...}` —
  own the milestones, `manifest-import`, `svc.startd`/`configd` bootstrap,
  filesystem/minimal, etc. These must be present for *any* boot.
- solnix manifests: `/lib/svc/manifest/solnix/*.xml` — everything declared via
  `smf.services.*`.

Because both live under the dirs `manifest-import` scans, the world's own
`svc:/system/manifest-import:default` imports our manifests at boot with zero
extra wiring. Our activation-time `svccfg import` (§3.1) is then only needed for
*switching* an already-booted system, not for first boot.

### 5.2 Minimum services for a bootable base config

These come from the world (stock manifests), not from `smf.services.*`:

- `svc:/system/svc/restarter:default` (svc.startd) — implicit, the restarter.
- `svc:/system/manifest-import:default` — imports our manifests.
- `svc:/milestone/single-user`, `.../multi-user`, `.../multi-user-server`.
- `svc:/system/filesystem/{root,usr,minimal,local}:default`.
- `svc:/system/device/local:default`, `svc:/milestone/devices:default`.
- `svc:/system/console-login:default` (a login prompt — proves multi-user).
- `svc:/milestone/network:default`, `svc:/network/loopback:default` (loopback
  at minimum; real NICs are P2.3).

`VERIFY` this exact minimal set against a stripped OpenIndiana boot; the goal is
"`svcadm milestone multi-user-server` completes and `svcs -x` is clean." solnix
adds only what the specific config declares on top.

### 5.3 Composition with the world's manifest dir

```
/lib/svc/manifest/
├── system/          # world (stock)
├── network/         # world (stock)
├── milestone/       # world (stock)  ← owns the milestone targets
└── solnix/          # solnix-generated (checkedManifests, §2.6)
    ├── sshd.xml
    └── cleantmp.xml
/lib/svc/method/     # world stock methods + our store-path method scripts
                     #   (our methods are absolute /nix/store paths referenced
                     #    from the XML; they need not be copied under /lib)
```

The system `etc`/path modules (T1.7) symlink or bind our `checkedManifests`
subtree in as `/lib/svc/manifest/solnix`. Our method scripts are referenced by
absolute store path from the XML, so they do **not** need to live under
`/lib/svc/method` — one less copy, and it keeps them immutable in the store.
`VERIFY` `svc.startd` executes a method whose `exec` is an absolute
`/nix/store/...` path (it should — `exec` is just a command line).

### 5.4 The DTD

`service_bundle.dtd.1` ships with the world at
`/usr/share/lib/xml/dtd/service_bundle.dtd.1`. The generated `<!DOCTYPE>`
references that on-target path (correct on the running system). For the
build-time `xmllint` check (§2.6), pin the DTD as a Nix input
(`dtdFile = "${pkgs.illumos.smf-dtd}/service_bundle.dtd.1"` or a vendored copy
from the illumos source) so the cross-builder has it without an illumos host.
`VERIFY` where the DTD lives in the proto area / which `pkgs.illumos.*`
component should expose it.

---

## 6. File plan (ordered checklist)

Mapped to T1.11 (generator) and T1.12 (activation). Each file is the smallest
thing that advances the gate; grow lazily.

| # | File | Task | What it contains |
|---|------|------|------------------|
| 1 | `lib/smf/xml.nix` | T1.11 | `xmlEscape`, `mkMethod`, `mkManifest`, `mkManifestDir` pure helpers (§2). No `config` deps → unit-testable. |
| 2 | `modules/system/boot/init/smf.nix` | T1.11 | The `smf.services.<name>` option surface (§1) + `config` wiring: fold `requires`, call `lib/smf/xml.nix`, produce `checkedManifests`. |
| 3 | `modules/system/etc/…` (extend existing) | T1.11 | Stage `checkedManifests` at `/lib/svc/manifest/solnix` (§5.3). Reuse the etc/path module, don't invent one. |
| 4 | `modules/nixos-compat.nix` (extend T1.9) | — | Tier-1 `systemd.*` accept-and-ignore stub (§4.1); optional opt-in translator behind `smf.translateSystemd`. |
| 5 | `modules/system/activation/smf-activate.sh` (+ its `.nix` wrapper) | T1.12 | Rendered activation snippet (§3.1): `svccfg import`, enable/disable deltas, `svcadm milestone`. |
| 6 | Hook into forked `switch-to-configuration` | T1.12 | Call the SMF activation snippet in the activation sequence (§3.3). |
| 7 | `configurations/base` (extend T1.17) | test | Declare the minimal `smf.services.*` (sshd + console-login are world-provided; add at least one solnix oneshot to exercise the generator). |
| 8 | `lib/smf/tests.nix` | test | Pure eval-time asserts: rendered XML for the sshd/oneshot examples matches expected fixtures; `xmllint --dtdvalid` passes. Runs on the Linux builder, no illumos needed. |

### Test gate

1. **Build-time (Linux cross-builder):**
   `lib/smf/tests.nix` asserts pass; every generated manifest passes
   `xmllint --dtdvalid service_bundle.dtd.1` (§2.6).
2. **On-target (QEMU, the Phase 1 gate — R6.2/R6.3/R9):**
   - Image boots; `manifest-import` imports `/lib/svc/manifest/solnix/*`.
   - `svcadm milestone svc:/milestone/multi-user-server:default` completes.
   - `svcs -x` reports **no** services in `maintenance`/`degraded`.
   - `svcs svc:/network/sshd:default` shows `online`; the declared oneshot
     shows `online` (transient, ran once) — not `maintenance`.
   - A switch to a config that toggles a service's `enable` takes effect after
     `switch-to-configuration` without reboot.

Green gate = T1.11 + T1.12 done and R6.1–R6.3 satisfied.

---

## 7. Open items (VERIFY list)

- `svccfg import` re-import updates in place and preserves admin property
  overrides on Hipster 2025.06 (§3.3).
- `svc.startd` runs a method whose `exec` is an absolute `/nix/store` path
  (§5.3).
- illumos `service_bundle.dtd.1` validates under GNU `xmllint`; else fall back
  to well-formedness + on-target `svccfg validate` (§2.6).
- Exact minimal stock-manifest set to reach `multi-user-server` (§5.2).
- Where the DTD is exposed in `pkgs.illumos.*` (§5.4).
- `startd/duration` accepts `wait` as we expect for foreground-child services
  (§1.2); confirm the property name/values against `smf(7)`/`svc.startd(8)`.

---

## 8. Implementation notes + §2 corrections (T1.11 generator, DONE)

The generator (§2) is implemented in `lib/smf/xml.nix` (pure renderers) and
wired into `modules/system/boot/init/smf.nix` (`config.system.build.smfManifests`
= `checkedManifests`). Built + validated on the illumos host
(`illumos-960edb1c89`, gate `ac45d71fc2`) via `scripts/oi-smf-gates.sh`.

**GATE result:** the `sshd` (§1.3) and a `cleantmp` transient oneshot (§1.4)
manifests both **PASS `xmllint --noout --dtdvalid service_bundle.dtd.1`** AND
**`svccfg validate`** (the on-target authority — stronger than xmllint, and it
resolves the §7 open item / §2.6 `VERIFY`: the illumos DTD *does* validate under
GNU xmllint, no fallback needed). A negative test confirms the gate rejects a
manifest with an undeclared element.

### Corrections to §2 found during implementation

1. **§2.3 `mkMethod` scope bug.** The template `mkMethod = svcName: kind:
   method:` referenced `svc.workingDirectory` in its body, but `svc` was not a
   parameter. Shipped signature: **`mkMethod = svcName: svc: kind: method:`**
   (takes the whole service for `workingDirectory`, plus the specific method).

2. **§2.4 `exec` may be a derivation, not a string.** `mkMethod` returns either
   an SMF `:token` (a string) OR a `writeScript` result (a *derivation*). The
   `renderMethod` template does `esc exec`, and `xmlEscape` (`replaceStrings`)
   requires a string — so callers must stringify: **`esc "${exec}"`**. `"${drv}"`
   coerces a derivation to its out-path and leaves a plain string unchanged.
   (Without this, eval fails: "value is a set while a string was expected".)

3. **§2.6 DTD is in the gate proto.** Resolves the §5.4 `VERIFY`: the DTD ships
   at `usr/share/lib/xml/dtd/service_bundle.dtd.1` inside `pkgs.illumos.gate`
   (the proto). The module reads `dtdFile =
   "${pkgs.illumos.gate}/usr/share/lib/xml/dtd/service_bundle.dtd.1"`. A
   dedicated `pkgs.illumos.smf-dtd` component is optional polish; the proto
   path is already a store path.

4. **`<service>` element ORDER is DTD-enforced.** `service_bundle.dtd.1`'s
   content model is `create_default_instance?, single_instance?, restarter?,
   dependency*, dependent*, method_context?, exec_method*,
   notification_parameters*, property_group*, instance*, stability?, template?`.
   The §2.4 template's emission order (single_instance → dependency* →
   exec_method* → property_group[startd] → instance → template) already respects
   this; the implementation preserves it and the DTD check confirms it.

5. **`pkgs` is forced only inside `config`.** The module's `smfXml`/`dtdFile`
   bindings are in the `config` `let`, not the top-level `let`, so a
   bare/options-only import does not require `pkgs` to carry
   `writeText`/`writeScript`/`runtimeShell`/`illumos`. Only realising the
   generated manifests touches them.

### Standalone testability (no nixpkgs on the build host)

`lib/smf/xml.nix` captures **no `pkgs`, no `config`** — it takes `{ lib,
writeText, writeScript, runtimeShell }` by injection. The fork passes
`pkgs.writeText` etc.; `lib/smf/tests.nix` passes tiny plain-`derivation`
stand-ins + a minimal `lib` subset, so the renderer is unit-testable on the
illumos host that has NO nixpkgs (the same constraint `pkgs/illumos/*.nix` works
around). This is why the GATE could be met before the nixpkgs fork exists.
