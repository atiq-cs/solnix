#!/usr/bin/env bash
set -e
export PATH=/usr/gnu/bin:/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
G=/root/riscv-port/src/gcc-14.3.0

# 1. install riscv/sol2.h + t-sol2 from the repo copies
cp /root/riscv-port/gcc/sol2.h $G/gcc/config/riscv/sol2.h
cat > $G/gcc/config/riscv/t-sol2 <<'TS'
# riscv64 illumos/Solaris: 64-bit only, no multilib. The riscv base rules
# come from riscv/t-riscv; the Solaris crt/libgcc rules come from t-sol2.
TS

# 2. insert the config.gcc stanza after the riscv freebsd stanza (idempotent)
if ! grep -q "riscv\*-\*-solaris2\*" $G/gcc/config.gcc; then
python3 - "$G/gcc/config.gcc" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = "\nloongarch*-*-linux*)\n"
stanza = '''riscv*-*-solaris2* | riscv*-*-illumos2*)
\t# riscv has no config/riscv/sysv4.h; elfos.h + riscv/elf.h cover the
\t# SVR4/ELF base.  Use the sol2 tail (${cpu_type}/sol2.h sol2.h) directly.
\ttm_file="elfos.h ${tm_file} riscv/elf.h ${sol2_tm_file_tail}"
\ttmake_file="${tmake_file} riscv/t-riscv t-sol2 riscv/t-sol2"
\ttm_defines="${tm_defines} TARGET_DEFAULT_ASYNC_UNWIND_TABLES=1"
\twith_tls=${with_tls:-trad}
\tnative_system_header_dir=/usr/include
\tgcc_cv_initfini_array=yes
\t;;

'''
assert anchor in s, "loongarch anchor not found"
s = s.replace(anchor, "\n" + stanza + anchor[1:], 1)
open(p,"w").write(s)
print("config.gcc patched")
PY
else
echo "config.gcc already patched"
fi
echo SETUP_DONE
