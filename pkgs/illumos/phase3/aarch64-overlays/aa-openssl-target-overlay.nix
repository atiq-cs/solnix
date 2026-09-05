# aarch64 cross openssl target fix. OpenSSL 3.6.3 upstream ships NO
# solaris64-aarch64 Configure target -- only solaris64-x86_64 / sparcv9 / linux-*.
# nixpkgs' openssl configureScript map keys on hostPlatform.system; aarch64-solaris
# is absent -> throw "Not sure what configuration to use for aarch64-unknown-solaris2.11".
#
# Fix (analogous to the wave4 target-openssl trick, mechanized as an overlay):
#   1. drop a Configurations/50-solaris-aarch64.conf into the source defining
#      solaris64-aarch64-gcc (inherits solaris-common-gcc for illumos shared-lib
#      semantics; SIXTY_FOUR_BIT_LONG bn_ops; no asm_arch -> pairs with no-asm so
#      we never need an aarch64-solaris perlasm scheme).
#   2. override configureScript to point at it, with no-asm.
# The cross gcc is supplied by the stdenv cc (CC/CROSS_COMPILE via cc-wrapper),
# so the target only needs the shared-lib + bn config, not a compiler name.
#
# NOTE (phantom undefs): the apps/openssl executable links -lnsl, and the seed
# sysroot's libnsl.so is itself a filter that re-exports mp_*@SUNW_1.1 /
# MD5*@SUNW_1.1 from libmp/libmd. GNU ld (the only aarch64-capable linker in the
# seed) resolves a shared lib's own undefined symbols eagerly and errors, because
# libmd.so is absent from the seed sysroot. --allow-shlib-undefined tells GNU ld
# to trust that those symbols resolve at runtime via the illumos filter chain
# (they do). Pairs with entry-aa-fin-x.nix's cxxNomapCc, which fixes the earlier
# libgcc-unwind.map shared-link wall. Upgrade path: add libmd.so to the aarch64
# seed sysroot, then this flag is unnecessary.
final: prev: {
  openssl = prev.openssl.overrideAttrs (o: {
    NIX_LDFLAGS = (o.NIX_LDFLAGS or "") + " --allow-shlib-undefined";
    postPatch = (o.postPatch or "") + ''
      cat > Configurations/50-solaris-aarch64.conf <<'EOF'
      my %targets = (
          "solaris64-aarch64-gcc" => {
              inherit_from     => [ "solaris-common-gcc" ],
              CC               => "gcc",
              CFLAGS           => add_before(picker(default => "-Wall",
                                                    debug   => "-O0 -g",
                                                    release => "-O3")),
              lib_cppflags     => add("-DL_ENDIAN"),
              bn_ops           => "SIXTY_FOUR_BIT_LONG",
              shared_cflag     => "-fPIC",
              shared_ldflag    => add_before("-shared -static-libgcc"),
              multilib         => "/64",
          },
      );
      EOF
    '';
    configureScript = "./Configure solaris64-aarch64-gcc no-asm";
  });
}
