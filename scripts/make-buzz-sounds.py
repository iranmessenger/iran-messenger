"""Synthesises the BUZZ alert sounds, so no third-party recording is shipped.

Writes each sound twice: as an Android raw resource (used by the BUZZ
notification channels) and as a Flutter asset (played inside the app).

    python scripts/make-buzz-sounds.py
"""
import sys
import wave
from pathlib import Path

import numpy as np

RATE = 22050
ROOT = Path(__file__).resolve().parent.parent / 'app'
TARGETS = [
    ROOT / 'android' / 'app' / 'src' / 'main' / 'res' / 'raw',
    ROOT / 'assets' / 'sounds',
]


def silence(seconds):
    return np.zeros(int(seconds * RATE))


def place(track, sound, at):
    start = int(at * RATE)
    end = min(len(track), start + len(sound))
    track[start:end] += sound[: end - start]


def strike(freq, seconds, partials, decay):
    """A struck chime bar: a few partials, each dying away on its own."""
    t = np.arange(int(seconds * RATE)) / RATE
    out = np.zeros_like(t)
    for ratio, level, speed in partials:
        out += level * np.sin(2 * np.pi * freq * ratio * t) * np.exp(-t * decay * speed)
    attack = np.minimum(t / 0.004, 1)
    return out * attack


def doorbell():
    """Ding-dong: two chime bars, a major third apart."""
    partials = [(1, 1.0, 1.0), (2.0, 0.35, 1.8), (3.0, 0.12, 2.6), (4.2, 0.05, 4.0)]
    track = silence(2.3)
    place(track, strike(659.25, 1.4, partials, 2.6), 0.0)
    place(track, strike(523.25, 1.8, partials, 2.0), 0.55)
    return track


def knock_once(rng):
    t = np.arange(int(0.16 * RATE)) / RATE
    thump = 0.9 * np.sin(2 * np.pi * 170 * t) * np.exp(-t * 70)
    click = rng.standard_normal(len(t)) * np.exp(-t * 400) * 0.5
    glass = sum(
        level * np.sin(2 * np.pi * f * t) * np.exp(-t * d)
        for f, level, d in [(2350, 0.45, 45), (3580, 0.3, 60), (5150, 0.18, 80)]
    )
    return thump + click + glass


def knock():
    """Knock-knock-knock on a window, twice."""
    rng = np.random.default_rng(7)
    track = silence(1.75)
    for at in (0.0, 0.19, 0.38, 0.95, 1.14, 1.33):
        place(track, knock_once(rng) * rng.uniform(0.85, 1.0), at)
    return track


def classic():
    """An old-fashioned electric buzzer: brrr-brrr."""
    t = np.arange(int(1.3 * RATE)) / RATE
    saw = 2 * ((t * 150) % 1) - 1
    square = np.sign(np.sin(2 * np.pi * 75 * t)) * 0.4
    tone = saw + square
    # Soften the edges with a short moving average (a gentle low-pass).
    tone = np.convolve(tone, np.ones(6) / 6, mode='same')
    gate = ((t < 0.5) | ((t > 0.7) & (t < 1.2))).astype(float)
    gate = np.convolve(gate, np.ones(220) / 220, mode='same')
    return tone * gate * (0.85 + 0.15 * np.sin(2 * np.pi * 9 * t))


def write(name, samples):
    peak = np.max(np.abs(samples)) or 1
    fade = np.minimum(1, (len(samples) - np.arange(len(samples))) / (0.03 * RATE))
    pcm = (samples / peak * 0.85 * fade * 32767).astype('<i2')
    for folder in TARGETS:
        folder.mkdir(parents=True, exist_ok=True)
        with wave.open(str(folder / f'buzz_{name}.wav'), 'wb') as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(RATE)
            w.writeframes(pcm.tobytes())


if __name__ == '__main__':
    for name, make in [('doorbell', doorbell), ('knock', knock), ('classic', classic)]:
        write(name, make())
    sys.stdout.write('done\n')
