#!/usr/bin/env python3
"""Loopback fixtures, ephemeral authentication, and bounded embedded-player checks."""
import base64
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit, quote

binary, fixture_root = sys.argv[1:3]
source_binary = sys.argv[3] if len(sys.argv) > 3 else None
root = Path(fixture_root)
root.mkdir(parents=True, exist_ok=True)
shutil.copytree(Path(__file__).parent / "fixtures", root, dirs_exist_ok=True)
user = 'test-' + secrets.token_hex(4) + '@example'
password = secrets.token_urlsafe(12) + ':@/?#'
expected = 'Basic ' + base64.b64encode((user + ':' + password).encode()).decode()
requests = []
auth_attempts = []

class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(root), **kwargs)
    def log_message(self, *args):
        pass
    def do_HEAD(self):
        self.do_GET()
    def do_GET(self):
        address = urlsplit(self.path)
        query = parse_qs(address.query)
        if address.path.startswith('/dav/'):
            auth_attempts.append((address.path, self.headers.get('Authorization') == expected))
            if self.headers.get('Authorization') != expected:
                self.send_response(401)
                self.send_header('WWW-Authenticate', 'Basic realm="fixture"')
                self.end_headers()
                return
            requests.append(address.path)
            path = root / Path(address.path).name
            if not path.exists():
                self.send_error(404); return
            size = path.stat().st_size
            start, end = 0, size - 1
            range_header = self.headers.get('Range', '')
            if range_header.startswith('bytes='):
                values = range_header[6:].split('-', 1)
                start = int(values[0] or 0); end = min(size - 1, int(values[1]) if values[1] else size - 1)
            if start >= size:
                self.send_response(416); self.end_headers(); return
            self.send_response(206 if range_header else 200)
            self.send_header('Content-Type', 'application/vnd.apple.mpegurl' if path.suffix == '.m3u8' else 'video/mp2t' if path.suffix == '.ts' else 'video/mp4')
            self.send_header('Accept-Ranges', 'bytes')
            self.send_header('Content-Length', str(end - start + 1))
            if range_header: self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
            self.end_headers()
            if self.command != 'HEAD':
                with path.open('rb') as stream:
                    stream.seek(start)
                    try: self.wfile.write(stream.read(end - start + 1))
                    except (BrokenPipeError, ConnectionResetError): pass
            return
        if self.headers.get('Authorization'):
            self.send_error(400, 'Credentials leaked to catalogue')
            return
        port = self.server.server_port
        base = f'http://127.0.0.1:{port}'
        video = {'vod_id': '1', 'vod_name': '测试影片', 'type_name': '电视剧',
                 'vod_play_from': '测试线路',
                 'vod_play_url': f'第1集${base}/dav/sample.m3u8#第2集${base}/dav/sample.mp4'}
        if 't' in query:
            video['vod_name'] = f'第 {query.get("pg",["1"])[0]} 页电视剧'
        if 'wd' in query:
            video['vod_name'] = query['wd'][0]
        if address.path == '/config.json':
            payload = {'sites': [{'name': 'JSON 测试源', 'type': 1, 'api': base + '/api.json'},
                                 {'name': 'Android 测试源', 'type': 3, 'api': 'csp_Test'}]}
        elif address.path == '/api.json':
            payload = {'list': [video], 'pagecount': 3}
            if query.get('ac') == ['list']:
                payload['class'] = [{'type_id': 1, 'type_name': '电影'}, {'type_id': 2, 'type_name': '电视剧'}, {'type_id': 3, 'type_name': '综艺'}]
        elif address.path == '/api.xml':
            classes = '<class><ty id="1">电影</ty><ty id="2">电视剧</ty><ty id="3">综艺</ty></class>' if query.get('ac') != ['videolist'] else ''
            data = f'''<rss>{classes}
<list pagecount="3"><video><id>1</id><name>测试影片</name><type>电视剧</type><tid>2</tid><area>美国</area><year>2026</year><lang>英语</lang><class>悬疑</class><dl>
<dd flag="测试线路"><![CDATA[第1集${base}/dav/sample.m3u8#第2集${base}/dav/sample.mp4]]></dd>
</dl></video></list></rss>'''.encode()
            self.send_response(200); self.send_header('Content-Type', 'application/xml')
            self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
            return
        elif address.path in ['/browse.json', '/slow.json']:
            if address.path == '/slow.json': time.sleep(0.3)
            pg = int(query.get('pg', ['1'])[0])
            payload = {'pagecount': 2, 'list': [{'vod_id': str(100 + pg), 'vod_name': '筛选测试' + str(pg), 'type_id': '10', 'type_name': '欧美剧', 'vod_area': '英国' if pg == 1 else '美国', 'vod_class': '悬疑,犯罪', 'vod_year': '2026'}]}
            if query.get('ac') == ['list']:
                payload['class'] = [{'type_id': '2', 'type_name': '电视剧'}, {'type_id': '10', 'type_pid': '2', 'type_name': '欧美剧'}, {'type_id': '11', 'type_pid': '2', 'type_name': '国产剧'}]
        else:
            self.send_error(404)
            return
        data = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
env = os.environ.copy()
env['FAMILYTV_TEST_USER'] = user
env['FAMILYTV_TEST_PASSWORD'] = password
env['FAMILYTV_TEST_AUTH_BASE_URL'] = f'http://{quote(user,safe="")}:{quote(password,safe="")}@127.0.0.1:{server.server_port}'
try:
    source_only = os.environ.get('FAMILYTV_TEST_SOURCE_ONLY') == '1'
    result = subprocess.CompletedProcess([], 0) if source_only else subprocess.run([binary, str(root.resolve()), f'http://127.0.0.1:{server.server_port}'], env=env, timeout=120)
    if source_binary and result.returncode == 0:
        result = subprocess.run([source_binary, f'http://127.0.0.1:{server.server_port}'], timeout=60)
    required = set() if source_only else {'/dav/sample.mp4', '/dav/sample.m3u8', '/dav/sample.ts'}
    if result.returncode or not required.issubset(requests):
        print('FAIL: playback or authenticated child requests, process result=', result.returncode, auth_attempts); sys.exit(1)
    if not source_only: print('PASS: MP4, HLS playlist and TS child requests authenticated; no credential leakage to catalogue')
finally:
    server.shutdown()
