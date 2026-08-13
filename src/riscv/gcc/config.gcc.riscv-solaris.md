# config.gcc delta for riscv64-unknown-solaris2.11

Applies to gcc-14.3.0 `gcc/config.gcc`.

## 1. New target stanza

Inserted immediately after the `riscv*-*-freebsd*)` stanza (before
`loongarch*-*-linux*`). Mirrors the sparc/x86 solaris arch stanzas but WITHOUT
`${sol2_tm_file_head}`: that head is `elfos.h ${cpu_type}/sysv4.h`, and there is
no `config/riscv/sysv4.h` (build fails at `s-gtype` with "No rule to make
target config/riscv/sysv4.h"). elfos.h + `riscv/elf.h` cover the SVR4/ELF base,
so the stanza names `elfos.h` directly and only appends the tail
(`${cpu_type}/sol2.h sol2.h`) via `${sol2_tm_file_tail}`.

DO NOT also name `riscv/sol2.h` explicitly in the stanza: `${sol2_tm_file_tail}`
is `${cpu_type}/sol2.h sol2.h` = `riscv/sol2.h sol2.h`, so an explicit
`riscv/sol2.h` is a duplicate and `s-gtype` fails with "config/riscv/sol2.h
specified more than once". The tail already pulls the arch sol2.h in.

```sh
riscv*-*-solaris2* | riscv*-*-illumos2*)
	# riscv has no config/riscv/sysv4.h (only i386/sparc ship one), so do NOT
	# use ${sol2_tm_file_head} (= elfos.h ${cpu_type}/sysv4.h); elfos.h +
	# riscv/elf.h already cover the SVR4/ELF base. Use the tail
	# (${cpu_type}/sol2.h sol2.h) directly.
	tm_file="elfos.h ${tm_file} riscv/elf.h riscv/sol2.h ${sol2_tm_file_tail}"
	tmake_file="${tmake_file} riscv/t-riscv t-sol2 riscv/t-sol2"
	tm_defines="${tm_defines} TARGET_DEFAULT_ASYNC_UNWIND_TABLES=1"
	# illumos/Solaris riscv64 is little-endian LP64D only.
	with_tls=${with_tls:-trad}
	# native system headers live in /usr/include as on every solaris arch.
	native_system_header_dir=/usr/include
	# Force .init_array support (as the other riscv stanzas do); GAS has it.
	gcc_cv_initfini_array=yes
	;;
```

NOTE: `t-sol2` and the sol2 c/cxx/d objs are added by the common
`*-*-solaris2*` block (config.gcc lines ~1043-1075), so listing `t-sol2` in the
stanza's `tmake_file` is belt-and-suspenders; `riscv/t-sol2` is the riscv-arch
solaris tmake fragment (below).

## 2. New tmake fragment `gcc/config/riscv/t-sol2`

Minimal — riscv64 solaris is 64-bit only (no multilib), so it just pulls the
riscv builtins/driver rules already provided by `riscv/t-riscv`. A stub is
enough; created so the `tmake_file` reference resolves:

```make
# riscv64 illumos/Solaris: 64-bit only, no multilib. The riscv base rules
# come from riscv/t-riscv; the Solaris crt/libgcc rules come from t-sol2.
```

## 3. config.sub

NO CHANGE NEEDED. gcc-14.3.0 `config.sub riscv64-unknown-solaris2.11`
canonicalizes cleanly to `riscv64-unknown-solaris2.11` (rc=0), because both the
`riscv64` cpu and the `solaris2` os are already known; the combination
validates without a new rule. Proven on the fred node.

## Crib provenance
- Stanza shape: gcc-14.3.0 `riscv*-*-freebsd*` / `riscv*-*-linux*` stanzas +
  the `i[34567]86-*-solaris2* | x86_64-*-solaris2*` and `sparc*-*-solaris2*`
  arch-solaris stanzas (all in the same config.gcc).
- `native_system_header_dir=/usr/include`, `t-sol2`, `sol2_tm_file_*` wiring:
  the common `*-*-solaris2*` block, identical to how aarch64-solaris does it in
  richlowe/gcc.
- `riscv/sol2.h`: richlowe/gcc arm64-gate `aarch64/sol2.h` pattern +
  gcc `i386/sol2.h`.
