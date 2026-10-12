#!/usr/bin/env python3
"""Remux the generated H.264 fixture into MKV using libmpv, without FFmpeg CLI.

Run from the project root: python3 scripts/remux_fixture.py
Only writes Tests/Fixtures/中文 测试 MKV.mkv and its same-name SRT/ASS.

mpv records demuxer packets rather than rendered frames. Recording is enabled
before loadfile, all selected audio/video tracks are consumed forward to EOF,
and no seeks or stream changes are made. speed=10 affects presentation only;
the recorder copies compressed packet data and codec parameters. The output
is reopened in an independent mpv core and its original-duration tracks checked.

Official references:
https://mpv.io/manual/stable/#options-stream-record
https://github.com/mpv-player/mpv/blob/master/common/recorder.c

The upstream feature is experimental and external subtitles are not recorded;
this fixture keeps the original SRT/ASS as explicit sidecars.
"""

import ctypes as C
import json
import shutil
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
LIBRARY = ROOT / "Vendor/lib/libmpv.2.dylib"
FIXTURES = ROOT / "Tests/Fixtures"
SOURCE = FIXTURES / "中文 测试 H264.mp4"
DESTINATION = FIXTURES / "中文 测试 MKV.mkv"

EVENT_NONE = 0
EVENT_LOG_MESSAGE = 2
EVENT_END_FILE = 7
EVENT_FILE_LOADED = 8
REASON_EOF = 0


class Event(C.Structure):
    _fields_ = [
        ("event_id", C.c_int),
        ("error", C.c_int),
        ("reply_userdata", C.c_uint64),
        ("data", C.c_void_p),
    ]


class EndFile(C.Structure):
    _fields_ = [("reason", C.c_int), ("error", C.c_int), ("playlist_entry_id", C.c_int64)]


class LogMessage(C.Structure):
    _fields_ = [("prefix", C.c_char_p), ("level", C.c_char_p), ("text", C.c_char_p), ("log_level", C.c_int)]


