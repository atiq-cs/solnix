import re,glob,collections
fams = {
 'AES_CMAC_*':r'\bAES_CMAC_[A-Za-z]+\s*\(',
 'AES_Encrypt':r'\bAES_Encrypt\s*\(',
 'AES_Setkey':r'\bAES_Setkey\s*\(',
 'aes_key_wrap*':r'\baes_key_(wrap|unwrap)[a-z_]*\s*\(',
 'rc4_*':r'\brc4_[a-z]+\s*\(',
 'arc4random*':r'\barc4random[a-z_]*\s*\(',
 'HMAC_SHA1_*':r'\bHMAC_SHA1_[A-Za-z]+\s*\(',
 'HMAC_SHA256_*':r'\bHMAC_SHA256_[A-Za-z]+\s*\(',
 'HMAC_MD5_*':r'\bHMAC_MD5_[A-Za-z]+\s*\(',
 'michael_*':r'\bmichael_[a-z]+\s*\(',
}
txt = ''.join(open(f,errors='replace').read() for f in sorted(glob.glob('*.c')))
tot=0; names=set()
for k,p in sorted(fams.items()):
    ms=re.findall(p,txt); tot+=len(ms); print(f'  {k:16s} {len(ms):3d}')
    for m in re.finditer(p,txt): names.add(m.group(0).rstrip('( \t'))
print(f'  {"TOTAL calls":16s} {tot:3d}')
print(f'  distinct primitives: {len(names)}')
