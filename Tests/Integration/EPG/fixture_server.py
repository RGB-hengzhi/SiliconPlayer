#!/usr/bin/env python3
"""Prepared fixture only. Start explicitly after the frozen player suite ends.

No external network, credentials or non-test files. Runtime evidence directory
must be new. Logs retain route and auth-present flags, never raw credentials.
"""
from __future__ import annotations
import argparse
import base64
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import signal
import struct
import threading
import time
from urllib.parse import urlsplit
import zlib


def png(width: int, height: int) -> bytes:
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    row = b'\0' + bytes((24, 170, 95, 255)) * width
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(row * height)) + chunk(b'IEND', b'')


class Fixture:
    def __init__(self, directory: Path) -> None:
        self.directory = directory
        self.lock = threading.Lock()
        self.now = datetime.now(timezone.utc).replace(microsecond=0)
        self.logo = png(512, 128)
        self.huge_logo = png(4097, 1)
        self.peer_port: int | None = None
        self.mutable_logo_mode = 'good'

    def event(self, data: dict) -> None:
        data['recordedUTC'] = datetime.now(timezone.utc).isoformat()
        with self.lock, (self.directory / 'server-log.jsonl').open('a', encoding='utf-8') as output:
            output.write(json.dumps(data, ensure_ascii=False) + '\n')

    def xml(self, name: str = '正在播放的中文节目') -> bytes:
        stamp = lambda value: value.strftime('%Y%m%d%H%M%S +0000')
        first, boundary, last = self.now - timedelta(minutes=10), self.now + timedelta(minutes=10), self.now + timedelta(minutes=30)
        return (f"<?xml version='1.0' encoding='UTF-8'?><tv>"
                f"<channel id='news.a'><display-name>同名频道</display-name><icon src='/logo.png'/></channel>"
                f"<channel id='news.b'><display-name>同名频道</display-name><icon src='/logo.png'/></channel>"
                f"<programme channel='news.a' start='{stamp(first)}' stop='{stamp(boundary)}'><title>{name}</title><desc>中文描述，按输入偏移显示。</desc></programme>"
                f"<programme channel='news.a' start='{stamp(boundary)}' stop='{stamp(last)}'><title>下一条中文节目</title></programme>"
                f"<programme channel='news.b' start='{stamp(first)}' stop='{stamp(last)}'><title>另一个频道的节目</title></programme>"
                f"</tv>").encode()