class MPV:
    def __init__(self, paused=False):
        self.lib = C.CDLL(str(LIBRARY))
        signatures = {
            "mpv_create": ([], C.c_void_p),
            "mpv_initialize": ([C.c_void_p], C.c_int),
            "mpv_set_option_string": ([C.c_void_p, C.c_char_p, C.c_char_p], C.c_int),
            "mpv_set_property_string": ([C.c_void_p, C.c_char_p, C.c_char_p], C.c_int),
            "mpv_get_property_string": ([C.c_void_p, C.c_char_p], C.c_void_p),
            "mpv_command": ([C.c_void_p, C.POINTER(C.c_char_p)], C.c_int),
            "mpv_wait_event": ([C.c_void_p, C.c_double], C.POINTER(Event)),
            "mpv_request_log_messages": ([C.c_void_p, C.c_char_p], C.c_int),
            "mpv_error_string": ([C.c_int], C.c_char_p),
            "mpv_free": ([C.c_void_p], None),
            "mpv_terminate_destroy": ([C.c_void_p], None),
        }
        for name, (arguments, result) in signatures.items():
            function = getattr(self.lib, name)
            function.argtypes = arguments
            function.restype = result
        self.handle = self.lib.mpv_create()
        if not self.handle:
            raise RuntimeError("mpv_create failed")
        try:
            options = {
                "vo": "null", "ao": "null", "config": "no", "terminal": "no",
                "idle": "yes", "keep-open": "no", "hwdec": "no",
                "pause": "yes" if paused else "no", "speed": "10",
                "audio-pitch-correction": "no", "framedrop": "no",
                "sub-auto": "no", "audio-file-auto": "no", "ytdl": "no", "load-scripts": "no", "osc": "no",
            }
            for name, value in options.items():
                self.check(self.lib.mpv_set_option_string(self.handle, name.encode(), value.encode()), name)
            self.check(self.lib.mpv_initialize(self.handle), "initialize")
            self.check(self.lib.mpv_request_log_messages(self.handle, b"warn"), "request logs")
        except Exception:
            self.close()
            raise

    def check(self, result, operation):
        if result < 0:
            message = self.lib.mpv_error_string(result).decode("utf-8", "replace")
            raise RuntimeError("{}: {}".format(operation, message))

    def command(self, *arguments):
        encoded = [str(value).encode("utf-8") for value in arguments]
        values = (C.c_char_p * (len(encoded) + 1))(*encoded, None)
        self.check(self.lib.mpv_command(self.handle, values), arguments[0])

    def set(self, name, value):
        self.check(self.lib.mpv_set_property_string(self.handle, name.encode(), str(value).encode("utf-8")), name)

    def get(self, name):
        pointer = self.lib.mpv_get_property_string(self.handle, name.encode())
        if not pointer:
            return ""
        try:
            return C.string_at(pointer).decode("utf-8", "replace")
        finally:
            self.lib.mpv_free(pointer)

    def wait(self, target, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            event = self.lib.mpv_wait_event(self.handle, 0.1).contents
            if event.event_id == EVENT_LOG_MESSAGE and event.data:
                message = C.cast(event.data, C.POINTER(LogMessage)).contents
                if message.prefix and message.text:
                    print("mpv {}: {}".format(message.prefix.decode(), message.text.decode("utf-8", "replace").strip()), file=sys.stderr)
            if event.event_id == EVENT_END_FILE and event.data:
                ending = C.cast(event.data, C.POINTER(EndFile)).contents
                if ending.error < 0:
                    self.check(ending.error, "playback")
                if target == EVENT_END_FILE:
                    if ending.reason != REASON_EOF:
                        raise RuntimeError("Playback did not reach normal EOF: {}".format(ending.reason))
                    return
                raise RuntimeError("Playback ended before loading")
            if event.event_id == target:
                return
        raise TimeoutError("Timed out waiting for mpv event {}".format(target))

    def tracks(self):
        count = int(self.get("track-list/count") or 0)
        return [
            {key: self.get("track-list/{}/{}".format(index, key)) for key in ("id", "type", "codec", "external", "selected")}
            for index in range(count)
        ]

    def close(self):
        if getattr(self, "handle", None):
            self.lib.mpv_terminate_destroy(self.handle)
            self.handle = None


def main():
    if not SOURCE.is_file():
        raise RuntimeError("Generate the source first: swift scripts/make_fixtures.swift")
    for suffix in (".srt", ".ass"):
        sidecar = SOURCE.with_suffix(suffix)
        if not sidecar.is_file():
            raise RuntimeError("Missing source subtitles: {}".format(sidecar))

    recorder = MPV()
    try:
        # Set before opening: setting this after demuxer buffering misses cached packets.
        recorder.set("stream-record", DESTINATION)
        recorder.command("loadfile", SOURCE, "replace")
        recorder.wait(EVENT_FILE_LOADED)
        original_duration = float(recorder.get("duration"))
        original_tracks = recorder.tracks()
        recorder.wait(EVENT_END_FILE)
        # Normal EOF unloads the demuxer and finalizes the stream recorder trailer.
        recorder.set("stream-record", "")
    finally:
        recorder.close()
    if not DESTINATION.is_file() or DESTINATION.stat().st_size < 1024:
        raise RuntimeError("mpv did not create a usable MKV")
    for suffix in (".srt", ".ass"):
        shutil.copyfile(SOURCE.with_suffix(suffix), DESTINATION.with_suffix(suffix))

    verifier = MPV(paused=True)
    try:
        verifier.command("loadfile", DESTINATION, "replace")
        verifier.wait(EVENT_FILE_LOADED)
        duration = float(verifier.get("duration"))
        container = verifier.get("file-format")
        video = verifier.get("video-codec")
        audio = verifier.get("audio-codec")
        tracks = verifier.tracks()
        video_tracks = [track for track in tracks if track["type"] == "video"]
        audio_tracks = [track for track in tracks if track["type"] == "audio"]
        if len(video_tracks) != 1 or video_tracks[0]["codec"] != "h264":
            raise RuntimeError("Remuxed MKV does not contain the original H.264 video: {}".format(tracks))
        if len(audio_tracks) != 1 or audio_tracks[0]["codec"] != "aac":
            raise RuntimeError("Remuxed MKV does not contain the original AAC audio: {}".format(tracks))
        if abs(duration - original_duration) > 0.1 or abs(duration - 12) > 0.1:
            raise RuntimeError("Remuxed duration changed unexpectedly: {} -> {}".format(original_duration, duration))
        if container != "mkv" and "matroska" not in container:
            raise RuntimeError("Output was not recognized as Matroska: {}".format(container))
        for suffix in (".srt", ".ass"):
            verifier.command("sub-add", DESTINATION.with_suffix(suffix), "select")
        subtitle_tracks = [track for track in verifier.tracks() if track["type"] == "sub"]
        if len(subtitle_tracks) != 2:
            raise RuntimeError("Sidecar subtitles did not load: {}".format(subtitle_tracks))
        verifier.set("pause", "no")
        verifier.wait(EVENT_END_FILE)
        print(json.dumps({
            "output": str(DESTINATION), "bytes": DESTINATION.stat().st_size,
            "container": container, "duration": duration, "originalDuration": original_duration,
            "video": video, "audio": audio, "originalTracks": original_tracks,
            "tracks": tracks, "externalSubtitles": subtitle_tracks,
            "method": "libmpv stream-record remux, speed=10, forward playback to EOF",
            "verified": "Independent libmpv core loaded and played MKV to normal EOF",
            "durationNote": "Container timestamp rebasing may add less than 0.1 seconds; codecs remain h264/aac",
        }, ensure_ascii=False, indent=2))
    finally:
        verifier.close()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("MKV 素材生成/验证失败：{}".format(error), file=sys.stderr)
        sys.exit(1)
