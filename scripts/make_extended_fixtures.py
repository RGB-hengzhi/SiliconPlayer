#!/usr/bin/env python3
"""Create reproducible local format fixtures and pin official FFmpeg test samples.

The downloaded samples are local regression inputs, not application resources.
Their SHA-256 values were pinned after direct official HTTPS downloads; MP3 is
also checked against the checksum published by the FFmpeg samples server.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parent.parent
FOLDER = ROOT / 'Tests' / 'Fixtures' / 'extended'
MANIFEST = FOLDER / 'manifest.json'
FFMPEG = ROOT / 'Vendor' / 'tools' / 'ffmpeg'
FFPROBE = ROOT / 'Vendor' / 'tools' / 'ffprobe'
OFFICIAL_SAMPLES = {
    'mp3': {
        'url': 'https://samples.ffmpeg.org/A-codecs/MP3/ascii.mp3',
        'filename': 'ascii.mp3',
        'sha256': '7c72e328ad3fe508ba244d8a20bac3d2c646ceca42341dcb7dc4fbf7bb3badeb',
        'published_md5': '09bb5727c87762bd16d153c2919d8bd2',
        'checksum_source': 'https://samples.ffmpeg.org/A-codecs/MP3/md5sum',
    },
    'vp9': {
        'url': 'https://fate-suite.ffmpeg.org/vp9-test-vectors/vp90-2-2pass-akiyo.webm',
        'filename': 'vp90-2-2pass-akiyo.webm',
        'sha256': '5e58a4ad6c3869d61840503bf4095214cc60e665fa410baa7a45eb3a22df39dc',
        'checksum_source': 'SHA-256 pinned after direct official HTTPS download',
    },
    'av1': {
        'url': 'https://fate-suite.ffmpeg.org/av1/frames_refs_short_signaling.ivf',
        'filename': 'frames_refs_short_signaling.ivf',
        'sha256': 'd9136e7e427a1ec1423823f1d8cee37ed0aa354d16bb6607feb5413436810918',
        'checksum_source': 'SHA-256 pinned after direct official HTTPS download',
    },
}
CASE_IDS = ['h264-720p', 'hevc-720p', 'h264-4k', 'hevc-4k', 'prores', 'flac', 'wav', 'aac', 'mp3', 'vp9', 'av1']


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def probe(path: Path) -> dict:
    raw = subprocess.check_output([str(FFPROBE), '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(path)], timeout=30)
    return json.loads(raw)


def official_sample(codec: str) -> tuple[Path, dict]:
    spec = OFFICIAL_SAMPLES[codec]
    folder = FOLDER / 'sources'
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / spec['filename']
    if not path.is_file() or sha256(path) != spec['sha256']:
        request = Request(spec['url'], headers={'User-Agent': 'SiliconPlayer local format verification'})
        with urlopen(request, timeout=30) as response:
            if not response.geturl().startswith(('https://samples.ffmpeg.org/', 'https://fate-suite.ffmpeg.org/')):
                raise RuntimeError('Official sample redirected outside FFmpeg servers')
            data = response.read(4_000_001)
        if len(data) > 4_000_000 or hashlib.sha256(data).hexdigest() != spec['sha256']:
            raise RuntimeError(f'{codec}: official sample SHA-256 mismatch or excessive size')
        temporary = path.with_suffix(path.suffix + '.download')
        temporary.write_bytes(data)
        temporary.replace(path)
    if 'published_md5' in spec:
        data = path.read_bytes()
        actual = hashlib.md5(data).hexdigest()
        if actual != spec['published_md5']:
            raise RuntimeError(f'{codec}: published FFmpeg sample MD5 mismatch')
    return path, {**spec, 'bytes': path.stat().st_size, 'metadata': probe(path),
                  'usage': 'Local regression only; no redistribution license inferred'}


def case_spec(case_id: str, duration: float) -> tuple[str, str, list[str], dict]:
    tone = ['-f', 'lavfi', '-i', f'sine=frequency=440:sample_rate=48000:duration={duration}']
    common = ['-t', str(duration)]
    generated = {'kind': 'generated', 'source': 'FFmpeg lavfi testsrc2 and sine filters',
                 'documentation': 'https://ffmpeg.org/ffmpeg-filters.html', 'duration_seconds': duration}
    if case_id.startswith(('h264-', 'hevc-')):
        codec, size = case_id.split('-')
        dimensions = '3840x2160' if size == '4k' else '1280x720'
        bitrate = '14M' if size == '4k' else '4M'
        args = ['-f', 'lavfi', '-i', f'testsrc2=size={dimensions}:rate=30:duration={duration}', *tone,
                '-c:v', f'{codec}_videotoolbox', '-allow_sw', '0', '-b:v', bitrate, '-pix_fmt', 'yuv420p',
                '-c:a', 'aac', '-b:a', '128k', '-ac', '2', *common, '-movflags', '+faststart']
        if codec == 'hevc': args += ['-tag:v', 'hvc1']
        return f'{case_id}.mp4', codec, args, {**generated, 'hardware_encoding_required': True, 'encoder': f'{codec}_videotoolbox'}
    if case_id == 'prores':
        args = ['-f', 'lavfi', '-i', f'testsrc2=size=1280x720:rate=30:duration={duration}', *tone,
                '-c:v', 'prores_ks', '-profile:v', '0', '-pix_fmt', 'yuv422p10le', '-threads:v', '2',
                '-c:a', 'pcm_s16le', '-ac', '2', *common]
        return 'prores.mov', 'prores', args, {**generated, 'encoder': 'prores_ks', 'profile': 'Proxy, 4:2:2 10-bit'}
    if case_id in ('flac', 'wav', 'aac'):
        codec = {'flac': 'flac', 'wav': 'pcm_s24le', 'aac': 'aac'}[case_id]
        extension = {'flac': 'flac', 'wav': 'wav', 'aac': 'm4a'}[case_id]
        args = [*tone, '-c:a', codec, '-ac', '2', *common]
        if case_id == 'aac': args += ['-b:a', '192k']
        return f'{case_id}.{extension}', codec, args, {**generated, 'encoder': codec}
    sample, source = official_sample(case_id)
    extension = 'mp3' if case_id == 'mp3' else 'mkv'
    args = ['-stream_loop', '-1', '-i', str(sample), *common, '-map', '0:0', '-c', 'copy']
    return f'{case_id}.{extension}', case_id, args, {'kind': 'official-sample-loop-copy', **source,
             'duration_seconds': duration, 'limitation': 'Looped small official test vector; not representative high-resolution performance'}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('cases', nargs='*', help='Optional fixture IDs: ' + ', '.join(CASE_IDS))
    parser.add_argument('--duration', type=float, default=24, help='Default 24s allows the 18s playback benchmark')
    parser.add_argument('--force', action='store_true')
    args = parser.parse_args()
    if set(args.cases) - set(CASE_IDS):
        parser.error('Unknown fixture ID: ' + ', '.join(sorted(set(args.cases) - set(CASE_IDS))))
    if args.duration < 6 or args.duration > 120:
        parser.error('--duration must be between 6 and 120 seconds')
    if not FFMPEG.is_file() or not FFPROBE.is_file():
        parser.error('Build Vendor/tools/ffmpeg and ffprobe before generating fixtures')
    FOLDER.mkdir(parents=True, exist_ok=True)
    manifest = json.loads(MANIFEST.read_text()) if MANIFEST.is_file() else {'schema': 1, 'cases': []}
    existing = {case['id']: case for case in manifest.get('cases', [])}
    tools = {'ffmpeg_sha256': sha256(FFMPEG), 'ffprobe_sha256': sha256(FFPROBE),
             'ffmpeg_version': subprocess.check_output([str(FFMPEG), '-version'], text=True).splitlines()[0]}
    failures = []
    for case_id in args.cases or CASE_IDS:
        try:
            filename, codec, arguments, source = case_spec(case_id, args.duration)
            output = FOLDER / filename
            cached = existing.get(case_id)
            if args.force or not output.is_file() or not cached or cached.get('duration_requested') != args.duration or sha256(output) != cached.get('sha256'):
                command = [str(FFMPEG), '-hide_banner', '-nostdin', '-y', *arguments, str(output)]
                print(f'Generating {case_id} ({args.duration:g}s)…', flush=True)
                start = time.monotonic()
                with (FOLDER / f'{case_id}-encode.log').open('w') as log:
                    subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=600)
                generated_seconds = time.monotonic() - start
            else:
                command = cached.get('command', [])
                generated_seconds = cached.get('generation_wall_seconds')
            metadata = probe(output)
            streams = metadata.get('streams', [])
            is_video = any(stream.get('codec_type') == 'video' for stream in streams)
            if not any(stream.get('codec_name') == codec for stream in streams):
                raise RuntimeError(f'{case_id}: fixture codec differs from expected {codec}')
            existing[case_id] = {'id': case_id, 'path': str(output.relative_to(ROOT)), 'expected_codec': codec,
                                'video': is_video, 'duration_requested': args.duration, 'sha256': sha256(output),
                                'bytes': output.stat().st_size, 'source': source, 'command': command,
                                'generation_wall_seconds': generated_seconds, 'ffprobe': metadata}
            print(f'PASS fixture {case_id}: {codec}, {output.stat().st_size:,} bytes', flush=True)
        except Exception as error:
            failures.append({'id': case_id, 'error': str(error)})
            existing.pop(case_id, None)
            print(f'FAIL fixture {case_id}: {error}', flush=True)
        manifest = {'schema': 1, 'tools': tools, 'cases': [existing[key] for key in CASE_IDS if key in existing], 'generation_failures': failures}
        MANIFEST.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    (FOLDER / 'format-validation.srt').write_text('1\n00:00:00,000 --> 00:00:24,000\n中文格式覆盖测试 · SiliconPlayer\n', encoding='utf-8')
    return int(bool(failures))


if __name__ == '__main__':
    raise SystemExit(main())
