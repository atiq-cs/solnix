# Yes — published paths with invalid closures, and they share the same missing leaves

## The question

"Are there cached packages that are not valid in nix closures that should be re-built/cached?" — yes, and the
useful part is *which*, and that they converge.

## What the registry claims vs what is true

`real-derivations.tsv` marks **all 184** x86_64-solaris rows `hermetic_closure = y` and 175 `published`. Both the
"published" and the "hermetic" columns have already been measured wrong in both directions (63 `staged` rows were
actually published; 21 `published` rows were 404). **The columns are stale annotations, not measurements** — a
closure's validity has to be checked by fetch, not read.

## Measured: sampling 40 published roots by full-closure fetch

For each root, fetch its `narinfo` **and every entry in its `References` closure**. A root is valid only if all of
them are 200.

```
valid closures  : 39 / 40
INVALID closures:  1   (less-704)
```

`less` is marked `published` and its own narinfo is 200 — **but its closure is broken**, missing:

```
0mh27ap6…-pcre2-10.47-dev   404
agvfjzh4…-ncurses-6.6       404
d1ksp724…-ncurses-6.6       404
```

## The important part: the invalid closures converge on a tiny leaf set

`less`'s missing references are **the same paths that block `git`** — `pcre2-dev (0mh27)` and `ncurses-6.6`. So the
invalidity is not scattered; it traces to a small set of **unbuilt-and-unstored leaves** shared across many
published roots. **44 registry rows reference `ncurses`/`readline`/`pcre2`/`openssl`** — the candidate blast radius.

⚠️ **`ncurses-6.6` appears under TWO hashes** (`agvfjzh4…` and `d1ksp724…`, the `-dev` output). Both 404. So a fix
must produce both outputs, not just the runtime lib — the same "publish the row, still incomplete" trap as
`pcre2-dev`.

## What follows

The `solnix-dixibuild` run is already rebuilding those exact leaves from source (it builds the *consumers* — `git`,
`curl`, `less`, `nvi` — and publishes whatever closure they reference, which is the only way to get the `0mh27`
hash git and less actually pin). **So closing blocker 7 should validate not just `dixi`'s roots but every other
published root that shares those leaves** — `less` among them.

⚠️ This means "published" in the registry currently over-counts working packages. After the rebuild lands, the
right follow-up is a **one-time full-closure sweep of all 175 published x86_64 roots** (the 40-sample method,
extended), rewriting `published` from a measured closure walk rather than trusting the column. That turns the
registry from an annotation back into a claim — and it is cheap, being pure `narinfo` fetches with no build.

## The rule this establishes

**A narinfo returning 200 does not mean a valid closure.** Four of five names the earlier audit checked, and
`less` here, are 200 on themselves and 404 on a reference. Any future "is it published" check must walk the
`References` closure; the `published` column, and even a single-path `curl`, will lie.
