# lib/smf/tests.nix — standalone (no nixpkgs, no module system) exercise of the
# SMF renderers in lib/smf/xml.nix. GATE 2: produce a real generated SMF manifest
# + method script as store paths, so the host can run `xmllint --dtdvalid`
# against them.
#
# The full module-system eval needs the nixpkgs fork (pkgs, eval-config). This
# harness sidesteps that per the task's allowance ("test the generator functions
# in isolation ... with sample inputs"): it injects tiny writeText/writeScript
# stand-ins (plain derivations, no stdenv) and passes sample `svc` attrsets that
# match the smf.services.<name> option surface (configurations/base.nix sshd +
# a transient oneshot). If the XML the renderer emits is DTD-valid, the generator
# is correct; the module wiring is then just plumbing these same values in.
#
# Build on the illumos host:
#   nix-build lib/smf/tests.nix -A sshdManifest      # -> the sshd manifest XML
#   nix-build lib/smf/tests.nix -A oneshotManifest   # -> the oneshot manifest
#   nix-build lib/smf/tests.nix -A sshdStartMethod   # -> the wrapped start script
# then: xmllint --noout --dtdvalid <DTD> <result>

let
  # Minimal `lib` subset the renderers use — no nixpkgs needed. builtins cover
  # replaceStrings; the rest are one-liners.
  lib = {
    inherit (builtins) replaceStrings concatStringsSep;
    optionalString = c: s: if c then s else "";
    mapAttrsToList = f: attrs: map (n: f n attrs.${n}) (builtins.attrNames attrs);
    hasPrefix = pre: str:
      builtins.substring 0 (builtins.stringLength pre) str == pre;
    # escapeShellArg: single-quote, escaping embedded single quotes. Good enough
    # for the workingDirectory case (a path).
    escapeShellArg = s:
      "'" + builtins.replaceStrings [ "'" ] [ "'\\''" ] s + "'";
  };

  # writeText / writeScript stand-ins: a plain derivation that writes $content to
  # $out (nixpkgs' do the same, plus refs scanning we don't need here). Runs on
  # the illumos host with /usr/bin/bash, matching pkgs/illumos/*.nix's approach.
  mkWriter = executable: name: content: derivation {
    inherit name content;
    system = builtins.currentSystem;
    builder = "/usr/bin/bash";
    PATH = "/usr/gnu/bin:/usr/bin:/usr/sbin";
    args = [ "-c" (
      ''printf '%s' "$content" > "$out"''
      + (if executable then ''; chmod +x "$out"'' else "")
    ) ];
  };
  writeText = mkWriter false;
  writeScript = mkWriter true;

  smf = import ./xml.nix {
    inherit lib writeText writeScript;
    runtimeShell = "/bin/sh";
  };

  # --- sample service values (match the smf.services.<name> option surface) ---

  # sshd: contract daemon, from configurations/base.nix §1.3. `allDependencies`
  # is what the module computes from `requires` (the folded require_all group);
  # here we supply it directly.
  sshd = {
    enable = true;
    category = "network";
    instance = "default";
    description = "OpenSSH server";
    model = "contract";
    start = { exec = "/run/current-system/sw/sbin/sshd -f /etc/ssh/sshd_config"; timeoutSeconds = 60; };
    stop = { exec = ":kill"; timeoutSeconds = 60; };
    refresh = { exec = ":kill -HUP"; timeoutSeconds = 60; };
    user = "root";
    group = null;
    environment = { };
    workingDirectory = null;
    properties.config = { listen_addr = "0.0.0.0"; port = "22"; };
    extraManifestXML = "";
    allDependencies = [{
      name = "solnix-requires";
      grouping = "require_all";
      restartOn = "none";
      fmris = [ "svc:/milestone/network:default" "svc:/system/filesystem/local:default" ];
    }];
  };

  # oneshot: transient, from §1.4. Exercises a REAL start command (wrapped into a
  # method script), a :true stop token, environment vars, and NO dependencies /
  # NO application properties. Description carries a literal `&` to exercise
  # xmlEscape end-to-end.
  oneshot = {
    enable = true;
    category = "system";
    instance = "default";
    description = "Clean /tmp at boot (rm & rebuild)";
    model = "transient";
    start = { exec = "/run/current-system/sw/bin/rm -rf /tmp/*"; timeoutSeconds = 30; };
    stop = { exec = ":true"; timeoutSeconds = 60; };
    refresh = null;
    user = "root";
    group = "root";
    environment = { PATH = "/run/current-system/sw/bin"; TZ = "UTC"; };
    workingDirectory = "/tmp";
    properties = { };
    extraManifestXML = "";
    allDependencies = [ ];
  };
in
{
  sshdManifest = smf.mkManifest "sshd" sshd;
  oneshotManifest = smf.mkManifest "cleantmp" oneshot;
  sshdStartMethod = smf.mkMethod "sshd" sshd "start" sshd.start;
  oneshotStartMethod = smf.mkMethod "cleantmp" oneshot "start" oneshot.start;

  # escaping self-check as a Nix assert (fails eval if xmlEscape regresses):
  #   "a & <b> 'c' \"d\"" -> "a &amp; &lt;b&gt; &apos;c&apos; &quot;d&quot;"
  _escCheck =
    assert smf.xmlEscape ''a & <b> 'c' "d"''
         == "a &amp; &lt;b&gt; &apos;c&apos; &quot;d&quot;";
    "escape-ok";
}
