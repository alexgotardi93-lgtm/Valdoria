# -*- coding: utf-8 -*-
# Gera um HTML unico com supabase.js, imgdata.js e bgdata.js embutidos.
# Rode de qualquer lugar: python3 build/build_standalone.py
import io, os

D = os.path.dirname(os.path.dirname(os.path.abspath(__file__))) + os.sep  # raiz do repo
s = io.open(D + 'index.html', encoding='utf-8').read()
for f in ['supabase.js', 'imgdata.js', 'bgdata.js']:
    tag = '<script src="%s"></script>' % f
    assert tag in s, 'falta tag ' + f
    js = io.open(D + f, encoding='utf-8').read()
    s = s.replace(tag, '<script>\n/* ==== %s ==== */\n%s\n</script>' % (f, js), 1)
assert 'src="supabase.js"' not in s and 'src="imgdata.js"' not in s and 'src="bgdata.js"' not in s
out = D + 'valdoria-standalone.html'
io.open(out, 'w', encoding='utf-8').write(s)
print('OK ->', os.path.getsize(out), 'bytes')