def handler(fixture: Fixture):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'
        def log_message(self, *_args):
            pass

        def do_GET(self):
            route = urlsplit(self.path).path
            fixture.event({'kind': 'request', 'route': route, 'port': self.server.server_address[1],
                           'authorizationPresent': bool(self.headers.get('Authorization')),
                           'proxyAuthorizationPresent': bool(self.headers.get('Proxy-Authorization')),
                           'cookiePresent': bool(self.headers.get('Cookie'))})
            if route == '/auth/guide.xml':
                expected = 'Basic ' + base64.b64encode(b'fixture:test-only').decode()
                if self.headers.get('Authorization') != expected:
                    self.send_response(401); self.send_header('WWW-Authenticate', 'Basic realm="EPG fixture"')
                    self.send_header('Content-Length', '0'); self.end_headers(); return
                return self.body(fixture.xml(), 'application/xml')
            if route == '/redirect-logo':
                self.send_response(302)
                self.send_header('Location', f'http://127.0.0.1:{fixture.peer_port}/logo.png')
                self.send_header('Content-Length', '0'); self.end_headers(); return
            if route == '/channels.m3u':
                origin = f'http://127.0.0.1:{self.server.server_address[1]}'
                body = (f'#EXTM3U\n#EXTINF:-1 tvg-id="news.a" tvg-logo="{origin}/logo.png" group-title="节目测试",同名频道\n{origin}/media-a.mp4\n'
                        f'#EXTINF:-1 tvg-id="news.b" tvg-logo="{origin}/logo.png" group-title="节目测试",同名频道\n{origin}/media-b.mp4\n'
                        f'#EXTINF:-1 group-title="节目测试",无ID频道\n{origin}/media-c.mp4\n').encode()
                return self.body(body, 'audio/x-mpegurl')
            if route == '/guide.xml': return self.body(fixture.xml(), 'application/xml', cookie=True)
            if route == '/replacement.xml': return self.body(fixture.xml('新来源的中文节目'), 'application/xml')
            if route == '/bad.xml': return self.body(b'<tv><broken>', 'application/xml')
            if route == '/dtd.xml': return self.body(b'<!DOCTYPE tv [<!ENTITY x "bad">]><tv/>', 'application/xml')
            if route == '/logo.png': return self.body(fixture.logo, 'image/png')
            if route.startswith('/control/logo-'):
                mode = route.removeprefix('/control/logo-')
                if mode not in ['good', 'bad', 'missing']:
                    self.send_response(404); self.send_header('Content-Length', '0'); self.end_headers(); return
                with fixture.lock: fixture.mutable_logo_mode = mode
                return self.body(b'<tv/>', 'application/xml')
            if route == '/mutable-logo.png':
                with fixture.lock: mode = fixture.mutable_logo_mode
                if mode == 'missing':
                    self.send_response(404); self.send_header('Content-Length', '0'); self.end_headers(); return
                return self.body(fixture.logo if mode == 'good' else b'<html>bad refresh</html>', 'image/png')
            if route == '/too-wide.png': return self.body(fixture.huge_logo, 'image/png')
            if route == '/html-as-image': return self.body(b'<html>not a logo</html>', 'image/png')
            if route == '/corrupt.png': return self.body(fixture.logo[:40], 'image/png')
            if route == '/declared-oversize':
                return self.body(b'x' * (1024 * 1024 + 1), 'image/png')
            if route == '/oversize': return self.chunked(route, b'x' * (1024 * 1024 + 1), delay=0)
            if route == '/slow-guide.xml': return self.chunked(route, fixture.xml(), delay=0.3, chunk_size=24)
            if route == '/slow-logo.png': return self.chunked(route, fixture.logo, delay=0.2, chunk_size=24)
            self.send_response(404); self.send_header('Content-Length', '0'); self.end_headers()

        def body(self, data: bytes, content_type: str, cookie: bool = False):
            self.send_response(200); self.send_header('Content-Type', content_type)
            if cookie: self.send_header('Set-Cookie', 'epg_fixture=test-only; Path=/')
            self.send_header('Content-Length', str(len(data))); self.end_headers()
            try: self.wfile.write(data); self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError): pass

        def chunked(self, route: str, data: bytes, delay: float, chunk_size: int = 16384):
            self.send_response(200); self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Transfer-Encoding', 'chunked'); self.end_headers()
            sent = 0
            try:
                for offset in range(0, len(data), chunk_size):
                    chunk = data[offset:offset + chunk_size]
                    self.wfile.write(f'{len(chunk):x}\r\n'.encode() + chunk + b'\r\n'); self.wfile.flush()
                    sent += len(chunk)
                    if delay: time.sleep(delay)
                self.wfile.write(b'0\r\n\r\n'); self.wfile.flush()
                fixture.event({'kind': 'completed', 'route': route, 'bytesSent': sent})
            except (BrokenPipeError, ConnectionResetError, OSError):
                fixture.event({'kind': 'disconnected', 'route': route, 'bytesSent': sent})
    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report-directory', required=True, type=Path)
    args = parser.parse_args()
    args.report_directory.mkdir(parents=True, exist_ok=False)
    fixture = Fixture(args.report_directory)
    servers = [ThreadingHTTPServer(('127.0.0.1', 0), handler(fixture)) for _ in range(2)]
    fixture.peer_port = servers[1].server_address[1]
    for server in servers: server.daemon_threads = True
    metadata = {'status': 'fixture-ready-not-app-tested', 'pid': __import__('os').getpid(),
                'origins': [f'http://127.0.0.1:{server.server_address[1]}' for server in servers],
                'guideAnchorUTC': fixture.now.isoformat(), 'mediaRoutes': 'intentionally return 404; bind existing approved media fixture before app playback validation'}
    (args.report_directory / 'fixture-session.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + '\n')
    stopped = threading.Event()
    def stop(_sig, _frame): stopped.set()
    signal.signal(signal.SIGTERM, stop); signal.signal(signal.SIGINT, stop)
    threads = [threading.Thread(target=server.serve_forever, daemon=True) for server in servers]
    for thread in threads: thread.start()
    print(json.dumps(metadata, ensure_ascii=False), flush=True)
    try:
        while not stopped.wait(0.5): pass
    finally:
        for server in servers: server.shutdown(); server.server_close()
        for thread in threads: thread.join(timeout=2)
        fixture.event({'kind': 'server-stopped'})


if __name__ == '__main__': main()
