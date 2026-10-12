#!/usr/bin/env python3
"""Four real bundled-libmpv DSP groups, using production-generated audio chains.

No SiliconPlayer application, CoreAudio driver or real audio device is started.
The only audio sink is an explicitly selected PCM float WAVE writer. Sources and
results are short deterministic tones; --keep-wav retains output evidence.
"""
import argparse
from array import array
import cmath
import ctypes as C
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import wave

ROOT = Path(__file__).resolve().parents[2]
RATE = 48000
SECONDS = 4
SOURCES = ['Sources/SiliconPlayer/PlayerModelAdvanced.swift',
           'Sources/SiliconPlayer/UserVideoFiltersIntegration.swift',
           'Sources/PlayerCore/PlaybackSettings.swift', 'Sources/PlayerCore/ProcessingSettings.swift']
LIMITS = ['PCM/float output verifies DSP signals, not listening quality or speaker/DAC response.',
          'No CoreAudio device, exclusive output, multichannel hardware or compressed passthrough is certified.',
          'Only +3dB at 1kHz, channel swap, +1 semitone and specified gain/limiter boundaries are covered.',
          'An instrumented PlayerModel compiles extracted production applySettings/setVolume; real filter execution uses bundled libmpv.',
          'The video-configuration dependency is an explicit call-recording stub returning zero; no video configuration, decoder, renderer or lifecycle is tested.',
          'UserVideoFiltersIntegration is a whole-file hash anchor only and is not extracted or compiled by this audio harness.',
          'Secondary-subtitle styling is an explicit typed call recorder returning true; no subtitle property writes, readbacks, dual-subtitle behavior or performance are tested.',
          'Whole MPVEngine hashes are time snapshots; only its extracted setVolume fragment must remain stable during this test.']


def require(value, message):
    if not value:
        raise RuntimeError(message)


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def bytes_hash(value):
    return hashlib.sha256(value).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + '\n')


def fragments():
    source = (ROOT / SOURCES[0]).read_text()
    begin = source.index('    func applySettings() {')
    end = source.index('\n    func refreshAdvancedState()', begin)
    apply = source[begin:end]
    engine = (ROOT / 'Sources/SiliconPlayer/MPVEngine.swift').read_text()
    volume = next(line for line in engine.splitlines() if line.startswith('    func setVolume('))
    return {'applySettings': apply, 'setVolume': volume}


def compile_chains(scratch, reports, regions):
    generated = scratch / 'ProductionAudioSettings.swift'
    generated.write_text('import AppKit\nimport CMPV\nimport PlayerCore\nextension PlayerModel {\n' +
                         '\n'.join(regions.values()) + '\n}\n')
    core = sorted(str(path) for path in (ROOT / 'Sources/PlayerCore').glob('[A-Z]*.swift'))
    module = ['xcrun', 'swiftc', '-emit-library', '-emit-module', '-parse-as-library', '-module-name', 'PlayerCore',
              '-target', 'arm64-apple-macos14.0', *core, '-emit-module-path', str(scratch / 'PlayerCore.swiftmodule'),
              '-o', str(scratch / 'libPlayerCore.dylib')]
    binary = scratch / 'AudioSignalChains'
    compile = ['xcrun', 'swiftc', '-parse-as-library', '-target', 'arm64-apple-macos14.0', '-I', str(scratch),
               '-I', str(ROOT / 'Sources/CMPV'), '-L', str(scratch), '-lPlayerCore', '-L', str(ROOT / 'Vendor/lib'),
               '-lmpv', '-Xlinker', '-rpath', '-Xlinker', str(ROOT / 'Vendor/lib'), '-Xlinker', '-rpath',
               '-Xlinker', str(scratch), str(generated), str(ROOT / 'Tests/Integration/AudioSignalChains.swift'), '-o', str(binary)]
    commands = [('core-compile', module), ('chain-export-compile', compile),
                ('chain-export', [str(binary), str(reports / 'production-chains.json')])]
    for name, command in commands:
        process = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
        (reports / (name + '.log')).write_text(process.stdout)
        require(process.returncode == 0, name + ' failed; see ' + str(reports / (name + '.log')))
    return {case['id']: case for case in json.loads((reports / 'production-chains.json').read_text())['cases']}


