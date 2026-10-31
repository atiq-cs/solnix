// Copied by solnix (pkgs/illumos/cli/go-c1.nix) into internal/getproviders/ as platform_illumos.go.
// GOOS=illumos, but provider registries publish solaris_<arch> builds only (no illumos_*), and Go's
// solaris binaries run on illumos. So on illumos tofu resolves, caches and locks providers as solaris_<arch>.

package getproviders

func init() { CurrentPlatform.OS = "solaris" }
