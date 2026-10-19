from PIL import Image, ImageEnhance, ImageFilter
from pathlib import Path
for name in ("desktop-approved", "truck-approved"):
    f=Path("public/branding")/(name+".webp")
    im=Image.open(f).convert("RGB")
    # Reprocesa el recurso publicado: reduce artefactos y aplica interpolación suave.
    im=im.resize((im.width*2, im.height*2),Image.Resampling.LANCZOS)
    im=ImageEnhance.Contrast(im).enhance(1.045)
    im=im.filter(ImageFilter.UnsharpMask(radius=1.5,percent=165,threshold=2))
    im.save(f,"WEBP",quality=96,method=6)
    print(name, im.size, f.stat().st_size)
