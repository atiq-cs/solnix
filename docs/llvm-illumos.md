# LLVM on solnix: clang, lld and LLDB 23.1.4

`pkgs/illumos/llvm/` builds LLVM 23.1.4 (llvmorg-23.1.4, 2026-10-20, the newest release; OpenIndiana's clang-23 and
OmniOS's llvm-23 are the same version) from source, split as nixpkgs' `llvmPackages` is:

| attr | what | nixpkgs name |
|---|---|---|
| `llvm` | libLLVM.so, the llvm-* tools, headers, static component libs, lib/cmake/llvm | `llvmPackages.llvm` (out+lib+dev in one) |
| `clang-unwrapped` | clang, libclang, libclang-cpp, the resource headers | `llvmPackages.clang-unwrapped` |
| `lld` | ld.lld and the other flavours | `llvmPackages.lld` |
| `lldb` | lldb with the illumos port | `llvmPackages.lldb` |
| `clang_23` | wrapper: sysroot, gcc runtime, store ld, RUNPATH | `llvmPackages.clang` |

`desktop/gtk/llvm.nix` (llvm-clang 21.1.8, Firefox's bindgen) is separate and unchanged.

Not built: compiler-rt and libcxx. clang uses gcc's libstdc++ and libgcc, as OpenIndiana, OmniOS and nixpkgs on Linux
do. Upstream supports no sanitizers on x86_64 Solaris (clang `Solaris::getSupportedSanitizers`).

## What the illumos patches do (patches/)

- `clang-lld-23-illumos.patch`: clang's Solaris driver knew only Solaris ld and GNU ld, so `-fuse-ld=lld` was "invalid
  linker name", and an absolute ld.lld got Solaris-ld flags ("ld.lld: unknown argument '-C'"). Now lld gets the GNU
  flavour of the link job, plus `-dynamic-linker /usr/lib/amd64/ld.so.1` (GNU ld's sol2 emulation builds that in; lld
  has none). lld learns the `elf_x86_64_sol2` emulation name and marks the output ELFOSABI_SOLARIS.
- `llvm-config-no-build-dir.patch`: llvm-config embedded the build directory (LLVM_SRC_ROOT/LLVM_OBJ_ROOT). It uses
  them only to detect a run from the build tree, so they now name /build.
- `lldb-23-illumos.patch`: covered in the next section.

## LLDB: what works on illumos, and what does not yet

Upstream LLDB 23.1.4 has no illumos support at all. It does not build: illumos `int8_t` is plain `char`, which collides
with `Stream::operator<<(char)`; `offset_t` is ambiguous with `::offset_t`; there is no `<sys/ptrace.h>`, no
`cfmakeraw`, and liblldb's export map uses globs that Solaris ld reads as literal names. It has no host layer and no host
platform (Debugger asserts one exists). It has no native process plugin, and lldb-server is off for SunOS. gdbserver
18.1 has no Solaris target either. Core files fail with "don't know how to parse core file: unsupported OS".

The port adds:

- **Host/solaris** (process info from /proc/<pid>/psinfo and path/a.out) and **Platform/Solaris**, the host platform.
- **illumos core files**: the OS is detected from the CORE NT_UTSNAME note, since illumos cores are ELFOSABI_NONE.
  A solnix core has two PT_NOTE segments: an old-style one (NT_PRSTATUS, NT_PRPSINFO, NT_PRFPREG) and one with NT_PSTATUS
  and an NT_LWPSTATUS per LWP. lldb parses each segment on its own, so only a segment with NT_PSTATUS must have threads.
  (The OpenIndiana build hosts' cores have one segment. An earlier version of the port rejected solnix cores with "no
  NT_LWPSTATUS note".) Threads come from NT_LWPSTATUS: pr_reg is the 28-entry gregset_t, mapped by RegisterContextSolaris_x86_64, and
  pr_fpreg is the FXSAVE area. Also read: NT_PSINFO, NT_AUXV, NT_LWPNAME. SolarisSignals carries illumos numbering
  (SIGUSR1 is 16, SIGSTOP 23, ...). POSIX-DYLD walks the rtld link map, whose first entry is the executable as exec'd.

Works (x86_64): load a binary and its DWARF (image lookup, breakpoint set by file:line, source list, disassemble), and
read a core file (backtrace with function, arguments and file:line; frame variable; global variables; registers; all
threads with LWP names; the signal; the shared-library list).

Does not work yet: `process launch` and `process attach`. A launch with debugging is refused ("debug launch (no illumos
native process plugin)"). Live debugging on solnix is gdb's job (the gdb 18.1 package). A native plugin means a
`NativeProcessSolaris` over /proc control files: PCSTOP/PCRUN/PCSTRACE/PCSFAULT, /proc/<pid>/as for memory,
lwpstatus/PCSREG for registers, PCWATCH for watchpoints, and a fork/exec launch that stops at exec through PR_FORK and
PCSEXIT. It also needs a SunOS target in lldb-server so it runs over gdb-remote like every other native plugin. The
FreeBSD ptrace plugin is the closest model at 1076+343+660 lines (process, thread, x86 registers): an estimated 2000-2500
lines plus testing.

## Reproducibility: the illumos link-editor sorts on heap pointers

llvm-clang 21.1.8 failed `nix-store --check` (104). The same drv built on chef (16 CPUs) and chef2 (48 CPUs) gave
different NARs. Of 3574 files, only lib/libLLVM.so.21.1 differed. Of its 34 sections, only .SUNW_reloc differed. Its
78765 relocations were the same set in a different order: 5 R_AMD64_GLOB_DAT entries moved.

The mechanism is in illumos-gate usr/src/cmd/sgs/libld/common/relocate.c (`do_sorted_outrelocs`, `reloc_compare`):
output relocations are sorted by the address of their `Sym_desc`, a calloc'd struct. ld links libumem, and libumem sizes
its per-CPU caches at 2 x online CPUs, rounded up to a power of two (init_lib.c `umem_get_max_ncpus`). Different CPU
counts give different heap layouts, which give a different relocation order.

Measured on chef2 by relinking the 23.1.4 libLLVM.so with the same command:

| setting | .SUNW_reloc order |
|---|---|
| default (48 CPUs, 128 caches), 6/6 | e59d7cb1 |
| UMEM_OPTIONS=concurrency=64, 2/2 | e59d7cb1 |
| concurrency=32, 16 and 4 | fcd6c983 |
| concurrency=1 | e97a5e79 |
| nomagazines (6/6), nomagazines+concurrency 1/16/32/64 | 087bc018, e8cc9592, b5df404f, b5df404f, 56aaadc7 |
| pstop'd mid-link at 6 offsets (12 runs) | e59d7cb1 (timing does not matter) |
| concurrency=32, TMPDIR length or env size varied | fcd6c983 |

Pinning the CPU count was not enough. With `concurrency=32`, clang 23.1.4 still failed `--check` on one host (1 of 3
rebuilds matched). Again only one file differed (lib/libclang-cpp.so.23.1), again only .SUNW_reloc, and again it was the
same 184951 relocations in a different order. Relinking it with one command and one environment, six times in a row,
gave two orders (A B B B A A). libumem's first reap is the cause. It is armed at init + 1 s (umem.c `umem_reap_next`),
and it runs at the first heap growth after that (vmem.c `vmem_xalloc` -> `vmem_reap`). It empties the magazines, so
allocations after it get different buffers. Which growth that is depends on how fast the link is running. Measured on
chef2 (libclang-cpp, then libLLVM, each with `concurrency=32`):

| setting | orders seen |
|---|---|
| plain, 6 runs | 2 (f281db8b, c56356ea) |
| ASLR off (psecflags -s -aslr) | 2 |
| bound to one CPU (pbind) | 1 (6/6) |
| nomagazines | 3 |
| reap_interval=100000 | 1 plain, but ld stopped at 0.3 s for 2 s gives the other (the first reap is still at 1 s) |
| sbrk_minalloc=1g, plain and stopped at 0.3 s and 2.5 s | 1 (7/7 for each library) |
| libLLVM, plain, stopped at 1, 2.5 or 5 s | fcd6c983 (8/8); stopped at 0.3 s: 02e8eea4 (2/2) |

ld's peak heap is about 380 MB on these links (pmap). With `sbrk_minalloc=1g` the first heap growth covers the whole
link, so the heap never grows again and no reap happens mid-link. The recipes export
`UMEM_OPTIONS=concurrency=32,sbrk_minalloc=1g` for the whole build. The cost is 1 GB of swap reserved per ld while it
runs. This is not llvm-specific: any large link on illumos can do this. The real fix is in ld itself (sort on a stable
key such as the symbol name), and it belongs upstream in illumos-gate.

## Build hosts

The parts other than llvm add `-Wl,-R,<dep>/lib` for llvm (and clang, for lldb). mk-src-pkg's RUNPATH takes a dependency's
`lib/amd64` or `lib-64` only, and LLVM installs its libraries to `lib/`, so without it ld.lld failed its own `--version`
check ("libLLVM.so.23.1: open failed"). Any 64-bit package that installs to `lib/` and is used as a mk-src-pkg dep has the
same problem.

Every tool on the build PATH comes from the store (mk-src-pkg `nativeTools`: cmake, ninja, python3, GNU patch,
coreutils, findutils, the world), so a solnix host can rebuild these. A build fails if any file in $out names the build
directory.
