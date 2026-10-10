import http.server
from pathlib import Path
import subprocess
import sys
import threading
import time

state = {'revision': 'initial', 'requests': []}
lock = threading.Lock()
bodies = {
    'initial': '测试,#genre#\n甲,https://example.com/a.m3u8\n乙,https://example.com/b.m3u8\n',
    'updated': '测试,#genre#\n乙,https://example.com/b.m3u8\n丙,https://example.com/c.m3u8\n',
    'empty': '测试,#genre#\n',
    'html': '<html><body>not a playlist</body></html>',
}

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path.startswith('/set/'):
            with lock:
                state['revision'] = self.path.removeprefix('/set/')
            code, body = 200, b'OK'
        elif self.path == '/assert-headers':
            with lock:
                requests = list(state['requests'])
            valid = len(requests) >= 6 and all('no-cache' in item[0] and item[1] == 'no-cache' for item in requests)
            code, body = (200 if valid else 500), b'headers checked'
        elif self.path == '/slow.txt':
            time.sleep(0.6)
            code, body = 200, bodies['initial'].encode()
        elif self.path == '/live.txt':
            with lock:
                revision = state['revision']
                state['requests'].append((self.headers.get('Cache-Control', ''), self.headers.get('Pragma', '')))
            if revision == 'http-error':
                code, body = 503, b'temporary outage'
            elif revision == 'encoding':
                code, body = 200, b'\xff\xfe\xfd'
            else:
                code, body = 200, bodies[revision].encode()
        else:
            code, body = 404, b'not found'
        self.send_response(code)
        self.send_header('Content-Type', 'text/plain; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'public, max-age=604800')
        self.end_headers()
        self.wfile.write(body)

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
result = subprocess.run([str(Path(sys.argv[1]).resolve()), f'http://127.0.0.1:{server.server_port}'], timeout=45)
server.shutdown()
sys.exit(result.returncode)
