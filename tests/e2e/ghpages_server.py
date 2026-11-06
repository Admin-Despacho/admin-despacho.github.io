# Servidor de prueba (incluido en el repositorio para que las pruebas de actualización PWA sean reproducibles).
# "pages": Cache-Control max-age=600 (como GitHub Pages). "heur": sin Cache-Control.
# "stale1": como Pages, pero la PRIMERA vez que se pide la página entrega el index.html ANTERIOR (env STALE_INDEX), como la caché de Pages
#           durante los 10 minutos posteriores a publicar. Sirve el enlace /tmp/serve (las pruebas lo cambian al "publicar").
import http.server, sys, os, threading, hashlib, io
MODE = sys.argv[2] if len(sys.argv) > 2 else 'pages'; ROOT = os.environ.get('OKD_SERVE_ROOT','/tmp/serve'); STALE = os.environ.get('STALE_INDEX'); lock = threading.Lock(); state = {'served': False}
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k): super().__init__(*a, directory=ROOT, **k)
    def send_head(self):
        # Los builds pueden generarse en orden inverso. Last-Modified no identifica su contenido.
        # Pages valida con ETag: nunca devolver 304 de un build distinto por su mtime.
        path = self.translate_path(self.path)
        if os.path.isdir(path): path = os.path.join(path, 'index.html')
        try:
            with open(path, 'rb') as f: body = f.read()
        except OSError:
            self.send_error(404); return None
        etag = '"' + hashlib.sha256(body).hexdigest() + '"'
        if self.headers.get('If-None-Match') == etag:
            self.send_response(304); self.send_header('ETag', etag); self.end_headers(); return None
        self.send_response(200); self.send_header('Content-Type', self.guess_type(path))
        self.send_header('Content-Length', str(len(body))); self.send_header('ETag', etag); self.end_headers()
        return io.BytesIO(body)
    def end_headers(self):
        if MODE in ('pages', 'stale1'): self.send_header('Cache-Control', 'max-age=600')
        super().end_headers()
    def do_GET(self):
        if MODE == 'stale1' and STALE and self.path.split('?')[0] in ('/', '/index.html'):
            with lock:
                if not state['served']:
                    state['served'] = True; body = open(STALE, 'rb').read()
                    self.send_response(200); self.send_header('Content-Type', 'text/html'); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body); return
        return super().do_GET()
    def log_message(self, f, *a): sys.stderr.write((f % a) + '\n')
if __name__ == '__main__':
    http.server.ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
