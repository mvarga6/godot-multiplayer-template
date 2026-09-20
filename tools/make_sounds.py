#!/usr/bin/env python3
"""Regenerate the pickup cues in audio/. Standard library only.

Run from the project root:  python3 tools/make_sounds.py
"""
import math, struct, wave

SR = 44100
H_BELL = (1.0, 0.5, 0.25, 0.12)
H_SOFT = (1.0, 0.28, 0.08)
H_GLASS = (1.0, 0.7, 0.45, 0.3, 0.18)


def env(i, n, attack=0.005, release=0.35):
    t, total = i / SR, n / SR
    a = min(1.0, t / attack) if attack else 1.0
    r = min(1.0, max(0.0, (total - t) / release)) if release else 1.0
    return a * (r ** 1.6)


def tone(freq, dur, amp, harmonics, detune):
    n = int(SR * dur)
    out = [0.0] * n
    for i in range(n):
        t = i / SR
        s = 0.0
        for k, h in enumerate(harmonics, start=1):
            s += h * math.sin(2 * math.pi * freq * k * t)
            if detune:
                s += h * 0.5 * math.sin(2 * math.pi * (freq * k + detune) * t)
        out[i] = s * amp * env(i, n)
    return out


def seq(notes):
    """notes: (freq, dur, amp, harmonics, detune, start_seconds), overlap allowed."""
    total = max(start + d for (_f, d, _a, _h, _det, start) in notes)
    buf = [0.0] * (int(total * SR) + 1)
    for (f, d, a, h, det, start) in notes:
        off = int(start * SR)
        for i, v in enumerate(tone(f, d, a, h, det)):
            if off + i < len(buf):
                buf[off + i] += v
    return buf


def write(path, buf):
    scale = 0.89 / max(1e-9, max(abs(v) for v in buf))
    frames = b''.join(
        struct.pack('<h', int(max(-1.0, min(1.0, v * scale)) * 32767)) for v in buf)
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(frames)
    print('%-32s %.2fs' % (path, len(buf) / SR))


write('audio/pickup_gold.wav', seq([
    (988.0, 0.10, 0.55, H_SOFT, 0.0, 0.00),
    (1318.5, 0.22, 0.55, H_SOFT, 0.0, 0.055),
]))
write('audio/pickup_ruby.wav', seq([
    (659.3, 0.13, 0.55, H_BELL, 1.5, 0.00),
    (784.0, 0.15, 0.50, H_BELL, 1.5, 0.075),
    (1046.5, 0.30, 0.50, H_BELL, 1.5, 0.15),
]))
write('audio/pickup_emerald.wav', seq([
    (783.99, 0.12, 0.50, H_BELL, 2.0, 0.00),
    (987.77, 0.13, 0.50, H_BELL, 2.0, 0.07),
    (1174.7, 0.14, 0.50, H_BELL, 2.0, 0.14),
    (1567.98, 0.34, 0.55, H_GLASS, 2.0, 0.21),
]))
write('audio/pickup_diamond.wav', seq([
    (1046.5, 0.10, 0.45, H_GLASS, 2.5, 0.00),
    (1318.5, 0.10, 0.45, H_GLASS, 2.5, 0.06),
    (1567.98, 0.11, 0.48, H_GLASS, 2.5, 0.12),
    (2093.0, 0.14, 0.50, H_GLASS, 2.5, 0.18),
    (2637.0, 0.45, 0.42, H_GLASS, 3.5, 0.25),
]))
