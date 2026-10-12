import argparse
import base64
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote

counts = {}
lock = threading.Lock()
expected = 'Basic ' + base64.b64encode(b'fixture:fixture').decode()
class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass
    def count(self):
        with lock:
            counts[self.path] = counts.get(self.path, 0) + 1
    def reply(self, code, body=b'', content_type='application/octet-stream', headers=None):
        self.send_response(code)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass
    def do_GET(self):
        self.count()
        path = unquote(self.path)
        if path == '/channels.m3u8':
            self.reply(200, ('\ufeff#EXTM3U\r\n#EXTINF:-1 tvg-logo="/logo.png" group-title="中文频道",电影,频道\r\n/dav/中文 影片.mp4\r\n#EXTINF:-1 group-title="*",第二频道\r\nhttps://example.com/live.m3u8\r\n').encode(), 'application/vnd.apple.mpegurl')
        elif path == '/channels.pls':
            self.reply(200, b'[playlist]\nFile2=/two.mp4\nTitle2=Second\nFile1=/one.mp4\nTitle1=First\n', 'audio/x-scpls')
        elif path == '/unauthorized':
            self.reply(401, b'unauthorized', headers={'WWW-Authenticate': 'Basic realm="fixture"'})
        elif path == '/redirect':
            self.reply(302, headers={'Location': f'http://localhost:{self.server.server_port}/redirect-target'})
        elif path == '/redirect-target':
            self.reply(200, b'ok')
        elif path == '/dav/中文 影片.mp4':
            if self.headers.get('Authorization') != expected:
                self.reply(401, b'unauthorized', headers={'WWW-Authenticate': 'Basic realm="fixture"'})
            else:
                self.reply(200, b'fixture-media-data')
        elif path == '/slow':
            time.sleep(5)
            self.reply(200, b'slow')
        elif path == '/large':
            self.reply(200, b'x' * (8 * 1024 * 1024 + 1))
        elif path == '/timeout':
            time.sleep(30)
            self.reply(200, b'late')
        elif path == '/metrics':
            with lock:
                body = json.dumps(counts).encode()
            self.reply(200, body, 'application/json')
        elif path == '/download-slow':
            self.send_response(200)
            self.send_header('Content-Length', str(256 * 1024))
            self.end_headers()
            try:
                for _ in range(16):
                    self.wfile.write(b'x' * 16384)
                    self.wfile.flush()
                    time.sleep(0.1)
            except (BrokenPipeError, ConnectionResetError):
                pass
        elif path == '/download-long':
            self.send_response(200)
            self.send_header('Content-Length', str(28))
            self.end_headers()
            try:
                for _ in range(28):
                    self.wfile.write(b'x')
                    self.wfile.flush()
                    time.sleep(1)
            except (BrokenPipeError, ConnectionResetError):
                pass
        else:
            self.reply(404, b'missing')
    def do_PROPFIND(self):
        self.count()
        if self.headers.get('Depth') != '1':
            self.reply(400, b'wrong depth')
            return
        if self.headers.get('Authorization') != expected:
            self.reply(401, b'unauthorized', headers={'WWW-Authenticate': 'Basic realm="fixture"'})
            return
        self.reply(207, b'''<?xml version="1.0" encoding="utf-8"?>
<multistatus xmlns="DAV:" xmlns:x="urn:foreign">
 <response><href>/dav/</href><propstat><prop><resourcetype><collection/></resourcetype><displayname>Root</displayname></prop><status>HTTP/1.1 200 OK</status></propstat></response>
 <response><href>folder/</href><propstat><prop><resourcetype><collection/></resourcetype><displayname>Folder</displayname></prop><status>HTTP/1.1 200 OK</status></propstat></response>
 <response><href>%E4%B8%AD%E6%96%87%20%E5%BD%B1%E7%89%87.mp4</href>
  <propstat><prop><displayname>Chinese video</displayname><resourcetype/><getcontentlength>18</getcontentlength><getlastmodified>Sat, 03 Oct 2026 10:00:00 GMT</getlastmodified><x:displayname>Wrong foreign name</x:displayname></prop><status>HTTP/1.1 200 OK</status></propstat>
  <propstat><prop><getcontentlength>9999</getcontentlength><resourcetype><collection/></resourcetype></prop><status>HTTP/1.1 404 Not Found</status></propstat>
 </response>
 <response><href>missing.mp4</href><propstat><prop><displayname>Missing</displayname></prop><status>HTTP/1.1 404 Not Found</status></propstat></response>
 <response><href>http://evil.invalid/file.mp4</href><propstat><prop><displayname>Foreign server</displayname></prop><status>HTTP/1.1 200 OK</status></propstat></response>
</multistatus>''', 'application/xml')

arguments = argparse.ArgumentParser(description='Loopback fixture only; credentials are synthetic.')
arguments.add_argument('--port-file', required=True)
options = arguments.parse_args()
server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
server.daemon_threads = True
with open(options.port_file, 'w') as file:
    file.write(str(server.server_port))
print('Local HTTP fixture listening; request logging disabled', flush=True)
server.serve_forever()
