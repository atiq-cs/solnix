let
  b = builtins.toFile "sa-builder.sh" ''
    set -e
    test -n "$NIX_ATTRS_SH_FILE" || { echo "FAIL: no NIX_ATTRS_SH_FILE" >&2; exit 1; }
    . "$NIX_ATTRS_SH_FILE"
    echo "list1=''${myList[1]} count=''${#myList[@]} bool=$myBool" > "''${outputs[out]}"
  '';
in
derivation {
  name = "structured-attrs-proof";
  system = "x86_64-solaris";
  builder = "/usr/bin/bash";
  args = [ b ];
  __structuredAttrs = true;
  myList = [ "a" "b" "c" ];
  myBool = true;
}
