# lib/smf/xml.nix — pure SMF manifest + method-script renderers.
#
# design-smf-init.md §2 file #1. These are the load-bearing string functions
# that turn an `smf.services.<name>` submodule value into (a) a method wrapper
# script and (b) a DTD-valid SMF manifest XML, referencing the script by
# absolute store path.
#
# pkgs-AGNOSTIC by injection: the module (modules/system/boot/init/smf.nix)
# calls this with the nixpkgs fork's writers:
#     import ../../lib/smf/xml.nix {
#       inherit lib;
#       writeText = pkgs.writeText;
#       writeScript = pkgs.writeScript;
#       runtimeShell = pkgs.runtimeShell;
#     }
# A standalone test (lib/smf/tests.nix) injects tiny stand-ins (builtins.toFile
# / a plain derivation) so the renderers are unit-testable on a host that has NO
# nixpkgs (the illumos build host — same constraint pkgs/illumos/*.nix works
# around). No `config`, no `pkgs` captured here → the XML/script logic is a pure
# function of its inputs and the injected writers.

{ lib
, writeText     # name: str -> content: str -> store path (like pkgs.writeText)
, writeScript   # name: str -> content: str -> executable store path
, runtimeShell  # absolute path to the method-script shell (e.g. /bin/sh)
}:

let
  inherit (lib) optionalString concatStringsSep mapAttrsToList hasPrefix;

  # --- escaping (design §2.2) ---------------------------------------------
  # XML attribute/text escaping. Escape `&` FIRST so we don't double-escape the
  # entities we introduce; replaceStrings is single-pass left-to-right per
  # position and does NOT re-scan its own replacements, so listing `&` first is
  # correct and safe (verified: "a & <b>" -> "a &amp; &lt;b&gt;", no double-esc).
  xmlEscape =
    builtins.replaceStrings
      [ "&" "<" ">" "'" "\"" ]
      [ "&amp;" "&lt;" "&gt;" "&apos;" "&quot;" ];

  # --- method wrapper (design §2.3, corrected) ----------------------------
  # Returns either an SMF :token (passed straight through as the exec attr) or an
  # absolute store-path to a wrapper script. The wrapper sources SMF's shell
  # include, optionally cd's to workingDirectory, and runs the command body — so
  # arbitrary shell lives in a FILE, never in an XML attribute (sidesteps quoting
  # hell; XML `exec` only ever carries a store path or a :token).
  #
  # §2.3 CORRECTION: the design's mkMethod referenced `svc.workingDirectory` but
  # only took `method` — `svc` was out of scope. Fixed by taking the whole `svc`
  # (for workingDirectory) plus the specific `method`.
  mkMethod = svcName: svc: kind: method:
    if method == null || method.exec == null || hasPrefix ":" method.exec
    then (if method == null then null else method.exec)
    else writeScript "smf-${svcName}-${kind}" ''
      #!${runtimeShell}
      . /lib/svc/share/smf_include.sh
      ${optionalString (svc.workingDirectory != null)
          "cd ${lib.escapeShellArg svc.workingDirectory}"}
      ${method.exec}
    '';

  # --- manifest XML (design §2.4) -----------------------------------------
  # DTD element ORDER for <service> is fixed (service_bundle.dtd.1):
  #   create_default_instance?, single_instance?, restarter?, dependency*,
  #   dependent*, method_context?, exec_method*, notification_parameters*,
  #   property_group*, instance*, stability?, template?
  # We emit: single_instance, dependency*, exec_method*, property_group(startd),
  # instance, template — which respects that order. <instance>'s own model is
  #   restarter?, dependency*, dependent*, method_context?, exec_method*,
  #   notification_parameters*, property_group*, template?
  # so the application property_groups (and the extraManifestXML splice) go
  # there, before any nested template.
  mkManifest = name: svc:
    let
      esc = xmlEscape;
      startExec = mkMethod name svc "start" svc.start;
      stopExec = mkMethod name svc "stop" svc.stop;
      refreshExec = mkMethod name svc "refresh" svc.refresh;

      renderMethod = kind: exec: timeout: ''
      <exec_method type='method' name='${kind}' exec='${esc "${exec}"}' timeout_seconds='${toString timeout}'>
            <method_context${optionalString (svc.workingDirectory != null)
                " working_directory='${esc svc.workingDirectory}'"}>
              <method_credential user='${esc svc.user}'${
                optionalString (svc.group != null) " group='${esc svc.group}'"}/>${
                optionalString (svc.environment != { }) ''

              <method_environment>${
                concatStringsSep "" (mapAttrsToList
                  (k: v: "\n                <envvar name='${esc k}' value='${esc v}'/>")
                  svc.environment)}
              </method_environment>''}
            </method_context>
          </exec_method>'';

      renderDep = dep: ''
      <dependency name='${esc dep.name}' grouping='${dep.grouping}' restart_on='${dep.restartOn}' type='service'>${
            concatStringsSep "" (map
              (f: "\n            <service_fmri value='${esc f}'/>") dep.fmris)}
          </dependency>'';

      renderPg = pgName: props: ''
      <property_group name='${esc pgName}' type='application'>${
            concatStringsSep "" (mapAttrsToList
              (k: v: "\n            <propval name='${esc k}' type='astring' value='${esc v}'/>")
              props)}
          </property_group>'';

      # SMF <dependent>: one optional_all group per target FMRI. The group name
      # must be unique within the target, so it is derived from this service.
      renderDependent = i: f: ''
      <dependent name='${esc name}-dep${toString i}' grouping='optional_all' restart_on='none'>
            <service_fmri value='${esc f}'/>
          </dependent>'';
      depList = svc.dependents or [ ];
      dependentsXml = concatStringsSep "" (builtins.genList
        (i: "\n          " + renderDependent i (builtins.elemAt depList i))
        (builtins.length depList));

      deps = svc.allDependencies or svc.dependencies;
    in
    writeText "${name}.xml" ''
      <?xml version="1.0"?>
      <!DOCTYPE service_bundle SYSTEM "/usr/share/lib/xml/dtd/service_bundle.dtd.1">
      <service_bundle type='manifest' name='solnix:${esc name}'>
        <service name='${esc svc.category}/${esc name}' type='service' version='1'>
          <single_instance/>${
            concatStringsSep "" (map (d: "\n          " + renderDep d) deps)}${dependentsXml}
          ${renderMethod "start" startExec svc.start.timeoutSeconds}
          ${renderMethod "stop" stopExec svc.stop.timeoutSeconds}${
            optionalString (svc.refresh != null)
              ("\n          " + renderMethod "refresh" refreshExec svc.refresh.timeoutSeconds)}
          <property_group name='startd' type='framework'>
            <propval name='duration' type='astring' value='${svc.model}'/>
          </property_group>
          <instance name='${esc svc.instance}' enabled='${if svc.enable then "true" else "false"}'>${
            concatStringsSep "" (mapAttrsToList (n: p: "\n          " + renderPg n p) svc.properties)}${
            optionalString (svc.extraManifestXML != "") ("\n          " + svc.extraManifestXML)}
          </instance>
          <template>
            <common_name>
              <loctext xml:lang='C'>${esc svc.description}</loctext>
            </common_name>
          </template>
        </service>
      </service_bundle>
    '';
in
{
  inherit xmlEscape mkMethod mkManifest;
}
