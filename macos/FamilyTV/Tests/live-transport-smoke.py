#!/usr/bin/env python3
"""Headless checks of the same live transport used by the app; no user settings."""
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

seen = set()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        base = f'http://127.0.0.1:{self.server.server_port}'
        if self.headers.get('User-Agent') != 'relay-fixture-agent' or self.headers.get('Referer') != base + '/':
            self.send_error(403); return
        path = urlsplit(self.path).path
        seen.add(path)
        if path == '/redirect':
            self.send_response(302); self.send_header('Location', '/hls/master.m3u8?ticket=fixture')
            self.send_header('Content-Length', '0'); self.end_headers(); return
        if path == '/hls/master.m3u8':
            data = b'#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin?ticket=fixture"\n#EXT-X-MAP:URI="map.bin"\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nmedia.m3u8\n'
        elif path == '/hls/key.bin' and urlsplit(self.path).query == 'ticket=fixture':
            data = b'0123456789abcdef'
        elif path == '/hls/map.bin' and self.headers.get('Range') == 'bytes=2-5':
            data = b'2345'
        elif path == '/hls/media.m3u8':
            data = b'#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10,\nsegment.ts\n#EXT-X-ENDLIST\n'
        elif path == '/hls/segment.ts':
            data = bytes([0x47, 1, 2, 3])
        else:
            self.send_error(404); return
        self.send_response(206 if path == '/hls/map.bin' else 200)
        self.send_header('Content-Type', 'application/vnd.apple.mpegurl' if path.endswith('.m3u8') else 'application/octet-stream')
        if path == '/hls/map.bin': self.send_header('Content-Range', 'bytes 2-5/10')
        if path == '/hls/media.m3u8':
            self.send_header('Transfer-Encoding', 'chunked')
            self.end_headers()
            for part in [data[:13], data[13:]]:
                self.wfile.write(f'{len(part):x};fixture=yes\r\n'.encode() + part + b'\r\n')
            self.wfile.write(b'0\r\n\r\n')
        else:
            self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    result = subprocess.run([sys.argv[1], f'http://127.0.0.1:{server.server_port}'], timeout=45)
    required = {'/redirect', '/hls/master.m3u8', '/hls/key.bin', '/hls/map.bin', '/hls/media.m3u8', '/hls/segment.ts'}
    if result.returncode or not required.issubset(seen): sys.exit(1)
finally:
    server.shutdown()
