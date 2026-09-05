# aarch64 GTK4 toolkit entry: entry-aa-fin (proven cross set) + the toolkit
# fixes injected into crossOverlays (target) + the native toml repin injected
# into the non-cross overlays (buildPackages).
import /root/entry-aa-fin-x.nix {
  nixpkgs = /root/nixpkgs-patched;
  extraCrossOverlays = [ (import /root/aa-toolkit-fixes-overlay.nix) ];
  extraNativeOverlays = [ (import /root/aa-native-toml-overlay.nix) ];
}
