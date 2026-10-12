# Audio DSP signal regression

Run from the project root:

```sh
bash scripts/test_audio_signals.sh --keep-wav
```

Use `--report-directory /absolute/path` to preserve a separate run. `--library`
can select a specific bundled `libmpv.2.dylib`. No player application or real
audio device is started. The only sink is `ao=pcm`, configured before mpv init;
the worker holds pause until it observes the real PCM output and playback restart.

The runner extracts and compiles the current production `applySettings()`, video
helper and `setVolume()` into `AudioSignalChains.swift`. It exports actual filter
strings/settings and then executes them through the bundled libmpv. It does not
reimplement the production EQ/pitch/volume formulae. Generated regions, source
files, input WAVs and all 44 bundled libraries are hashed. The complete MPVEngine
hash is a time snapshot; the extracted volume method must remain unchanged.

There are **4 independent DSP groups**, using **15 PCM A/B executions**:

| Group | Signal acceptance |
| --- | --- |
| 1kHz EQ +3dB | Both channels within ±0.1dB; 250Hz/4kHz response below 0.5dB |
| Stereo channel swap | Swapped amplitude within 0.2%; wrong-channel tone below −60dB |
| +1 semitone pitch | Both zero-crossing and Hann FFT estimates within 1 cent; length within 0.1s |
| Volume and overload limiter | PCM16 and float input retain +12dB gain before limiting, unlimited peak >2.9, limited peak ≤1.00001; measured 3rd/5th/7th harmonic ratio <0.001; negative volume silent and >100 clamped |

Sources are deterministic legal 48kHz/4-second stereo PCM16 and IEEE float32 WAVs.
The output parser requires actual IEEE float32 WAV at 48kHz/stereo, finite samples,
and 3.8–4.2 seconds. Measurements use samples 48000–143999 (two steady seconds).
EQ and channel measurements use orthogonal known-frequency sine/cosine projection.
Pitch additionally uses a Hann-windowed 131072-bin FFT and interpolated peak.
The 3k/5k/7k ratio is a selected-harmonic diagnostic, not full-band THD.

This validates the tested DSP signals, not listening quality, DAC/speaker response,
exclusive mode, compressed passthrough, every EQ preset, or all source formats.
PCM output is untimed; it is not a realtime performance benchmark. Temporary
compiler/worker files are removed, and `--keep-wav` retains measured PCM evidence.
