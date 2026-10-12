"""Loopback-only real HTML/media HTTP server with range and bounded delays."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import mimetypes
import re
import threading
import time
from urllib.parse import unquote, urlsplit


class WebMediaServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, directory: Path, event_path: Path):
        super().__init__(("127.0.0.1", 0), WebMediaHandler)
        self.directory = directory.resolve()
        self.event_path = event_path
        self.events = []
        self.lock = threading.Lock()

    def record(self, **value):
        with self.lock:
            self.events.append({"monotonicSeconds": time.monotonic(), **value})
            temporary = self.event_path.with_suffix(".writing")
            temporary.write_text(json.dumps(self.events, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            temporary.replace(self.event_path)


class WebMediaHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_HEAD(self):
        self.serve(False)

    def do_GET(self):
        self.serve(True)

    def serve(self, body):
        address = urlsplit(self.path)
        request_path = unquote(address.path)
        # Delay HTML extraction, not the post-extraction media playback.
        case = request_path.strip("/").split("/")[0]
        slow = case in {"slow-stop", "slow-replace", "slow-quit", "slow-resolver"}
        relative = request_path.lstrip("/")
        if slow:
            relative = "progressive.html" if relative.endswith(".html") else relative.split("/", 1)[-1]
        target = (self.server.directory / relative).resolve()
        if not target.is_relative_to(self.server.directory) or not target.is_file():
            self.send_error(404)
            return
        self.server.record(event="started", path=request_path, case=case,
                           method=self.command, range=self.headers.get("Range", ""), delayed=slow and body and target.suffix == ".html")
        if slow and body and target.suffix == ".html":
            time.sleep(6)
            self.server.record(event="released", path=request_path, case=case)
        size = target.stat().st_size
        start, end = 0, size - 1
        status = 200
        value = self.headers.get("Range")
        if value:
            match = re.fullmatch(r"bytes=(\d*)-(\d*)", value)
            if not match or not any(match.groups()):
                self.send_error(416)
                return
            first, last = match.groups()
            if first:
                start = int(first)
                end = min(int(last), size - 1) if last else size - 1
            else:
                start = max(0, size - int(last))
            if start > end or start >= size:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            status = 206
        self.send_response(status)
        content_type = {".mpd": "application/dash+xml", ".vtt": "text/vtt; charset=utf-8",
                        ".m4s": "video/iso.segment"}.get(target.suffix, mimetypes.guess_type(target.name)[0] or "application/octet-stream")
        self.send_header("Content-Type", content_type)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if body:
            try:
                with target.open("rb") as source:
                    source.seek(start)
                    remaining = end - start + 1
                    while remaining:
                        data = source.read(min(65536, remaining))
                        if not data:
                            break
                        self.wfile.write(data)
                        remaining -= len(data)
            except (BrokenPipeError, ConnectionResetError):
                self.server.record(event="client-disconnected", path=request_path, case=case)
        self.server.record(event="completed", path=request_path, case=case, status=status)
