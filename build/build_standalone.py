# -*- coding: utf-8 -*-
import io,os
D='/home/claude/valdoria-jogo/'
s=io.open(D+'index.html',encoding='utf-8').read()
for f in ['supabase.js','imgdata.js','bgdata.js']:
    tag='<script src="%s"></script>'%f
    assert tag in s, 'falta tag '+f
    js=io.open(D+f,encoding='utf-8').read()
    s=s.replace(tag,'<script>\n/* ==== %s ==== */\n%s\n</script>'%(f,js),1)
assert 'src="supabase.js"' not in s and 'src="imgdata.js"' not in s and 'src="bgdata.js"' not in s
out=D+'valdoria-standalone.html'
io.open(out,'w',encoding='utf-8').write(s)
print('OK ->',os.path.getsize(out),'bytes')
