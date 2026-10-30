#!/usr/bin/env python3
# p10p11p12p13.py <gate> : aa64vm FIX= patcher = m4's p10 + p11 (dboot strict-align) + p12 (16550 console) + p13 (ITS BASER page size).
import os, subprocess, sys
H = os.path.dirname(os.path.abspath(__file__))
for p in ('../ena-admin-20261028/p10-ena-admin-poll-recheck.py', 'p11-dboot-strict-align.py',
          'p12-uart-16550.py', 'p13-its-baser-pgsz.py'):
    subprocess.run(['python3', os.path.join(H, p), sys.argv[1]], check=True)
