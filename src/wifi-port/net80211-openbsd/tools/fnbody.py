import sys,re
# extract a top-level C function body by brace matching from a comment-stripped file
path,fn = sys.argv[1],sys.argv[2]
s=open(path,errors='replace').read()
m=re.search(r'^'+re.escape(fn)+r'\s*\(', s, re.M)
if not m: print("NOTFOUND",file=sys.stderr); sys.exit(2)
i=s.index('{',m.end())
d=0
for j in range(i,len(s)):
    if s[j]=='{': d+=1
    elif s[j]=='}':
        d-=1
        if d==0: print(s[i:j+1]); sys.exit(0)
print("UNBALANCED",file=sys.stderr); sys.exit(3)
