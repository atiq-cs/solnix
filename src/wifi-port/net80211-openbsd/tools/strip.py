import sys, re
s = open(sys.argv[1], errors='replace').read()
# blank out block and line comments, preserving line count
out = []
i = 0; n = len(s)
while i < n:
    if s.startswith('/*', i):
        j = s.find('*/', i+2)
        j = n if j < 0 else j+2
        out.append(''.join(c if c == '\n' else ' ' for c in s[i:j])); i = j
    elif s.startswith('//', i):
        j = s.find('\n', i); j = n if j < 0 else j
        out.append(' '*(j-i)); i = j
    else:
        out.append(s[i]); i += 1
sys.stdout.write(''.join(out))