def tone(path, channels, floating=False):
    samples = array('f' if floating else 'h')
    for index in range(RATE * SECONDS):
        for terms in channels:
            value = sum(amplitude * math.sin(2 * math.pi * frequency * index / RATE)
                        for frequency, amplitude in terms)
            require(abs(value) < 1, 'Illegal overfull input tone')
            samples.append(value if floating else round(value * 32767))
    if sys.byteorder != 'little':
        samples.byteswap()
    if floating:
        payload = samples.tobytes()
        format = struct.pack('<HHIIHH', 3, 2, RATE, RATE * 8, 8, 32)
        fact = struct.pack('<I', RATE * SECONDS)
        chunks = b'fmt ' + struct.pack('<I', len(format)) + format + b'fact' + struct.pack('<I', len(fact)) + fact
        chunks += b'data' + struct.pack('<I', len(payload)) + payload
        path.write_bytes(b'RIFF' + struct.pack('<I', len(chunks) + 4) + b'WAVE' + chunks)
    else:
        with wave.open(str(path), 'wb') as stream:
            stream.setnchannels(2); stream.setsampwidth(2); stream.setframerate(RATE)
            stream.writeframes(samples.tobytes())
    return {'path': str(path), 'sha256': digest(path), 'rate': RATE, 'channels': 2,
            'sampleFormat': 'IEEE float32' if floating else 'signed PCM16', 'frames': RATE * SECONDS, 'tones': channels}


def read_float_wave(path):
    raw = path.read_bytes()
    require(raw[:4] == b'RIFF' and raw[8:12] == b'WAVE', 'Invalid PCM output RIFF/WAVE header')
    position = 12; format = None; payload = None
    while position + 8 <= len(raw):
        name, length = struct.unpack_from('<4sI', raw, position)
        block = raw[position + 8:position + 8 + length]
        require(len(block) == length, 'Truncated WAVE chunk')
        if name == b'fmt ':
            format = struct.unpack_from('<HHIIHH', block)
            if format[0] == 65534:
                require(len(block) >= 40, 'Invalid extensible WAVE format')
                format = (struct.unpack_from('<H', block, 24)[0], *format[1:])
        elif name == b'data':
            payload = block
        position += 8 + length + (length % 2)
    require(format is not None and payload is not None, 'Missing WAVE format/data')
    encoding, channels, rate, byte_rate, alignment, bits = format
    require(encoding == 3 and bits == 32 and channels == 2 and rate == RATE and alignment == 8,
            'Output must really be stereo 48kHz IEEE float32, got ' + repr(format))
    values = array('f'); values.frombytes(payload)
    if sys.byteorder != 'little': values.byteswap()
    require(len(values) % 2 == 0 and all(math.isfinite(value) for value in values), 'Invalid audio samples')
    frames = len(values) // 2
    require(3.8 * RATE <= frames <= 4.2 * RATE, 'Unexpected processed duration/sample count')
    return [values[0::2], values[1::2]], {'sha256': digest(path), 'bytes': len(raw), 'encoding': 'IEEE float32',
        'rate': rate, 'channels': channels, 'bits': bits, 'frames': frames, 'durationSeconds': frames / rate,
        'allSamplesFinite': True, 'fullPeak': max(abs(value) for value in values)}


def amplitude(values, frequency):
    # Known-frequency orthogonal sine/cosine projection over exactly two seconds.
    segment = values[RATE:3 * RATE]
    step = 2 * math.pi * frequency / RATE
    sine = 0.0; cosine = 1.0; sine_step = math.sin(step); cosine_step = math.cos(step)
    real = imaginary = 0.0
    for value in segment:
        real += value * cosine; imaginary += value * sine
        cosine, sine = cosine * cosine_step - sine * sine_step, sine * cosine_step + cosine * sine_step
    return 2 * math.hypot(real, imaginary) / len(segment)


def frequency(values):
    # Interpolated positive zero crossings of an isolated steady sine; ignores
    # the first/last second so Rubber Band startup/flush is not mistaken for pitch.
    segment = values[RATE:3 * RATE]
    crossings = [index - 1 + (-previous) / (value - previous)
                 for index, (previous, value) in enumerate(zip(segment, segment[1:]), 1)
                 if previous <= 0 < value]
    require(len(crossings) > 100, 'No stable tonal zero crossings')
    return RATE * (len(crossings) - 1) / (crossings[-1] - crossings[0]), len(crossings)


