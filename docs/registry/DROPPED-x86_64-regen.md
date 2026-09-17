# x86_64-solaris registry rows dropped in the dixi fresh-closure regeneration

These 51 pnames were `published` x86_64-solaris rows in the pre-regeneration
`real-derivations.tsv`. They are the broader userland of the SAME orphaned stdenv
lineage that made the exact-8 rebuild impossible (drifted perl/bash base), so their
closures are invalid (root narinfo may be 200 while references 404 -- see
`cache-invalid-closures.md`). None are referenced by `base` or `dixi`'s starter set.

They were DROPPED rather than preserved because the tsv is a claim -- every row a
real derivation where nix-build works and --query --deriver resolves -- not a
graveyard. History lives in git. When a future config needs one of these, re-run
`scripts/regen-starter-tsv.sh` with it as a root to produce a FRESH valid row from
the current tree; do not copy the old hash back in (it is orphaned and will 404).

## Dropped pnames
```
0.15.2
0.29.2
1
10.4
10.47
1.0.8
1.08.2
1.12.2
1.14
1.1.45
1.18.1
1.26
1.35
1.4.1
1.4.21
1.61
1.6.58
1.8
1.8.0
1.8.2
1.85
20260508
2.10
2.15
2.2.1-unstable
2.46.1
2.6.4
2.73
2.8
3.0.2
3.10.2
3.12
3.3
3.5.2
3.53.3
3.7.0
4.10.0
4.33
4.4.1
4.9
5.4.0
5.4.1
5.8.3
6.0
6.1.3
704
7.10.0
8.3
8.6.16
9.11
9.2.0782
```
