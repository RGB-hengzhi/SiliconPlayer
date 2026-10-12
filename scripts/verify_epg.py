#!/usr/bin/env python3
"""Hash-pinned real-app XMLTV/view/logo/cancel/quit checks against owned HTTP.

Internal AppKit APIs drive the app. This is not physical mouse/keyboard testing.
The helper never builds, downloads, modifies daily preferences, or kills existing apps.
"""
from __future__ import annotations
import argparse
import base64
from datetime import datetime, timedelta, timezone
import hashlib
import http.server
import json
import os
import re
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import urllib.parse
from verify_async_screenshots import decode_images

ROOT = Path(__file__).resolve().parent.parent
MAIN_CHECKS = {
    'm3u-tvg-id-original-media', 'actual-source-transport-commits', 'exact-id-mapping-no-name-guess',
    'current-next-and-day-schedule', 'logos-disabled-until-explicit-action', 'manual-id-mapping-persists',
    'actual-anonymous-logo-image', 'actual-hosted-guide-view-png', 'failed-source-preserves-document-preferences',
    'credential-query-session-only', 'restore-no-automatic-network', 'real-request-cancel-preserves-guide',
    'original-channel-plays-real-renderer', 'service-shutdown-drains-owned-jobs',
}


def require(value, message):
    if not value:
        raise RuntimeError(message)


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(4 * 1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def write(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + '\n', encoding='utf-8')


def bundle_inventory(app):
    return {str(p.relative_to(app)): digest(p) for p in sorted(app.rglob('*'))
            if p.is_file() and not p.name.startswith('._')}


def pin_inputs(app):
    data = json.loads((app / 'Contents/Resources/build-provenance.json').read_text())
    require(data['inputFilesUnchanged'], 'Build inputs changed during compilation')
    pins = data['inputFiles']
    require(all(digest(ROOT / name) == sha for name, sha in pins.items()), 'App does not match current frozen build inputs')
    # The helper and raster decoder are explicitly bound even if a future builder
    # changes its default test-input scope.
    for name in ['scripts/verify_epg.py', 'scripts/verify_async_screenshots.py', 'Tests/Integration/ImageMetrics.swift']:
        pins[name] = digest(ROOT / name)
    return pins


class FixtureServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self, media, logo):
        super().__init__(('127.0.0.1', 0), Handler)
        self.media, self.logo = media.read_bytes(), logo.read_bytes()
        self.events, self.lock = [], threading.Lock()
    def event(self, path, kind, **fields):
        with self.lock:
            self.events.append({'path': path, 'event': kind, 'uptime': time.clock_gettime(time.CLOCK_UPTIME_RAW), **fields})


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *_):
        pass
    def do_HEAD(self):
        self.serve(False)
    def do_GET(self):
        self.serve(True)
    def serve(self, body):
        path = urllib.parse.urlsplit(self.path).path
        auth = self.headers.get('Authorization', '')
        correct = auth == 'Basic ' + base64.b64encode(b'guide-user:guide-password').decode()
        self.server.event(path, 'started', authPresent=bool(auth), authCorrect=correct,
                          cookiePresent=bool(self.headers.get('Cookie')), queryPresent='?' in self.path)
        if path in {'/guide.xml', '/bad.xml', '/slow.xml'} and not correct:
            self.send_error(401); return
        if path == '/guide.xml':
            now = datetime.now(timezone.utc)
            stamp = lambda value: value.strftime('%Y%m%d%H%M%S +0000')
            origin = 'http://127.0.0.1:' + str(self.server.server_port)
            data = ('<?xml version="1.0" encoding="UTF-8"?><tv>'
                    '<channel id="alpha.zh"><display-name>中文测试频道</display-name><icon src="' + origin + '/logo.png"/></channel>'
                    '<programme channel="alpha.zh" start="' + stamp(now-timedelta(hours=1)) + '" stop="' + stamp(now+timedelta(hours=1)) + '">'
                    '<title>正在播出的中文节目</title><desc>当前节目、精确频道匹配与匿名台标验证。</desc></programme>'
                    '<programme channel="alpha.zh" start="' + stamp(now+timedelta(hours=1)) + '" stop="' + stamp(now+timedelta(hours=2)) + '">'
                    '<title>下一档节目</title><desc>下一节目和当天日程。</desc></programme></tv>').encode()
            content_type = 'application/xml'
        elif path == '/bad.xml':
            data, content_type = b'<tv><broken', 'application/xml'
        elif path in {'/logo.png', '/slow-logo.png'}:
            data, content_type = self.server.logo, 'image/png'
        elif path in {'/media.mp4', '/manual.mp4'}:
            data, content_type = self.server.media, 'video/mp4'
        elif path == '/slow.xml':
            data, content_type = b'<tv>' + b' ' * 8192 + b'</tv>', 'application/xml'
        else:
            self.send_error(404); return
        slow = path in {'/slow.xml', '/slow-logo.png'}
        media_request = path in {'/media.mp4', '/manual.mp4'}
        total = len(data)
        range_header = self.headers.get('Range') if media_request else None
        content_range = None
        if range_header is not None:
            match = re.fullmatch(r'bytes=(\d*)-(\d*)', range_header.strip())
            start, end = 0, total - 1
            valid = match is not None and bool(match[1] or match[2])
            if valid:
                if match[1]:
                    start = int(match[1]); end = min(int(match[2]), total - 1) if match[2] else total - 1
                    valid = 0 <= start <= end < total
                else:
                    suffix = int(match[2]); valid = suffix > 0
                    start = max(0, total - suffix)
            if not valid:
                self.send_response(416)
                self.send_header('Content-Range', 'bytes */'+str(total))
                self.send_header('Content-Length', '0'); self.send_header('Connection', 'close')
                self.end_headers(); return
            data = data[start:end+1]
            content_range = 'bytes '+str(start)+'-'+str(end)+'/'+str(total)
            self.server.event(path, 'range-served', start=start, end=end, total=total)
        self.send_response(206 if content_range else 200)
        self.send_header('Content-Type', content_type); self.send_header('Content-Length', str(len(data)))
        self.send_header('Connection', 'close')
        if media_request: self.send_header('Accept-Ranges', 'bytes')
        if content_range: self.send_header('Content-Range', content_range)
        if path == '/guide.xml': self.send_header('Set-Cookie', 'guide=verification-only; Path=/')
        self.end_headers()
        if not body: return
        try:
            if slow:
                self.connection.settimeout(1)
                for byte in data:
                    self.wfile.write(bytes([byte])); self.wfile.flush()
                    time.sleep(0.025)  # Only this owned HTTP worker, never app MainActor.
            else:
                self.wfile.write(data); self.wfile.flush()
            self.server.event(path, 'completed')
        except (BrokenPipeError, ConnectionResetError, socket.timeout):
            self.server.event(path, 'client_closed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--expected-app-sha256', required=True)
    parser.add_argument('--report-directory', type=Path, required=True)
    options = parser.parse_args()
    require(__debug__, 'Run without Python -O')
    app, out = options.app.resolve(), options.report_directory.resolve()
    executable = app / 'Contents/MacOS/SiliconPlayer'
    require(app.suffix == '.app' and digest(executable) == options.expected_app_sha256, 'Unexpected app bytes')
    require(not out.exists(), 'Report directory already exists; refusing overwrite')
    out.mkdir(parents=True, exist_ok=False)
    pins, bundle = pin_inputs(app), bundle_inventory(app)
    media, logo = ROOT/'Tests/Fixtures/中文 测试 H264.mp4', ROOT/'Tests/Fixtures/中文 测试 H264.png'
    fixture_pins = {str(p.relative_to(ROOT)): digest(p) for p in [media, logo]}
    write(out/'inputs.json', {'app':str(app),'appSHA256':options.expected_app_sha256,'buildAndHelperInputs':pins,
                             'bundleFiles':bundle,'fixtures':fixture_pins,'scope':'Owned actual app/API/view HTTP tests; no physical input acceptance.'})
    summary = {'startedUTC':datetime.now(timezone.utc).isoformat(),'appSHA256':options.expected_app_sha256,'results':[], 'status':'running'}
    try:
        for mode in ['epg', 'epg-quit-load', 'epg-quit-logo']:
            server = FixtureServer(media, logo)
            thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
            report = out/(mode+'.json')
            process = None
            forced_cleanup = False
            try:
                with tempfile.TemporaryDirectory(prefix='siliconplayer-epg-') as storage, (out/(mode+'.log')).open('w') as log:
                    env = {k:v for k,v in os.environ.items() if not k.startswith('SILICONPLAYER_VERIFY_')}
                    env.update(SILICONPLAYER_VERIFY_MODE=mode,SILICONPLAYER_VERIFY_REPORT=str(report),SILICONPLAYER_VERIFY_STORAGE=storage,
                               SILICONPLAYER_VERIFY_EXIT='1',SILICONPLAYER_VERIFY_EPG_ORIGIN='http://127.0.0.1:'+str(server.server_port))
                    process = subprocess.Popen([str(executable)], env=env, stdout=log, stderr=subprocess.STDOUT)
                    exit_code = process.wait(timeout=75)
                    exited_at = time.clock_gettime(time.CLOCK_UPTIME_RAW)
                    require(exit_code == 0 and report.exists(), 'App failed or omitted EPG report: '+mode)
                    values = json.loads(report.read_text())
                    require(values.get('mode') == mode, 'EPG report describes a different mode')
                    require(values.get('epgPassed') is True and not values.get('failure'), 'EPG app checks failed: '+str(values.get('failure')))
                    checks = values['epgChecks']; ids = {v['id'] for v in checks}
                    require(len(ids)==len(checks) and all(v['passed'] for v in checks), 'Duplicate/failed EPG observations')
                    if mode == 'epg':
                        require(ids == MAIN_CHECKS, 'Main EPG checks missing')
                        values['decodedImages'] = decode_images([Path(values['epgPNG'])])
                    else:
                        if mode == 'epg-quit-load':
                            expected = {'m3u-tvg-id-original-media','actual-guide-request-in-progress','quit-awaits-owned-guide-request'}
                        else:
                            expected = {'m3u-tvg-id-original-media','actual-source-transport-commits','exact-id-mapping-no-name-guess',
                                        'current-next-and-day-schedule','logos-disabled-until-explicit-action','manual-id-mapping-persists',
                                        'quit-awaits-owned-logo-request'}
                        require(ids == expected, 'Quit EPG observations missing: '+mode)
                        require(values['epgJobsActiveAtQuit'] and 0 <= exited_at-values['epgQuitRequestedUptime'] <= 3,
                                'Quit did not naturally finish active EPG work within deadline')
                    for p in [Path(storage)/'epg-verification-preferences.json', *sorted((Path(storage)/'EPGVerificationLogos').glob('*.png'))]:
                        if p.is_file(): shutil.copyfile(p,out/(mode+'-'+p.name))
                    values.update(appSHA256=options.expected_app_sha256,appPID=process.pid,appExitCode=exit_code,
                                  processExitedUptime=exited_at,physicalNativeUIAcceptance=False)
                    write(report,values)
                # Wait for the server to observe the actual URLSession disconnect.
                slow = '/slow-logo.png' if mode=='epg-quit-logo' else '/slow.xml'
                deadline=time.monotonic()+3
                while not any(v['path']==slow and v['event']=='client_closed' for v in server.events) and time.monotonic()<deadline:
                    time.sleep(.05)
                events = list(server.events)
                require(any(v['path']==slow and v['event']=='client_closed' for v in events),'Actual canceled HTTP connection did not close')
                starts=[v for v in events if v['event']=='started']
                require(all(not v['authPresent'] and not v['cookiePresent'] for v in starts if 'logo' in v['path']), 'Source credentials/cookie reached logo')
                require(all(v['authCorrect'] for v in starts if v['path'].endswith('.xml')), 'Source request lost Basic credentials')
                write(out/(mode+'-http.json'),events)
                summary['results'].append({'id':mode,'status':'passed','appSHA256':options.expected_app_sha256,'appExitCode':exit_code,
                                           'observationCount':len(checks),'report':report.name,'forcedCleanup':False})
            finally:
                if process is not None and process.poll() is None:
                    forced_cleanup = True
                    process.terminate()
                    try: process.wait(timeout=3)
                    except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=3)
                server.shutdown(); server.server_close(); thread.join(timeout=2)
                write(out/(mode+'-http.json'),list(server.events))
                write(out/(mode+'-process.json'),{'appPID':process.pid if process is not None else None,
                      'appExitCode':process.returncode if process is not None else None,'forcedCleanup':forced_cleanup,
                      'serverThreadStopped':not thread.is_alive()})
        require(bundle_inventory(app)==bundle,'Bundle changed during EPG verification')
        require(all(digest(ROOT/name)==sha for name,sha in pins.items()),'Build/helper inputs changed during EPG verification')
        require(all(digest(ROOT/name)==sha for name,sha in fixture_pins.items()),'EPG fixtures changed')
        summary.update(status='passed',passed=3,inputsUnchanged=True,bundleUnchanged=True)
    except Exception as error:
        summary.update(status='failed',error=str(error)); raise
    finally:
        summary['finishedUTC']=datetime.now(timezone.utc).isoformat();write(out/'summary.json',summary)
    print('PASS 3 EPG actual application groups; internal observations and PNG decode add no groups')


if __name__ == '__main__':
    main()
