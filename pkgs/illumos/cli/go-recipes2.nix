# cli/go-recipes2.nix -- the maintainer's Go tools solnix lacked (recipes2, 2026-11-02), on goPkg storeOnly (../go-pkg-build.sh in wave6:
# hostfix store tools + the world on PATH, path-gated), so a solnix host rebuilds them. Versions are the build queue's targets.
# No upstream signatures on GitHub tag tarballs: each source is pinned by its sha256 (and the vendor dir by its NAR hash).
# Statically linked (CGO=0), as ./go-tools.nix.
{ goPkg, chk }:
let
  gh = repo: tag: sha256: { url = "https://codeload.github.com/${repo}/tar.gz/refs/tags/${tag}"; inherit sha256; };
  pkg = a: goPkg ({ storeOnly = true; } // a);
in {
  # fx: terminal JSON viewer/processor (MIT). nixpkgs: ldflags -s; version is a const in the source.
  fx = pkg { pname = "fx"; version = "40.0.1"; src = gh "antonmedv/fx" "40.0.1" "311ca3f2ac2fe951c1f662b52e9fbf5ceeed74a2b7c52e8aa98c30001c2ffbb2";
    vendorHash = "sha256-zXS1E3uQmNjV1Io7fNH8+m365A5qAff8QL6NlMchesg=";
    subPkgs = "."; check = chk ''"$out/bin/fx" --version'' "^40\\.0\\.1$" + chk ''echo '{"a":{"b":[1,2,3]}}' | "$out/bin/fx" .a.b[1]'' "^2$"; };
  # github-mcp-server: GitHub's MCP server (MIT). nixpkgs' ldflags (version, commit = the tag, date pinned to the epoch).
  github-mcp-server = pkg { pname = "github-mcp-server"; version = "1.14.0"; src = gh "github/github-mcp-server" "v1.14.0" "0bfb8a505f04f699570db3a712aa38d31ca403b420a26fceb7dc9cad7e52a997";
    vendorHash = "sha256-eGMN0UQbywse8yBQsXnmTorwvQctLxkWZCpWAlxfLY0=";
    subPkgs = "./cmd/github-mcp-server"; ldflags = "-X main.version=1.14.0 -X main.commit=v1.14.0 -X main.date=1970-01-01T00:00:00Z";
    check = chk ''"$out/bin/github-mcp-server" --version'' "^Version: 1\\.14\\.0$" + chk ''"$out/bin/github-mcp-server" --help'' "[-]-toolsets strings"; };   # [-]: chk's grep takes the regex as an option otherwise
  # rclone (MIT): nixpkgs builds it with cmount (cgofuse, FUSE): illumos has no FUSE, so plain build (no mount command), as nixpkgs
  # does where fuse is absent. Man page from the source tree (nixpkgs installManPage rclone.1).
  rclone = pkg { pname = "rclone"; version = "1.75.2"; src = gh "rclone/rclone" "v1.75.2" "68afd7f68c84bd978966feae2116339aa7bf454b39c573910c462e87c3774d5a";
    vendorHash = "sha256-ZblHn8GUkob8cVAEw4SgaOMdAA9UJarDL5kbHyEQ0m4=";
    subPkgs = "."; ldflags = "-X github.com/rclone/rclone/fs.Version=v1.75.2";
    man = ''mkdir -p "$out/share/man/man1"; cp rclone.1 "$out/share/man/man1/"'';
    check = chk ''"$out/bin/rclone" version'' "^rclone v1\\.75\\.2$"
      + chk ''mkdir -p "$W/r/a"; echo hi > "$W/r/a/f"; RCLONE_CONFIG=/nonexistent "$out/bin/rclone" copy "$W/r/a" "$W/r/b" && cat "$W/r/b/f"'' "^hi$"; };
}