def spectral_frequency(values):
    # Fixed seconds 1-3, Hann window, radix-2 FFT padded to 131072, followed
    # by three-bin log-magnitude interpolation. Search the entire positive
    # spectrum, rather than only accepting a peak near the expected answer.
    segment = values[RATE:3 * RATE]; count = len(segment); length = 131072
    bins = [complex(value * (.5 - .5 * math.cos(2 * math.pi * index / (count - 1))))
            for index, value in enumerate(segment)] + [0j] * (length - count)
    reversed_index = 0
    for index in range(1, length):
        bit = length >> 1
        while reversed_index & bit:
            reversed_index ^= bit; bit >>= 1
        reversed_index ^= bit
        if index < reversed_index:
            bins[index], bins[reversed_index] = bins[reversed_index], bins[index]
    size = 2
    while size <= length:
        root = cmath.exp(-2j * math.pi / size)
        for beginning in range(0, length, size):
            factor = 1
            for offset in range(size // 2):
                even = bins[beginning + offset]; odd = bins[beginning + offset + size // 2] * factor
                bins[beginning + offset] = even + odd; bins[beginning + offset + size // 2] = even - odd
                factor *= root
        size *= 2
    peak = max(range(1, length // 2 - 1), key=lambda index: abs(bins[index]))
    before, center, after = [math.log(max(1e-100, abs(bins[index]))) for index in (peak - 1, peak, peak + 1)]
    shift = .5 * (before - after) / (before - 2 * center + after)
    return {'frequencyHz': (peak + shift) * RATE / length, 'peakBin': peak,
            'binSpacingHz': RATE / length, 'FFTLength': length, 'windowSamples': count, 'window': 'Hann, seconds 1-3'}


def render_worker(config):
    library = C.CDLL(config['library'])
    class Event(C.Structure):
        _fields_ = [('event_id', C.c_int), ('error', C.c_int), ('reply_userdata', C.c_uint64), ('data', C.c_void_p)]
    class EndFile(C.Structure):
        _fields_ = [('reason', C.c_int), ('error', C.c_int)]
    class Log(C.Structure):
        _fields_ = [('prefix', C.c_char_p), ('level', C.c_char_p), ('text', C.c_char_p), ('log_level', C.c_int)]
    library.mpv_create.restype = C.c_void_p
    library.mpv_set_option_string.argtypes = [C.c_void_p, C.c_char_p, C.c_char_p]
    library.mpv_set_property_string.argtypes = [C.c_void_p, C.c_char_p, C.c_char_p]
    library.mpv_initialize.argtypes = [C.c_void_p]
    library.mpv_command.argtypes = [C.c_void_p, C.POINTER(C.c_char_p)]
    library.mpv_wait_event.argtypes = [C.c_void_p, C.c_double]; library.mpv_wait_event.restype = C.POINTER(Event)
    library.mpv_get_property_string.argtypes = [C.c_void_p, C.c_char_p]; library.mpv_get_property_string.restype = C.c_void_p
    library.mpv_free.argtypes = [C.c_void_p]
    library.mpv_request_log_messages.argtypes = [C.c_void_p, C.c_char_p]
    library.mpv_terminate_destroy.argtypes = [C.c_void_p]
    handle = library.mpv_create(); require(handle, 'mpv_create failed')
    logs = []; observed = {}; end_reason = None; started = time.monotonic()
    saw_restart = False; started_output = False
    def text(name):
        pointer = library.mpv_get_property_string(handle, name.encode())
        if not pointer: return None
        value = C.string_at(pointer).decode(); library.mpv_free(pointer); return value
    options = {'ao': 'pcm', 'ao-pcm-file': config['output'], 'ao-pcm-waveheader': 'yes', 'ao-pcm-append': 'no',
               'audio-format': 'float', 'video': 'no', 'vo': 'null', 'hwdec': 'no', 'config': 'no', 'terminal': 'no',
               'idle': 'yes', 'keep-open': 'no', 'pause': 'yes', 'volume-max': '100', 'replaygain': 'no'}
    try:
        for key, value in options.items():
            require(library.mpv_set_option_string(handle, key.encode(), value.encode()) >= 0, 'Rejected PCM option: ' + key)
        require(library.mpv_initialize(handle) >= 0, 'mpv_initialize failed')
        library.mpv_request_log_messages(handle, b'v')
        properties = config['case']['properties']
        for key in ('audio-channels', 'audio-device', 'audio-exclusive', 'audio-samplerate', 'audio-pitch-correction', 'af', 'volume'):
            require(library.mpv_set_property_string(handle, key.encode(), properties[key].encode()) >= 0, 'Rejected production property: ' + key)
        arguments = (C.c_char_p * 4)(b'loadfile', config['input'].encode(), b'replace', None)
        require(library.mpv_command(handle, arguments) >= 0, 'loadfile rejected')
        while time.monotonic() - started < 15:
            event = library.mpv_wait_event(handle, .05).contents
            for name in ('current-ao', 'audio-out-params/format', 'audio-out-params/samplerate', 'audio-out-params/channels', 'af', 'volume', 'mpv-version', 'ffmpeg-version'):
                value = text(name)
                if value: observed[name] = value
            if event.event_id == 2 and event.data:
                message = C.cast(event.data, C.POINTER(Log)).contents
                logs.append({'prefix': message.prefix.decode(), 'level': message.level.decode(), 'text': message.text.decode()})
            if event.event_id == 21:
                saw_restart = True
            # PCM is untimed and can reach EOF before a synchronous property
            # query. Hold initial pause until the real PCM driver is observed.
            if saw_restart and observed.get('current-ao') == 'pcm' and not started_output:
                require(library.mpv_set_property_string(handle, b'pause', b'no') >= 0, 'Cannot start PCM output')
                started_output = True
            if event.event_id == 7 and event.data:
                ended = C.cast(event.data, C.POINTER(EndFile)).contents
                end_reason = ended.reason
                require(ended.reason == 0 and ended.error >= 0, 'Audio did not reach clean EOF: ' + repr((ended.reason, ended.error)))
                break
        require(end_reason == 0, 'PCM playback EOF timed out')
        require(started_output and observed.get('current-ao') == 'pcm', 'Actual audio output was not PCM: ' + repr(observed))
        require(not any(row['level'] in ('error', 'fatal') for row in logs), 'libmpv reported an audio/filter error')
    finally:
        library.mpv_terminate_destroy(handle)
    return {'options': options, 'observed': observed, 'logs': logs, 'endReason': end_reason,
            'initialPCMDriverObservedBeforeUnpause': started_output, 'wallSeconds': time.monotonic() - started}


def run_render(name, input, case, library, scratch, reports, keep):
    output = scratch / (name + '.wav')
    configuration = scratch / (name + '.config.json')
    worker_result = scratch / (name + '.worker.json')
    save(configuration, {'library': str(library), 'input': str(input), 'output': str(output), 'case': case})
    command = [sys.executable, str(Path(__file__).resolve()), '--worker', str(configuration), str(worker_result)]
    process = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=25)
    (reports / (name + '.log')).write_text(process.stdout)
    require(process.returncode == 0, name + ' PCM worker failed; see ' + str(reports / (name + '.log')))
    worker = json.loads(worker_result.read_text())
    samples, metadata = read_float_wave(output)
    if keep:
        destination = reports / 'outputs' / output.name
        destination.parent.mkdir(parents=True, exist_ok=True); shutil.copyfile(output, destination)
        metadata['retainedPath'] = str(destination)
    metadata.update(id=name, inputSHA256=digest(input), chain=case['chain'], chainSHA256=bytes_hash(case['chain'].encode()),
                    requestedVolume=case['requestedVolume'], actualVolume=case['actualVolume'], execution=worker,
                    analyzedStartFrame=RATE, analyzedFramesPerChannel=2 * RATE)
    save(reports / (name + '.json'), metadata)
    return samples, metadata


def main():
    if len(sys.argv) == 4 and sys.argv[1] == '--worker':
        save(Path(sys.argv[3]), render_worker(json.loads(Path(sys.argv[2]).read_text())))
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report-directory', type=Path, default=ROOT / 'Docs/IncrementalTest-2026-10-04/audio-signals')
    parser.add_argument('--library', type=Path, default=ROOT / 'dist/SiliconPlayer.app/Contents/Frameworks/libmpv.2.dylib')
    parser.add_argument('--keep-wav', action='store_true', help='Retain all measured PCM outputs')
    args = parser.parse_args()
    reports = args.report_directory.resolve(); reports.mkdir(parents=True, exist_ok=True)
    library = args.library.resolve(); regions = fragments()
    production = {path: digest(ROOT / path) for path in SOURCES}
    harnesses = ['Tests/Integration/AudioSignalChecks.py', 'Tests/Integration/AudioSignalChains.swift', 'scripts/test_audio_signals.sh']
    library_hashes = {path.name: digest(path) for path in sorted(library.parent.glob('*.dylib')) if not path.name.startswith('._')}
    summary = {'startedUTC': datetime.now(timezone.utc).isoformat(), 'library': str(library), 'librarySHA256': digest(library),
               'libraryHashesBegin': library_hashes, 'productionSHA256': production,
               'testHarnessSHA256': {path: digest(ROOT / path) for path in harnesses},
               'extractedRegionSHA256': {name: bytes_hash(value.encode()) for name, value in regions.items()},
               'MPVEngineWholeFileSnapshotBegin': digest(ROOT / 'Sources/SiliconPlayer/MPVEngine.swift'),
               'appLaunched': False, 'realDeviceUsed': False, 'groupCount': 4, 'groups': [], 'renders': [], 'limitations': LIMITS,
               'compiledProductionRegions': ['applySettings', 'setVolume'], 'videoConfigurationTested': False,
               'videoDependency': 'Explicit recorder stub: records calls and returns zero, without applying or verifying video properties.',
               'videoIntegrationInputScope': 'Whole-file SHA anchor only; not extracted or compiled.',
               'secondarySubtitleStyleTested': False,
               'secondarySubtitleDependency': 'Explicit typed call recorder: requires one call with the actual sanitized preference; returns true without applying or verifying subtitles.',
               'references': ['https://mpv.io/manual/stable/#audio-output-drivers-pcm',
                              'https://github.com/mpv-player/mpv/blob/v0.41.0/audio/out/ao_pcm.c',
                              'https://ffmpeg.org/ffmpeg-filters.html#equalizer',
                              'https://ffmpeg.org/ffmpeg-filters.html#rubberband',
                              'https://ffmpeg.org/ffmpeg-filters.html#alimiter']}
    started = time.monotonic()
    def group(name, measurements, assertions):
        passed = all(assertions.values())
        summary['groups'].append({'name': name, 'passed': passed, 'measurements': measurements, 'assertions': assertions})
        save(reports / 'summary.json', summary)
        print(('PASS ' if passed else 'FAIL ') + name, flush=True)
    try:
        with tempfile.TemporaryDirectory(prefix='siliconplayer-audio-signals-', dir='/private/tmp') as temporary:
            scratch = Path(temporary)
            chains = compile_chains(scratch, reports, regions)
            input_dir = reports / 'inputs'; input_dir.mkdir(exist_ok=True)
            specs = {'eq': [[(250, .025), (1000, .05), (4000, .025)]] * 2,
                     'swap': [[(440, .15)], [(880, .25)]], 'pitch': [[(1000, .1)]] * 2,
                     'overload': [[(1000, .8)]] * 2, 'overload-float': [[(1000, .8)]] * 2}
            summary['inputs'] = {name: tone(input_dir / (name + '.wav'), channels, floating=name == 'overload-float')
                                 for name, channels in specs.items()}
            def render(name, input_name, chain_name):
                samples, row = run_render(name, input_dir / (input_name + '.wav'), chains[chain_name], library, scratch, reports, args.keep_wav)
                summary['renders'].append(row)
                return samples, row
            baseline, _ = render('eq-baseline', 'eq', 'baseline')
            equalized, _ = render('eq-plus3', 'eq', 'eq-3db')
            responses = {str(hz): [20 * math.log10(amplitude(equalized[channel], hz) / amplitude(baseline[channel], hz))
                                  for channel in range(2)] for hz in (250, 1000, 4000)}
            group('1kHz equalizer +3dB frequency response', {'gainDBByFrequencyAndChannel': responses,
                'method': 'Two-second orthogonal sine/cosine projection; same-input PCM A/B', 'toleranceDB': .1},
                {'centerWithin3dBPlusMinus0.1': all(abs(value - 3) <= .1 for value in responses['1000']),
                 'offBandGainBelow0.5dB': all(abs(value) < .5 for hz in ('250', '4000') for value in responses[hz])})
            baseline, _ = render('swap-baseline', 'swap', 'baseline')
            swapped, _ = render('swap-enabled', 'swap', 'swap')
            response = {'baseline': [[amplitude(channel, hz) for hz in (440, 880)] for channel in baseline],
                        'swapped': [[amplitude(channel, hz) for hz in (440, 880)] for channel in swapped]}
            group('Independent left/right channel swap', response,
                {'swappedAmplitudeWithin0.2Percent': abs(response['swapped'][0][1] / response['baseline'][1][1] - 1) < .002 and
                                                    abs(response['swapped'][1][0] / response['baseline'][0][0] - 1) < .002,
                 'wrongChannelToneBelowMinus60dB': response['swapped'][0][0] < response['swapped'][0][1] * .001 and
                                                 response['swapped'][1][1] < response['swapped'][1][0] * .001})
            baseline, baseline_row = render('pitch-baseline', 'pitch', 'baseline')
            shifted, shifted_row = render('pitch-plus1', 'pitch', 'pitch-one-semitone')
            base_frequency, base_crossings = frequency(baseline[0])
            reference = 1059.4630943592953
            shifted_zero = [frequency(channel) for channel in shifted]
            spectra = [spectral_frequency(channel) for channel in shifted]
            base_spectrum = spectral_frequency(baseline[0])
            zero_cents = [1200 * math.log2(value[0] / reference) for value in shifted_zero]
            spectral_cents = [1200 * math.log2(value['frequencyHz'] / reference) for value in spectra]
            group('Pitch +1 equal-tempered semitone', {'baselineHz': base_frequency, 'shiftedHz': shifted_zero[0][0],
                'referenceHz': reference, 'baselinePositiveCrossings': base_crossings, 'shiftedPositiveCrossings': [row[1] for row in shifted_zero],
                'zeroCrossHzByChannel': [row[0] for row in shifted_zero], 'zeroCrossErrorCents': zero_cents,
                'HannSpectrumByChannel': spectra, 'spectralErrorCents': spectral_cents, 'baselineHannSpectrum': base_spectrum,
                'baselineFrames': baseline_row['frames'], 'shiftedFrames': shifted_row['frames'], 'toleranceCents': 1,
                'method': 'Independent interpolated zero crossings and whole steady-window Hann FFT over seconds 1–3',
                'thresholdRationale': 'Rubber Band output has small time-varying phase/frequency modulation. <=1 cent accepts the desired semitone accurately; initial .25Hz ideal-sine failure and PCM are preserved in pitch-strict-initial-attempt.'},
                {'baselineWithin0.05Hz': abs(base_frequency - 1000) <= .05,
                 'baselineFFTWithin0.05Hz': abs(base_spectrum['frequencyHz'] - 1000) <= .05,
                 'bothChannelsZeroCrossWithin1Cent': all(abs(value) <= 1 for value in zero_cents),
                 'bothChannelsHannFFTWithin1Cent': all(abs(value) <= 1 for value in spectral_cents),
                 'durationPreservedWithin0.1Seconds': abs(shifted_row['frames'] - baseline_row['frames']) / RATE <= .1})
            baseline, baseline_row = render('gain-baseline', 'overload', 'baseline')
            unlimited, unlimited_row = render('gain-unlimited', 'overload', 'eq-overload-unlimited')
            limited, limited_row = render('gain-limited', 'overload', 'eq-overload-limited')
            half, _ = render('volume-half', 'overload', 'volume-half')
            silence, silent_row = render('volume-low-bound', 'overload', 'volume-low-bound')
            capped, cap_row = render('volume-high-bound', 'overload', 'volume-high-bound')
            float_baseline, float_baseline_row = render('float-gain-baseline', 'overload-float', 'baseline')
            float_unlimited, float_unlimited_row = render('float-gain-unlimited', 'overload-float', 'eq-overload-unlimited')
            float_limited, float_limited_row = render('float-gain-limited', 'overload-float', 'eq-overload-limited')
            base_amplitude = amplitude(baseline[0], 1000)
            half_ratio = amplitude(half[0], 1000) / base_amplitude
            capped_ratio = amplitude(capped[0], 1000) / base_amplitude
            def harmonic_ratio(values):
                return math.sqrt(sum(amplitude(values, hz) ** 2 for hz in (3000, 5000, 7000))) / amplitude(values, 1000)
            harmonic_ratios = {'PCM16Unlimited': harmonic_ratio(unlimited[0]), 'PCM16Limited': harmonic_ratio(limited[0]),
                               'floatUnlimited': harmonic_ratio(float_unlimited[0]), 'floatLimited': harmonic_ratio(float_limited[0])}
            overload_gain = {'PCM16': 20 * math.log10(amplitude(unlimited[0], 1000) / base_amplitude),
                             'float32': 20 * math.log10(amplitude(float_unlimited[0], 1000) / amplitude(float_baseline[0], 1000))}
            group('Volume bounds and real overload limiting', {'baselinePeak': baseline_row['fullPeak'],
                'unlimitedPeak': unlimited_row['fullPeak'], 'limitedPeak': limited_row['fullPeak'],
                'floatBaselinePeak': float_baseline_row['fullPeak'], 'floatUnlimitedPeak': float_unlimited_row['fullPeak'],
                'floatLimitedPeak': float_limited_row['fullPeak'], 'overloadGainDB': overload_gain,
                'harmonicRatiosAt3k5k7kRelativeTo1k': harmonic_ratios,
                'limiterAutolevel': 'Production level=disabled avoids automatic level compensation; the overload is reduced to unity, not digitally clipped before the limiter.',
                'halfVolumeAmplitudeRatio': half_ratio, 'cappedVolumeAmplitudeRatio': capped_ratio,
                'silencePeak': silent_row['fullPeak'], 'requestedToActualVolume':
                [[chains[name]['requestedVolume'], chains[name]['actualVolume']] for name in ('volume-low-bound', 'volume-half', 'volume-high-bound')]},
                {'overloadControlExceeds2.9FloatFullScale': unlimited_row['fullPeak'] > 2.9,
                 'floatInputOverloadControlExceeds2.9FullScale': float_unlimited_row['fullPeak'] > 2.9,
                 'bothSourceFormatsRetain12dBGainBeforeLimiter': all(abs(value - 12) < .1 for value in overload_gain.values()),
                 'limiterPeakWithinUnityPlus1eMinus5': .7 < limited_row['fullPeak'] <= 1.00001,
                 'floatInputLimiterPeakWithinUnityPlus1eMinus5': .7 < float_limited_row['fullPeak'] <= 1.00001,
                 'bothSourcesAvoidPreLimiterClippingHarmonics': all(value < .001 for value in harmonic_ratios.values()),
                 'halfVolumeAttenuatesWithoutSilence': 0 < half_ratio < .5,
                 'negativeVolumeClampProducesSilence': chains['volume-low-bound']['actualVolume'] == 0 and silent_row['fullPeak'] <= 1e-8,
                 'highVolumeClampRetainsBaseline': chains['volume-high-bound']['actualVolume'] == 100 and abs(capped_ratio - 1) < .002 and cap_row['fullPeak'] < 1})
    except Exception as error:
        summary['failure'] = str(error)
        print('FAIL ' + str(error), flush=True)
    finally:
        summary['finishedUTC'] = datetime.now(timezone.utc).isoformat(); summary['wallSeconds'] = time.monotonic() - started
        summary['productionSHA256End'] = {path: digest(ROOT / path) for path in SOURCES}
        summary['extractedRegionSHA256End'] = {name: bytes_hash(value.encode()) for name, value in fragments().items()}
        summary['MPVEngineWholeFileSnapshotEnd'] = digest(ROOT / 'Sources/SiliconPlayer/MPVEngine.swift')
        summary['libraryHashesEnd'] = {path.name: digest(path) for path in sorted(library.parent.glob('*.dylib')) if not path.name.startswith('._')}
        summary['passedGroupCount'] = sum(row['passed'] for row in summary['groups'])
        summary['passed'] = (not summary.get('failure') and summary['passedGroupCount'] == 4 and
            summary['productionSHA256End'] == production and summary['extractedRegionSHA256End'] == summary['extractedRegionSHA256'] and
            summary['libraryHashesEnd'] == library_hashes)
        save(reports / 'summary.json', summary)
    require(summary['passed'], 'Audio signal verification failed; see ' + str(reports / 'summary.json'))
    print('4 independent DSP signal groups passed; ' + str(len(summary['renders'])) + ' PCM A/B executions; no app/device launch', flush=True)


if __name__ == '__main__':
    main()
