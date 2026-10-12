import argparse
import base64
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote

expected = 'Basic ' + base64.b64encode(b'fixture:fixture').decode()
requests = []
lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def record(self):
        with lock:
            # Record synthetic checks only, never the actual authorization value.
            requests.append({'path': self.path, 'method': self.command,
                             'authorized': self.headers.get('Authorization') == expected,
                             'cookie_present': self.headers.get('Cookie') is not None})

    def reply(self, code, body=b'', headers=None):
        self.send_response(code)
        self.send_header('Content-Length', str(len(body)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        try:
            self.wfile.write(body)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        self.record()
        path = unquote(self.path)
        if path == '/same-origin-redirect':
            self.reply(302, headers={'Location': '/plain-media', 'Set-Cookie': 'fixture=value'})
        elif path == '/plain-media':
            self.reply(200, b'boundary-media-data')
        elif path == '/protected-media':
            if self.headers.get('Authorization') == expected:
                self.reply(200, b'boundary-protected-media')
            else:
                self.reply(401, headers={'WWW-Authenticate': 'Basic realm="boundary"'})
        elif path == '/external-entity':
            self.reply(200, b'external text should never be loaded')
        elif path == '/unknown-size':
            self.send_response(200)
            self.send_header('Connection', 'close')
            self.end_headers()
            try:
                for _ in range(16):
                    self.wfile.write(b'u' * 65536)
                    self.wfile.flush()
                    time.sleep(0.07)
            except (BrokenPipeError, ConnectionResetError):
                pass
            self.close_connection = True
        elif path == '/known-size':
            self.send_response(200)
            self.send_header('Content-Length', str(16 * 65536))
            self.end_headers()
            try:
                for _ in range(16):
                    self.wfile.write(b'k' * 65536)
                    self.wfile.flush()
                    time.sleep(0.07)
            except (BrokenPipeError, ConnectionResetError):
                pass
        elif path == '/truncated-download':
            self.send_response(200)
            self.send_header('Content-Length', '1000000')
            self.send_header('Connection', 'close')
            self.end_headers()
            self.wfile.write(b'partial')
            self.wfile.flush()
            self.close_connection = True
        elif path == '/chunked-large':
            self.send_response(200)
            self.send_header('Transfer-Encoding', 'chunked')
            self.end_headers()
            try:
                chunk = b'x' * 65536
                for _ in range(129):
                    self.wfile.write(b'10000\r\n' + chunk + b'\r\n')
                    self.wfile.flush()
                self.wfile.write(b'0\r\n\r\n')
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
        elif path == '/metrics':
            with lock:
                payload = json.dumps(requests).encode()
            self.reply(200, payload)
        else:
            self.reply(404, b'missing')

    def do_PROPFIND(self):
        self.record()
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        if self.headers.get('Depth') != '1' or b'propfind' not in body:
            self.reply(400, b'bad request')
            return
        if self.headers.get('Authorization') != expected:
            self.reply(401, headers={'WWW-Authenticate': 'Basic realm="boundary"'})
            return
        if self.path == '/dav-redirect/':
            self.reply(302, headers={'Location': '/dav-valid/'})
        elif self.path == '/dav-valid/':
            self.reply(207, b'<d:multistatus xmlns:d="DAV:"><d:response><d:href>file.mp4</d:href><d:propstat><d:prop><d:displayname>Redirected</d:displayname><d:getcontentlength>19</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>')
        elif self.path == '/dav-cdata/':
            self.reply(207, '<d:multistatus xmlns:d="DAV:"><d:response><d:href><![CDATA[中文%20影片.mp4]]></d:href><d:propstat><d:prop><d:displayname><![CDATA[中文影片]]></d:displayname><d:getcontentlength><![CDATA[19]]></d:getcontentlength></d:prop><d:status><![CDATA[HTTP/1.1 200 OK]]></d:status></d:propstat></d:response></d:multistatus>'.encode())
        elif self.path == '/dav-malformed/':
            self.reply(207, b'<multistatus xmlns="DAV:"><response>')
        elif self.path == '/dav-entity/':
            self.reply(207, f'<?xml version="1.0"?><!DOCTYPE d:multistatus [<!ENTITY external SYSTEM "http://127.0.0.1:{self.server.server_port}/external-entity">]><d:multistatus xmlns:d="DAV:"><d:response><d:href>file.mp4</d:href><d:propstat><d:prop><d:displayname>&external;</d:displayname></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>'.encode())
        elif self.path in ('/dav-403/', '/dav-404/', '/dav-405/'):
            self.reply(int(self.path[5:8]), b'directory refused')
        else:
            self.reply(404, b'missing')


parser = argparse.ArgumentParser(description='Loopback boundary fixture with synthetic credentials only')
parser.add_argument('--port-file', required=True)
options = parser.parse_args()
server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
server.daemon_threads = True
with open(options.port_file, 'w') as file:
    file.write(str(server.server_port))
print('Boundary HTTP fixture listening; credential values are never logged', flush=True)
server.serve_forever()
