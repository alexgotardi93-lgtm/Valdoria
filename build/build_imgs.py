import os,re,io,base64,unicodedata,json
from PIL import Image
SRC="/mnt/user-data/uploads/Desktop/Valdória/Cartas"
def slug(s):
    s=unicodedata.normalize('NFD',s).encode('ascii','ignore').decode()
    return re.sub(r'[^a-z0-9]+','-',s.lower()).strip('-')
imgs={}; sizes=[]; dims=None
for root,_,files in os.walk(SRC):
    for f in sorted(files):
        if not f.lower().endswith('.png'): continue
        name=f.split(' - ',1)[1].rsplit('.',1)[0] if ' - ' in f else f.rsplit('.',1)[0]
        sl=slug(name)
        if sl=='zephyros': sl='zephyros-furia-do-ceu'
        im=Image.open(os.path.join(root,f)).convert('RGB')
        if dims is None: dims=im.size
        w=320; h=round(im.height*w/im.width)
        im=im.resize((w,h),Image.LANCZOS)
        buf=io.BytesIO(); im.save(buf,'JPEG',quality=72,optimize=True)
        b=buf.getvalue(); sizes.append(len(b))
        imgs[sl]='data:image/jpeg;base64,'+base64.b64encode(b).decode()
js='window.CARDIMG='+json.dumps(imgs,ensure_ascii=False,separators=(',',':'))+';'
open('imgdata.js','w').write(js)
tot=sum(sizes)
print(f"cartas={len(imgs)} | orig_dims={dims} | resized_w=320 | avg={tot//len(sizes)//1024}KB | total_raw={tot//1024//1024}MB | js={os.path.getsize('imgdata.js')//1024//1024}MB")
print("slugs faltando? conferindo mismatches:")
