"""Genera los 7 íconos PWA y el logo de la pantalla de carga DESDE LOS DISEÑOS APROBADOS (una sola vez; el build solo los verifica).
Uso: python3 tools/generar_iconos_aprobados.py <Icono_PWA_APROBADO.png> <Pantalla_de_carga_APROBADA.png>
 · any 192/512: baldosa con esquinas redondeadas transparentes · maskable 192/512: contenido al 80 % dentro de la zona segura, fondo blanco
 · Apple 180: cuadrado sin transparencia (iOS redondea) · favicon 16/32: solo el «OK» · logo de carga: recorte del diseño con fondo transparente."""
import sys
from PIL import Image, ImageDraw
import numpy as np
icon_src, splash_src = sys.argv[1], sys.argv[2]
im = Image.open(splash_src).convert('RGB').crop((135, 233, 805, 553)); a = np.asarray(im).astype(float)
bg = np.median(np.concatenate([a[:6].reshape(-1, 3), a[-6:].reshape(-1, 3)]), axis=0); d = np.sqrt(((a - bg) ** 2).sum(2))
logo = Image.fromarray(np.dstack([a.astype('uint8'), np.clip((d - 18) * 6, 0, 255).astype('uint8')]), 'RGBA'); logo = logo.crop(logo.getbbox()); logo.thumbnail((640, 640), Image.LANCZOS)
logo.save('public/brand/ok-accesorios-splash.png', optimize=True)
ic = Image.open(icon_src).convert('RGB'); A = np.asarray(ic).astype(float); corner = A[5:40, 5:40].reshape(-1, 3).mean(0)
ys, xs = np.where(np.sqrt(((A - corner) ** 2).sum(2)) > 25); side = max(ys.max() - ys.min(), xs.max() - xs.min()); cy, cx = (ys.min() + ys.max()) // 2, (xs.min() + xs.max()) // 2
tile = ic.crop((cx - side // 2, cy - side // 2, cx + side // 2, cy + side // 2)); T = tile.size[0]; inner = tile.crop((int(T * .03), int(T * .03), int(T * .97), int(T * .97)))
def rounded(img, r):
    s = img.size[0]; m = Image.new('L', (s * 4, s * 4), 0); ImageDraw.Draw(m).rounded_rectangle([0, 0, s * 4 - 1, s * 4 - 1], radius=int(s * 4 * r), fill=255)
    o = img.convert('RGBA'); o.putalpha(m.resize((s, s), Image.LANCZOS)); return o
anyi = rounded(inner.resize((1024, 1024), Image.LANCZOS), 0.2)
for n, s in [('icon-512.png', 512), ('icon-192.png', 192)]: anyi.resize((s, s), Image.LANCZOS).save('public/icons/' + n, optimize=True)
for n, s in [('icon-maskable-512.png', 512), ('icon-maskable-192.png', 192)]:
    c = Image.new('RGB', (s, s), (255, 255, 255)); k = int(s * 0.80); c.paste(inner.resize((k, k), Image.LANCZOS), ((s - k) // 2, (s - k) // 2)); c.save('public/icons/' + n, optimize=True)
inner.resize((180, 180), Image.LANCZOS).save('public/icons/apple-touch-icon.png', optimize=True)
ok = inner.crop((int(inner.size[0] * .12), int(inner.size[1] * .12), int(inner.size[0] * .88), int(inner.size[1] * .55))); w, h = ok.size
sq = Image.new('RGB', (w, w), (255, 255, 255)); sq.paste(ok, (0, (w - h) // 2))
for n, s in [('icon-32.png', 32), ('icon-16.png', 16)]: rounded(sq.resize((s * 8, s * 8), Image.LANCZOS), 0.22).resize((s, s), Image.LANCZOS).save('public/icons/' + n, optimize=True)
print('íconos y logo generados desde los diseños aprobados')
