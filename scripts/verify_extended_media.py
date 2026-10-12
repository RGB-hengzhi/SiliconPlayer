#!/usr/bin/env python3
"""Prepare and verify additional media cases without implying codec-wide support.

--prepare downloads only two ZIP members from WebM Project's official decoder
suite via strict HTTP ranges, then generates explicitly synthetic boundary cases.
--check-only verifies SHA-256 and ffprobe characteristics without launching the
app. Playback is serial, uses isolated profiles, and pins the executable hash.
"""
from __future__ import annotations
import argparse
from datetime import datetime, timezone
import hashlib
import io
import json
import math
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import time
from urllib.request import Request, urlopen
import xml.etree.ElementTree as ET
import zipfile
import zlib

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
FOLDER = ROOT / 'Tests/Fixtures/ExpandedMedia'
MANIFEST = FOLDER / 'manifest.json'
CATALOG = ROOT / 'Tests/MediaSources/expanded-media.json'
APP = ROOT / 'dist/SiliconPlayer-development.app/Contents/MacOS/SiliconPlayer'
FFMPEG = ROOT / 'Vendor/tools/ffmpeg'
FFPROBE = ROOT / 'Vendor/tools/ffprobe'
WEBM_PAGE = 'https://www.webmproject.org/vp9/levels/'
WEBM_BASE = 'https://storage.googleapis.com/downloads.webmproject.org/vp9/decoder-test-streams/'
OFFICIAL = [
    {'id': 'vp9-official-4k60-8bit', 'archive': 'Profile_0_8bit.zip',
     'archiveBytes': 5793820775, 'etag': '"e037751301d962604beb6caec9d906c8"',
     'member': 'Profile_0_8bit/gf_dist/crowd_run_4096X2176_fr60_bd8_gf_dist_10_l51.webm',
     'offset': 1736249008, 'compressedBytes': 148916992, 'bytes': 148893712,
     'crc32': '6f8a12c1', 'decodedMD5': '452264f6b7ffe583230041b3ef765807',
     'width': 4096, 'height': 2176, 'fps': '60000/1001', 'pixelFormat': 'yuv420p', 'profile': 'Profile 0'},
    {'id': 'vp9-official-4k30-10bit', 'archive': 'Profile_2_10bit.zip',
     'archiveBytes': 5590452653, 'etag': '"f7cf17512a949a5f28205db027f75a9b"',
     'member': 'Profile_2_10bit/gf_dist/crowd_run_4096X2176_fr30_bd10_gf_dist_6_l5.webm',
     'offset': 1569640840, 'compressedBytes': 74084152, 'bytes': 74072423,
     'crc32': '85df49d4', 'decodedMD5': 'd5cda04f0f1fbed06eea0053f6681f3f',
     'width': 4096, 'height': 2176, 'fps': '30/1', 'pixelFormat': 'yuv420p10le', 'profile': 'Profile 2'},
]
CASE_IDS = [item['id'] for item in OFFICIAL] + [
    'hevc-synthetic-8k30', 'mpeg4-avi-pcm', 'mpeg2-ts-mp2', 'vp9-webm-opus',
    'h264-rotation90', 'mpeg2-anamorphic', 'h264-vfr', 'h264-external-flac',
    'wmv2-asf-wma2', 'flv1-flv-aac', 'rv20-realmedia-ra144']


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(4*1024*1024), b''):
            h.update(block)
    return h.hexdigest()


def save(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
    temporary.replace(path)


def probe(path):
    return json.loads(subprocess.check_output([str(FFPROBE), '-v', 'error', '-show_streams',
        '-show_format', '-of', 'json', str(path)], timeout=60))


def video_stream(metadata):
    return next(stream for stream in metadata['streams'] if stream['codec_type'] == 'video')


def range_response(spec, start, end):
    request = Request(WEBM_BASE + spec['archive'], headers={
        'Range': f'bytes={start}-{end}', 'If-Match': spec['etag'],
        'User-Agent': 'SiliconPlayer local decoder verification'})
    response = urlopen(request, timeout=60)
    require(response.geturl() == WEBM_BASE + spec['archive'], 'Archive URL unexpectedly redirected')
    require(response.status == 206, 'Server did not honor bounded range; refusing full archive download')
    require(response.headers.get('Content-Range') == f'bytes {start}-{end}/{spec["archiveBytes"]}',
            'Unexpected range or archive length')
    require(response.headers.get('ETag') == spec['etag'], 'Pinned official archive changed')
    return response


def official_member(spec):
    """Pinned local ZIP header, strict deflate bound, CRC and compressed length."""
    folder = FOLDER / 'sources'; folder.mkdir(parents=True, exist_ok=True)
    output = folder / Path(spec['member']).name
    if output.exists():
        require(output.stat().st_size == spec['bytes'], 'Existing official input has wrong length')
        crc = 0
        with output.open('rb') as f:
            for block in iter(lambda: f.read(1024*1024), b''): crc = zlib.crc32(block, crc)
        require(f'{crc:08x}' == spec['crc32'], 'Existing official input CRC mismatch')
        return output
    with range_response(spec, spec['offset'], spec['offset'] + 29) as response:
        header = response.read(31)
    require(len(header) == 30, 'ZIP header length mismatch')
    values = struct.unpack('<4s5H3I2H', header)
    require(values[0] == b'PK\x03\x04' and values[3] == 8, 'Unexpected ZIP signature/compression')
    require(not values[2] & 1, 'Encrypted ZIP member unsupported')
    require(values[6] == int(spec['crc32'], 16) and values[7] == spec['compressedBytes']
            and values[8] == spec['bytes'], 'Pinned ZIP member metadata changed')
    prefix = values[9] + values[10]
    with range_response(spec, spec['offset'] + 30, spec['offset'] + 29 + prefix) as response:
        extra = response.read(prefix + 1)
    require(len(extra) == prefix and extra[:values[9]].decode() == spec['member'], 'ZIP member name mismatch')
    payload = spec['offset'] + 30 + prefix
    temporary = output.with_suffix('.download')
    decoded_bytes = compressed_bytes = crc = 0
    inflater = zlib.decompressobj(-15)
    try:
        with range_response(spec, payload, payload + spec['compressedBytes'] - 1) as response, temporary.open('wb') as f:
            while True:
                block = response.read(1024*1024)
                if not block: break
                compressed_bytes += len(block)
                require(compressed_bytes <= spec['compressedBytes'], 'Range response exceeded its bound')
                decoded = inflater.decompress(block, spec['bytes'] - decoded_bytes + 1)
                decoded_bytes += len(decoded)
                require(decoded_bytes <= spec['bytes'], 'ZIP decompression exceeded pinned output size')
                crc = zlib.crc32(decoded, crc); f.write(decoded)
            remainder = inflater.flush()
            decoded_bytes += len(remainder); crc = zlib.crc32(remainder, crc); f.write(remainder)
        require(inflater.eof and not inflater.unused_data and not inflater.unconsumed_tail, 'Incomplete/trailing deflate payload')
        require(compressed_bytes == spec['compressedBytes'] and decoded_bytes == spec['bytes'], 'ZIP member size mismatch')
        require(f'{crc:08x}' == spec['crc32'], 'Official ZIP CRC mismatch')
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)
    return output


def encode(case_id, output, arguments):
    command = [str(FFMPEG), '-hide_banner', '-nostdin', '-y', *arguments, str(output)]
    print('PREPARE ' + case_id, flush=True)
    started = time.monotonic()
    with (FOLDER / (case_id + '-prepare.log')).open('w') as log:
        subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT, timeout=900)
    return command, time.monotonic() - started


def generated_spec(case_id):
    tone = ['-f', 'lavfi', '-i', 'sine=frequency=660:sample_rate=48000:duration=24']
    picture = ['-f', 'lavfi', '-i', 'testsrc2=size=720x576:rate=25:duration=24']
    common = ['-t', '24', '-threads:v', '2']
    source = {'kind': 'synthetic', 'generator': 'FFmpeg lavfi testsrc2/sine',
              'documentation': 'https://ffmpeg.org/ffmpeg-filters.html',
              'note': 'Generated test pattern and tone; not filmed content or proof of natural-content image quality.'}
    if case_id == 'hevc-synthetic-8k30':
        args = ['-f', 'lavfi', '-i', 'testsrc2=size=7680x4320:rate=30:duration=24', *tone,
                '-c:v', 'hevc_videotoolbox', '-allow_sw', '0', '-b:v', '30M', '-tag:v', 'hvc1',
                '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '128k', '-ac', '2', *common, '-movflags', '+faststart']
        return '.mp4', 'hevc', args, {**source, 'note': 'Native 7680×4320 generated pattern, not upscaled and not filmed 8K.',
                'encoder': 'hevc_videotoolbox', 'hardwareEncoderRequired': True}
    if case_id == 'mpeg4-avi-pcm':
        return '.avi', 'mpeg4', [*picture, *tone, '-c:v', 'mpeg4', '-q:v', '5', '-c:a', 'pcm_s16le', '-ac', '2', *common], source
    if case_id == 'wmv2-asf-wma2':
        return '.wmv', 'wmv2', [*picture, *tone, '-c:v', 'wmv2', '-q:v', '5', '-c:a', 'wmav2', '-b:a', '128k', '-ac', '2', *common], source
    if case_id == 'flv1-flv-aac':
        return '.flv', 'flv1', [*picture, *tone, '-c:v', 'flv', '-q:v', '5', '-c:a', 'aac', '-b:a', '128k', '-ac', '2', *common], source
    if case_id == 'rv20-realmedia-ra144':
        return '.rm', 'rv20', [*picture, *tone, '-c:v', 'rv20', '-q:v', '5', '-c:a', 'real_144', '-ar', '8000', '-ac', '1', *common], {
                **source, 'note': 'RealVideo 2 / RealAudio 14.4 synthetic regression only; no RMVB/RealVideo 3 or 4 support inferred.'}
    if case_id in ('mpeg2-ts-mp2', 'mpeg2-anamorphic'):
        vf = 'setsar=64/45' if case_id == 'mpeg2-anamorphic' else 'null'
        return '.ts', 'mpeg2video', [*picture, *tone, '-vf', vf, '-c:v', 'mpeg2video', '-q:v', '5', '-g', '12',
                '-c:a', 'mp2', '-b:a', '192k', '-ac', '2', *common], source
    if case_id == 'h264-rotation90':
        input_file = ROOT / 'Tests/Fixtures/extended/h264-720p.mp4'
        return '.mp4', 'h264', ['-display_rotation', '90', '-i', str(input_file), '-c', 'copy'], {
                'kind': 'synthetic-derived-metadata-only', 'input': str(input_file.relative_to(ROOT)),
                'inputSHA256': digest(input_file), 'documentation': 'https://ffmpeg.org/ffmpeg.html#Video-Options',
                'changes': 'Stream copy and 90 degree counter-clockwise display matrix via -display_rotation; no re-encoding.',
                'mpvExpectedClockwiseRotation': 270}
    if case_id == 'h264-vfr':
        return '.mp4', 'h264', ['-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=30:duration=24', *tone,
                '-vf', "select='lt(t,12)+gte(t,12)*not(mod(n,2))'", '-fps_mode', 'vfr',
                '-c:v', 'h264_videotoolbox', '-allow_sw', '0', '-b:v', '4M', '-c:a', 'aac', '-ac', '2', *common], {
                **source, 'timing': '30fps for first 12s; every second input frame retained afterward with original timestamps.'}
    if case_id == 'h264-external-flac':
        return '.mp4', 'h264', ['-i', str(ROOT / 'Tests/Fixtures/extended/h264-720p.mp4'), '-map', '0:v:0', '-c', 'copy'], {
                'kind': 'synthetic-derived-with-sidecar', 'changes': 'H.264 stream copy without internal audio; separate same-basename generated FLAC.',
                'note': 'Verifies automatic external audio discovery and selection; audible output is not independently measured.'}
    if case_id == 'vp9-webm-opus':
        input_file = ROOT / 'Tests/Fixtures/extended/vp9.mkv'
        return '.webm', 'vp9', ['-i', str(input_file), *tone, '-map', '0:v:0', '-map', '1:a:0',
                '-c:v', 'copy', '-c:a', 'opus', '-strict', '-2', '-b:a', '128k', '-ac', '2', '-t', '24'], {
                'kind': 'official-small-vector-derived-with-synthetic-audio', 'input': str(input_file.relative_to(ROOT)),
                'inputSHA256': digest(input_file), 'changes': 'Existing pinned FFmpeg VP9 vector copied to WebM with generated Opus tone.',
                'note': '352×288 test vector; not 4K footage. Retained for local regression only.'}
    raise RuntimeError('Unknown fixture: ' + case_id)


def realmedia_layout(data):
    """Parse the bounded, index-free RM v0 structure of our synthetic fixture."""
    cursor = 0; headers = {}; streams = {}
    require(data[:4] == b'.RMF', 'Synthetic RM signature missing')
    while cursor + 10 <= len(data):
        tag, size, version = struct.unpack_from('>4sIH', data, cursor)
        require(version == 0 and size >= 10, 'Unexpected RM header version/size')
        if tag == b'DATA': break
        require(cursor + size <= len(data), 'RM header exceeds file boundary')
        if tag == b'MDPR':
            require(size >= 44, 'Truncated RM MDPR header')
            stream_id = struct.unpack_from('>H', data, cursor + 10)[0]
            require(stream_id not in streams, 'Duplicate RM stream header')
            location = cursor + 40
            for _ in range(2):
                require(location < cursor + size, 'Truncated RM stream description')
                location += 1 + data[location]
                require(location <= cursor + size, 'RM stream description exceeds header')
            require(location + 4 <= cursor + size, 'Missing RM codec header size')
            codec_size = struct.unpack_from('>I', data, location)[0]; location += 4
            require(location + codec_size == cursor + size, 'RM codec header size mismatch')
            streams[stream_id] = {'offset': cursor, 'codecOffset': location,
                                 'codec': bytes(data[location:location + codec_size])}
        else:
            require(tag not in headers, 'Duplicate RM file header')
            headers[tag] = cursor
        cursor += size
    require(data[cursor:cursor + 4] == b'DATA' and cursor + 18 <= len(data), 'RM DATA header missing')
    count, next_data = struct.unpack_from('>II', data, cursor + 10)
    require(next_data == 0 and count == 1801, 'Unexpected synthetic RM packet count/link')
    packets = []; location = cursor + 18
    for _ in range(count):
        require(location + 12 <= len(data), 'Truncated RM packet header')
        version, length, stream_id, timestamp = struct.unpack_from('>HHHI', data, location)
        require(version == 0 and length >= 12 and location + length <= len(data)
                and stream_id in streams, 'Unexpected RM packet structure')
        packets.append({'offset': location, 'length': length, 'stream': stream_id, 'timestamp': timestamp})
        location += length
    require(data[location:] == bytes(8), 'Unexpected RM index/trailer')
    return headers, streams, cursor, location, packets


def correct_synthetic_realmedia(output):
    """Correct an FFmpeg 9.0.1 RM/RA144 muxer defect; never alter codec payloads.

    rmenc calls av_get_audio_frame_duration2(par, 0); RA144 needs frame_bytes > 0
    to calculate 160 samples per 20 bytes. Consequently the uncorrected muxer
    writes zero audio timestamps, duration, and coded-frame-size fields.
    """
    original = output.read_bytes(); before_sha = hashlib.sha256(original).hexdigest()
    rejected = FOLDER / 'rejected' / ('ra144-zero-pts-' + before_sha[:6]); rejected.mkdir(parents=True, exist_ok=True)
    archived = rejected / output.name
    if archived.exists(): require(digest(archived) == before_sha, 'Rejected RM archive differs')
    else: archived.write_bytes(original)
    headers, streams, data_offset, end, packets = realmedia_layout(original)
    require(set(streams) == {0, 1} and b'RV20' in streams[0]['codec']
            and streams[1]['codec'][:4] == b'.ra\xfd' and b'lpcJ' in streams[1]['codec'], 'Unexpected synthetic RM codecs')
    audio_offset = streams[1]['codecOffset']
    require(struct.unpack_from('>H', original, audio_offset + 48)[0] == 8000
            and struct.unpack_from('>H', original, audio_offset + 54)[0] == 1, 'RA144 sample rate/channel changed')
    audio = [packet for packet in packets if packet['stream'] == 1]
    video = [packet for packet in packets if packet['stream'] == 0]
    require(len(audio) == 1201 and len(video) == 600, 'Synthetic RM cadence/count changed')
    require(all(packet['length'] == 32 and packet['timestamp'] == 0 for packet in audio), 'Expected RA144 zero-timestamp defect absent')
    require(all(packet['timestamp'] == index * 40 for index, packet in enumerate(video)), 'RM video time axis changed')
    require(struct.unpack_from('>I', original, streams[1]['offset'] + 36)[0] == 0
            and struct.unpack_from('>I', original, audio_offset + 24)[0] == 0
            and struct.unpack_from('>H', original, audio_offset + 42)[0] == 0, 'Expected RA144 zero header fields absent')
    fixed = bytearray(original); allowed = set(); changes = []
    def replace(offset, fmt, value, field):
        size = struct.calcsize(fmt); previous = struct.unpack_from(fmt, original, offset)[0]
        struct.pack_into(fmt, fixed, offset, value); allowed.update(range(offset, offset + size))
        changes.append({'offset': offset, 'field': field, 'before': previous, 'after': value})
    for index, packet in enumerate(audio): replace(packet['offset'] + 6, '>I', index * 20, 'RA144 packet timestamp ms')
    replace(streams[1]['offset'] + 36, '>I', len(audio) * 20, 'Audio MDPR duration ms')
    replace(headers[b'PROP'] + 30, '>I', len(audio) * 20, 'PROP duration ms')
    replace(audio_offset + 24, '>I', 20, 'RA144 coded frame bytes')
    replace(audio_offset + 42, '>H', 20, 'RA144 coded frame bytes duplicate')
    old_size = struct.unpack_from('>I', original, data_offset + 4)[0]
    require(old_size == end - data_offset + 18, 'Unexpected FFmpeg RM DATA size')
    replace(data_offset + 4, '>I', end - data_offset, 'DATA chunk byte count')
    require(all(index in allowed for index, (a, b) in enumerate(zip(original, fixed)) if a != b), 'Correction changed unrelated bytes')
    payload_hashes = []
    for index, packet in enumerate(packets):
        start, stop = packet['offset'] + 12, packet['offset'] + packet['length']
        before = hashlib.sha256(original[start:stop]).hexdigest(); after = hashlib.sha256(fixed[start:stop]).hexdigest()
        require(before == after, 'Correction changed compressed packet payload')
        payload_hashes.append({'packet': index, 'stream': packet['stream'], 'bytes': stop - start, 'sha256': before})
    temporary = output.with_suffix('.corrected.tmp'); temporary.write_bytes(fixed); temporary.replace(output)
    decoded = {}
    for stream, codec in (('v', 'rawvideo'), ('a', 'pcm_s16le')):
        results = []
        for path in (archived, output):
            command = [str(FFMPEG), '-v', 'error', '-xerror', '-threads', '2', '-i', str(path),
                       '-map', f'0:{stream}:0', '-c', codec, '-f', 'hash', '-hash', 'sha256', '-']
            result = subprocess.check_output(command, stderr=subprocess.PIPE, text=True, timeout=60).strip()
            results.append({'path': str(path.relative_to(ROOT)), 'hash': result, 'command': command})
        require(results[0]['hash'] == results[1]['hash'] and results[0]['hash'].startswith('SHA256='),
                'RM correction changed complete decoded media content')
        decoded[stream] = results
    correction = {'schema': 1, 'kind': 'synthetic-container-timestamp-correction',
        'upstreamSources': ['https://raw.githubusercontent.com/FFmpeg/FFmpeg/n9.0.1/libavformat/rmenc.c',
            'https://raw.githubusercontent.com/FFmpeg/FFmpeg/n9.0.1/libavcodec/utils.c',
            'https://raw.githubusercontent.com/FFmpeg/FFmpeg/n9.0.1/libavcodec/ra144enc.c'],
        'defect': 'rmenc requests RA144 duration with frame_bytes=0; duration calculation returns zero, causing zero PTS and zero audio header duration/frame size.',
        'algorithm': 'Strictly parse this 600-frame RV20 / 1201-packet RA144 fixture; preserve all compressed payloads and video timestamps; set audio PTS=index*20ms (160samples/8000Hz), duration=24020ms, coded frame size=20bytes, DATA size to parsed packet end.',
        'uncorrectedPath': str(archived.relative_to(ROOT)), 'uncorrectedSHA256': before_sha,
        'correctedSHA256': digest(output), 'payloadPacketsVerified': len(payload_hashes),
        'packetPayloadHashes': payload_hashes, 'changes': changes, 'completeDecodedContentHashes': decoded,
        'note': 'Corrected synthetic regression only. Playback of the original malformed RM is not a synchronization support claim.'}
    evidence_hash = hashlib.sha256(json.dumps(correction, ensure_ascii=False, sort_keys=True).encode()).hexdigest()
    evidence_path = rejected / ('container-correction-' + evidence_hash[:12] + '.json')
    save(evidence_path, correction)
    return {**{key: value for key, value in correction.items() if key not in ('packetPayloadHashes', 'changes')},
            'evidencePath': str(evidence_path.relative_to(ROOT)),
            'evidenceSHA256': digest(evidence_path), 'changedFields': len(changes)}


def verify_characteristics(case, metadata):
    video = video_stream(metadata); expected = case['expected']
    require(video['codec_name'] == expected['codec'], 'Video codec changed')
    for key in ('width', 'height', 'pix_fmt'):
        require(video[key] == expected[key], f'{case["id"]}: unexpected {key}: {video[key]}')
    require(float(metadata['format']['duration']) >= 20, 'Playback fixture is too short')
    require(float(metadata['format']['duration']) >= case['benchmarkSeconds'] + 3,
            'Fixture would loop during benchmark; estimated frame count would reset')
    if case['id'] == 'hevc-synthetic-8k30':
        require(video['codec_name'] == 'hevc' and video['width'] == 7680 and video['height'] == 4320
                and video['avg_frame_rate'] == '30/1', 'Synthetic 8K fixture is not actual 7680×4320/30fps HEVC')
    if case['id'] == 'h264-rotation90':
        rotations = [item.get('rotation') for item in video.get('side_data_list', [])]
        require(90 in rotations, '90-degree display matrix missing')
    if case['id'] == 'mpeg2-anamorphic':
        require(video.get('sample_aspect_ratio') == '64:45' and video.get('display_aspect_ratio') == '16:9', 'Anamorphic SAR/DAR missing')
    if case['id'] == 'h264-vfr':
        values = json.loads(subprocess.check_output([str(FFPROBE), '-v', 'error', '-select_streams', 'v:0',
            '-show_frames', '-show_entries', 'frame=best_effort_timestamp_time', '-of', 'json', str(ROOT / case['path'])], timeout=60))
        timestamps = [float(item['best_effort_timestamp_time']) for item in values['frames']]
        deltas = {round(b-a, 4) for a,b in zip(timestamps, timestamps[1:])}
        require({0.0333, 0.0667}.issubset(deltas), 'VFR fixture lacks both 30fps and 15fps timestamps')
        case['verifiedFrameIntervalsSeconds'] = sorted(deltas)
    if case['id'] == 'h264-external-flac':
        require(not any(stream['codec_type'] == 'audio' for stream in metadata['streams']), 'Sidecar video unexpectedly contains audio')
        sidecar = case['sidecar']; path = ROOT / sidecar['path']
        require(path.is_file() and digest(path) == sidecar['sha256'], 'FLAC sidecar hash mismatch')
        require(probe(path)['streams'][0]['codec_name'] == 'flac', 'Sidecar is not FLAC')
    if case['id'] == 'rv20-realmedia-ra144':
        correction = case['source'].get('containerTimestampCorrection', {})
        require(correction.get('schema') == 1,
                'Synthetic RM lacks explicit timestamp-correction provenance')
        evidence = ROOT / correction['evidencePath']
        require(evidence.is_file() and digest(evidence) == correction['evidenceSHA256']
                and correction['correctedSHA256'] == case['sha256'], 'RM timestamp-correction provenance hash mismatch')
        audio = next(stream for stream in metadata['streams'] if stream['codec_type'] == 'audio')
        require(audio['codec_name'] == 'ra_144' and audio['sample_rate'] == '8000' and audio['channels'] == 1
                and abs(float(audio['duration']) - 24.02) < 0.001, 'RA144 stream duration/rate invalid')
        packets = json.loads(subprocess.check_output([str(FFPROBE), '-v', 'error', '-select_streams', 'a:0',
            '-show_packets', '-show_entries', 'packet=pts_time,dts_time,duration_time,size', '-of', 'json', str(ROOT / case['path'])], timeout=60))['packets']
        require(len(packets) == 1201 and all(packet['size'] == '20'
                and abs(float(packet['pts_time']) - index * 0.02) < 0.000001
                and packet['pts_time'] == packet['dts_time']
                and abs(float(packet['duration_time']) - 0.02) < 0.000001 for index, packet in enumerate(packets)), 'RA144 packets lack strict 20ms time axis')


def prepare(case_ids):
    FOLDER.mkdir(parents=True, exist_ok=True)
    old = json.loads(MANIFEST.read_text()) if MANIFEST.exists() else {}
    known = {case['id']: case for case in old.get('cases', [])}
    for case_id in case_ids:
        existing = known.get(case_id)
        if existing and (ROOT / existing['path']).is_file() and digest(ROOT / existing['path']) == existing['sha256'] \
                and (case_id != 'rv20-realmedia-ra144' or existing['source'].get('containerTimestampCorrection', {}).get('schema') == 1):
            verify_characteristics(existing, probe(ROOT / existing['path'])); print('CACHED ' + case_id, flush=True); continue
        official = next((item for item in OFFICIAL if item['id'] == case_id), None)
        if official:
            member = official_member(official); metadata = probe(member); video = video_stream(metadata)
            require(video['codec_name'] == 'vp9' and video['width'] == official['width'] and video['height'] == official['height'], 'Official input codec/resolution mismatch')
            require(video['pix_fmt'] == official['pixelFormat'] and video['avg_frame_rate'] == official['fps']
                    and video['profile'] == official['profile'], 'Official input profile/bit depth/cadence mismatch')
            output = FOLDER / (case_id + '.webm')
            command, elapsed = encode(case_id, output, ['-stream_loop', '-1', '-i', str(member), '-t', '36', '-map', '0:v:0', '-c', 'copy'])
            source = {'kind': 'official-compressed-decoder-vector-loop-copy', 'author': 'WebM Project test suite / crowd_run source sequence',
                'sourcePage': WEBM_PAGE, 'archiveURL': WEBM_BASE + official['archive'], 'archiveMember': official,
                'input': str(member.relative_to(ROOT)), 'inputSHA256': digest(member), 'inputProbe': metadata,
                'changes': 'Exact ZIP extraction, followed by 36s packet copy/loop; no re-encoding, resizing or frame-rate conversion.',
                'license': 'Official developer decoder test stream; open redistribution license not established.',
                'usage': 'Local player testing only; excluded from app package and redistribution.',
                'note': 'Encoded resolution is verified. Native camera/production provenance at that resolution is not established.'}
        else:
            extension, codec, arguments, source = generated_spec(case_id)
            output = FOLDER / (case_id + extension)
            command, elapsed = encode(case_id, output, arguments)
            if case_id == 'rv20-realmedia-ra144':
                source['containerTimestampCorrection'] = correct_synthetic_realmedia(output)
        metadata = probe(output); video = video_stream(metadata)
        require(video['codec_name'] == ('vp9' if official else codec), 'Generated fixture codec does not match requested codec')
        case = {'id': case_id, 'path': str(output.relative_to(ROOT)), 'bytes': output.stat().st_size,
            'sha256': digest(output), 'source': source, 'command': command, 'preparationWallSeconds': elapsed,
            'ffprobe': metadata, 'expected': {'codec': video['codec_name'], 'width': video['width'],
                'height': video['height'], 'pix_fmt': video['pix_fmt'], 'avg_frame_rate': video['avg_frame_rate']},
            'benchmarkSeconds': 30 if official else 18}
        if case_id == 'h264-external-flac':
            sidecar = output.with_suffix('.flac')
            side_command, _ = encode(case_id + '-sidecar', sidecar, ['-f', 'lavfi', '-i', 'sine=frequency=880:sample_rate=48000:duration=24', '-c:a', 'flac', '-ac', '2'])
            case['sidecar'] = {'path': str(sidecar.relative_to(ROOT)), 'sha256': digest(sidecar), 'bytes': sidecar.stat().st_size, 'command': side_command}
        verify_characteristics(case, metadata)
        known[case_id] = case
        save(MANIFEST, {'schema': 1, 'recordedUTC': datetime.now(timezone.utc).isoformat(),
            'tools': {'ffmpegSHA256': digest(FFMPEG), 'ffprobeSHA256': digest(FFPROBE)},
            'cases': [known[key] for key in CASE_IDS if key in known]})
        print(f'PREPARED {case_id}: {video["codec_name"]} {video["width"]}×{video["height"]}', flush=True)
    manifest = json.loads(MANIFEST.read_text())
    save(CATALOG, {**manifest, 'scope': 'Provenance and acquisition catalog; ignored local media is never included in application resources.',
        'limitations': ['8K case is a generated pattern, not filmed 8K content.', 'Official VP9 cases are copied/looped decoder vectors at 4096×2176, not certified native capture.',
            'Rotation/SAR/VFR cover the specified fixture only.', 'Automatic sidecar track loading is not independent confirmation of physical audible output.',
            'No DRM, HDR output, Dolby Vision or other chips/macOS versions are inferred.']})


def verify_references(case_ids, reports):
    specs = [spec for spec in OFFICIAL if spec['id'] in case_ids]
    if not specs: return []
    url = WEBM_BASE + 'VP9-Decoder-Performance-Test-Streams_metadata.xlsx'
    with urlopen(Request(url, headers={'User-Agent': 'SiliconPlayer decoder checksum verification'}), timeout=30) as response:
        data = response.read(2_000_001)
    require(len(data) <= 2_000_000, 'Official metadata unexpectedly large')
    archive = zipfile.ZipFile(io.BytesIO(data))
    namespace = {'s': 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}
    strings = [''.join(item.itertext()) for item in ET.fromstring(archive.read('xl/sharedStrings.xml')).findall('s:si', namespace)]
    rows = []
    for name in archive.namelist():
        if not name.startswith('xl/worksheets/sheet') or not name.endswith('.xml'): continue
        for row in ET.fromstring(archive.read(name)).findall('.//s:row', namespace):
            values = []
            for cell in row.findall('s:c', namespace):
                value = cell.find('s:v', namespace)
                values.append(strings[int(value.text)] if cell.get('t') == 's' and value is not None else value.text if value is not None else '')
            rows.append(values)
    results = []
    for spec in specs:
        stem = Path(spec['member']).stem
        row = next((row for row in rows if stem in row), None)
        require(row is not None and spec['decodedMD5'] in row, 'Published official decoded checksum does not match pinned value')
        source = FOLDER / 'sources' / Path(spec['member']).name
        command = [str(FFMPEG), '-v', 'error', '-threads', '2', '-i', str(source), '-map', '0:v:0',
            '-an', '-c:v', 'rawvideo', '-pix_fmt', spec['pixelFormat'], '-f', 'md5', '-']
        print('REFERENCE MD5 ' + spec['id'], flush=True)
        started = time.monotonic()
        output = subprocess.check_output(command, text=True, stderr=subprocess.PIPE, timeout=300).strip()
        require(output == 'MD5=' + spec['decodedMD5'], 'Software-decoded frame hash differs from official reference')
        results.append({'id': spec['id'], 'status': 'passed', 'sourceSHA256': digest(source),
            'officialMetadataURL': url, 'officialMetadataSHA256': hashlib.sha256(data).hexdigest(),
            'officialMetadataBytes': len(data), 'publishedRow': row,
            'pixelFormat': spec['pixelFormat'], 'expectedMD5': spec['decodedMD5'], 'actual': output,
            'command': command, 'wallSeconds': time.monotonic()-started, 'ffmpegSHA256': digest(FFMPEG)})
        save(reports/'reference-md5.json', {'recordedUTC': datetime.now(timezone.utc).isoformat(), 'results': results})
        print('REFERENCE PASS ' + spec['id'], flush=True)
    return results


def run_case(case, mode, app, app_hash, reports, timeout):
    from verify_formats import hardware, system_memory, command_text
    name = case['id'] + '-' + mode
    report = reports / (name + '.json'); image = report.with_suffix('.png')
    for stale in (report, image, report.with_suffix('.progress.json')): stale.unlink(missing_ok=True)
    require(digest(app) == app_hash, 'Application changed during verification')
    require(digest(ROOT / case['path']) == case['sha256'], 'Fixture changed before launch: ' + case['id'])
    env = {key:value for key,value in os.environ.items() if not key.startswith('SILICONPLAYER_VERIFY_')}
    env.update(SILICONPLAYER_VERIFY_REPORT=str(report), SILICONPLAYER_VERIFY_MODE=mode,
        SILICONPLAYER_VERIFY_EXIT='1', SILICONPLAYER_VERIFY_SECONDS=str(case['benchmarkSeconds']))
    if mode == 'controls': env['SILICONPLAYER_VERIFY_SUBTITLE'] = str(ROOT / 'Tests/Fixtures/extended/format-validation.srt')
    result = {'id': name, 'fixture': case['path'], 'fixtureSHA256': case['sha256'], 'mode': mode,
        'status': 'failed', 'memoryBefore': system_memory()}
    samples = []; started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix='siliconplayer-expanded-') as profile, report.with_suffix('.log').open('w') as log:
        env['SILICONPLAYER_VERIFY_STORAGE'] = profile
        process = subprocess.Popen([str(app), str(ROOT / case['path'])], env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            while process.poll() is None:
                elapsed = time.monotonic() - started
                require(elapsed <= timeout, 'Application timed out')
                usage = command_text(['ps', '-o', 'rss=,%cpu=', '-p', str(process.pid)]).split()
                if len(usage) == 2: samples.append({'wallSeconds': elapsed, 'residentBytes': int(usage[0])*1024, 'cpuPercent': float(usage[1])})
                time.sleep(.5)
            require(process.returncode == 0 and report.is_file(), 'Application exit/report failed')
            data = json.loads(report.read_text()); result['player'] = data
            require(data.get('mode') == mode, 'Application ran a different verification mode')
            require(data['loaded'] and not data.get('error') and not data.get('failure'), 'Media failed to load cleanly')
            require(any(track['type'] == 'video' and track['codec'] == case['expected']['codec'] for track in data['tracks']), 'Expected video codec absent')
            require(data.get('screenshotExists') and image.is_file() and image.stat().st_size > 3000, 'Rendered screenshot absent')
            require(image.read_bytes()[:8] == b'\x89PNG\r\n\x1a\n', 'Invalid screenshot PNG')
            checks = ['loaded expected video codec', 'valid rendered PNG', 'clean application exit']
            expected_audio = {stream['codec_name'] for stream in case['ffprobe']['streams'] if stream['codec_type'] == 'audio'}
            if expected_audio:
                audio_tracks = [track for track in data['tracks'] if track['type'] == 'audio']
                require(expected_audio.issubset({track['codec'] for track in audio_tracks}), 'Expected audio track codec absent')
                require(any(track['id'] == data['audioID'] and track['codec'] in expected_audio for track in audio_tracks),
                        'Expected audio track was not selected')
                checks.append('expected audio track codecs loaded and selected')
            if mode == 'controls':
                require(data['paused'] and abs(data['speed']-1.5)<.01 and abs(data['volume']-43)<.01, 'Controls failed')
                require(data['abCleared'] and abs(data['abStart']-2)<.1 and abs(data['abEnd']-3)<.1, 'A–B loop failed')
                require(data['subtitleID'] > 0 and 3 < data['position'] < 3.2, 'Subtitle/frame step failed')
                checks += ['pause/seek/speed/volume', 'A–B setting and clear', 'Chinese external subtitle', 'one frame advance']
            else:
                require(data['playedWallSeconds'] >= case['benchmarkSeconds']-.1, 'Playback interval too short')
                require(data['frames'] > 0 and data['physicalFootprintBytes'] > 0, 'No frame advance/physical footprint')
                params = data['videoParams']; expected = case['expected']
                require(params.get('w') == expected['width'] and params.get('h') == expected['height'], 'Decoded dimensions mismatch')
                stable = [sample for sample in data['samples'] if sample['wallSeconds'] >= 3]
                require(len(stable) >= 5, 'Insufficient stable playback samples')
                require(all(math.isfinite(sample['avsync']) and sample['physicalFootprintBytes'] > 0 for sample in stable),
                        'Invalid AV-sync or physical-footprint samples')
                require(data['decoderDrops'] >= 0 and data['renderDrops'] >= 0 and data['fps'] > 0,
                        'Invalid FPS/drop counters')
                fps = float(expected['avg_frame_rate'].split('/')[0])/float(expected['avg_frame_rate'].split('/')[1])
                drops = (data['decoderDrops']+data['renderDrops'])/max(1,fps*data['playedWallSeconds'])
                sync = max((abs(sample['avsync']) for sample in stable), default=0)
                result['quality'] = {'sourceAverageFPS': fps, 'reportedFPS': data['fps'], 'dropRatio': drops,
                    'maxStableAVSyncSeconds': sync, 'target': 'drops ≤1%, stable AV-sync ≤100ms, estimated frames ≥85% of source average cadence',
                    'meetsTarget': drops<=.01 and sync<=.1 and data['frames']>=fps*data['playedWallSeconds']*.85}
                require(result['quality']['meetsTarget'], 'Playback missed frame/drop/sync target')
                checks += ['decoded dimensions', 'continuous playback', 'drop/AV-sync/physical-footprint data', 'cadence/drop/sync target']
                if case['id'] == 'h264-rotation90':
                    # FFmpeg display_rotation is counter-clockwise; mpv uses clockwise degrees.
                    require(params.get('rotate') == 270, 'mpv discarded/misinterpreted source display rotation')
                    checks.append('90 degree counter-clockwise source display rotation retained (mpv 270 clockwise)')
                if case['id'] == 'mpeg2-anamorphic':
                    require(abs(float(params['dw'])/float(params['dh']) - 16/9)<.01, 'mpv anamorphic display geometry incorrect')
                    checks.append('16:9 display geometry for non-square source pixels')
            if case['id'] == 'h264-external-flac':
                require(any(track['codec'] == 'flac' and track['type'] == 'audio' and track['id'] == data['audioID'] for track in data['tracks']),
                        'External FLAC sidecar was not loaded/selected')
                checks.append('automatically discovered and selected external FLAC audio')
            result['checks'] = checks; result['status'] = 'passed'
        except Exception as error:
            result['error'] = str(error)
            if report.exists() and 'player' not in result:
                try: result['player'] = json.loads(report.read_text())
                except (OSError, ValueError): pass
        finally:
            if process.poll() is None: process.kill(); process.wait()
    result['wallSeconds'] = time.monotonic()-started; result['memoryAfter'] = system_memory(); result['processSamples'] = samples
    if samples:
        result['peakResidentBytes'] = max(sample['residentBytes'] for sample in samples)
        result['peakCPUPercent'] = max(sample['cpuPercent'] for sample in samples)
    if image.exists():
        header = image.read_bytes()[:24]
        width, height = struct.unpack('>II', header[16:24]) if len(header) == 24 else (0,0)
        result['screenshot'] = {'path': str(image), 'sha256': digest(image), 'bytes': image.stat().st_size,
            'width': width, 'height': height}
    print(f'{"PASS" if result["status"]=="passed" else "FAIL"} {name}: {result.get("player",{}).get("decoder","unknown")}' + (' — '+result['error'] if 'error' in result else ''), flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepare', action='store_true', help='Download/generate inputs only; does not launch the app')
    parser.add_argument('--check-only', action='store_true', help='Hash and ffprobe verification only')
    parser.add_argument('--reference-md5', action='store_true', help='Also software-decode official originals and compare primary published frame MD5')
    parser.add_argument('--only', nargs='*', help='Optional fixture IDs')
    parser.add_argument('--mode', choices=['controls','benchmark','all'], default='all')
    parser.add_argument('--app', type=Path, default=APP)
    parser.add_argument('--expected-app-sha256', help='Refuse a different executable')
    parser.add_argument('--report-directory', type=Path, default=ROOT / 'Docs/ExtendedTest-2026-10-04')
    parser.add_argument('--timeout', type=float, default=100)
    args = parser.parse_args()
    require(math.isfinite(args.timeout) and args.timeout > 0, '--timeout must be positive and finite')
    case_ids = args.only or CASE_IDS
    require(not (set(case_ids)-set(CASE_IDS)), 'Unknown case ID')
    if args.prepare: prepare(case_ids); return 0
    require(MANIFEST.exists(), 'Prepare fixtures first with --prepare')
    manifest = json.loads(MANIFEST.read_text()); cases = [case for case in manifest['cases'] if case['id'] in case_ids]
    require(len(cases) == len(case_ids), 'Missing requested fixture')
    for case in cases:
        path = ROOT / case['path']; require(path.is_file() and digest(path) == case['sha256'], 'Input hash mismatch: '+case['id'])
        verify_characteristics(case, probe(path)); print('INPUT PASS '+case['id'], flush=True)
    reports = args.report_directory.resolve(); reports.mkdir(parents=True, exist_ok=True)
    catalog_hash = digest(CATALOG)
    app = args.app.resolve()
    if app.suffix == '.app': app = app / 'Contents/MacOS/SiliconPlayer'
    app_hash = None
    if not args.check_only:
        require(app.is_file(), 'Application missing')
        app_hash = digest(app)
        require(not args.expected_app_sha256 or app_hash == args.expected_app_sha256, 'Executable does not match requested SHA-256')
    previous_summary = reports / 'summary.json'
    if previous_summary.exists():
        previous = json.loads(previous_summary.read_text())
        require(previous.get('fixtureCatalogSHA256') == catalog_hash,
                'Report directory contains another fixture catalog; use a new --report-directory to preserve evidence')
        if not args.check_only:
            require(previous.get('appSHA256') == app_hash,
                    'Report directory contains another executable; use a new --report-directory to preserve evidence')
    save(reports/'input-validation.json', {'recordedUTC': datetime.now(timezone.utc).isoformat(),
        'fixtureCatalogSHA256': catalog_hash, 'verificationScriptSHA256': digest(Path(__file__)),
        'tools': {'ffprobeSHA256': digest(FFPROBE), 'ffmpegSHA256': digest(FFMPEG)},
        'passed': len(cases), 'failed': 0, 'cases': [{'id':case['id'], 'sha256':case['sha256'], 'expected':case['expected'],
            'ffprobe':case['ffprobe'], 'source':case['source']} for case in cases]})
    if args.reference_md5: verify_references(case_ids, reports)
    if args.check_only: print(f'{len(cases)} fixtures verified; no app launched', flush=True); return 0
    from verify_formats import hardware
    summary = {'schema': 1, 'startedUTC': datetime.now(timezone.utc).isoformat(), 'hardware': hardware(),
        'appSHA256': app_hash, 'app': str(app), 'fixtureCatalog': str(CATALOG), 'fixtureCatalogSHA256': catalog_hash,
        'verificationScriptSHA256': digest(Path(__file__)),
        'tools': {'ffprobeSHA256': digest(FFPROBE), 'ffmpegSHA256': digest(FFMPEG)}, 'results': [],
        'limits': ['Current Mac, windowed rendering, normal desktop workloads only.',
            '8K is a native-resolution generated test pattern, not natural filmed 8K.',
            '4K VP9 are original official compressed test vectors repeated with packet copy; source capture resolution is not certified.',
            'Frame counts use mpv estimated-frame-number; physical display cadence is not independently measured.',
            'Sound, HDR/EDR, DRM, other chips/macOS versions and native UI are outside this test.']}
    for case in cases:
        for mode in (['controls','benchmark'] if args.mode == 'all' else [args.mode]):
            summary['results'].append(run_case(case, mode, app, app_hash, reports, args.timeout))
            summary['passed'] = sum(result['status']=='passed' for result in summary['results'])
            summary['failed'] = sum(result['status']!='passed' for result in summary['results'])
            save(reports/'summary.json', summary)
    require(digest(app) == app_hash, 'Application changed by end of tests')
    summary['finishedUTC'] = datetime.now(timezone.utc).isoformat(); save(reports/'summary.json', summary)
    print(f'{summary["passed"]} passed, {summary["failed"]} failed', flush=True)
    return int(summary['failed'] > 0)


if __name__ == '__main__':
    raise SystemExit(main())
