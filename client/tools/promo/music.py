"""Background music for the promo, synthesised from scratch (no samples): a pentatonic score in D 羽 mode
(D F G A C) for plucked zither (古筝-like), bamboo flute (笛子-like), low strings, war drums and gong,
laid out on the video's cut points (cut.json). Original composition; nothing is sampled or copied.

    python music.py out.wav [length_seconds]

Needs numpy + scipy. The sections follow the cut: title → map (calm) → field battle (drums build, the
charge, the melee) → overview → siege (tension, the ladders, the fight on the wall) → resolve → end card.
"""
from __future__ import annotations

import sys

import numpy as np
from scipy.io import wavfile
from scipy.signal import fftconvolve, butter, sosfilt

SR = 44100
BPM = 96.0
BEAT = 60.0 / BPM
rng = np.random.default_rng(7)

# D 羽调式: D F G A C
SCALE = [0, 3, 5, 7, 10]
D2 = 73.42


def note(deg: int, octave: int = 0) -> float:
    """Pentatonic degree (0..4, may run past) above D2 + octave."""
    o, d = divmod(deg, 5)
    return D2 * 2 ** (octave + o + SCALE[d] / 12)


class Track:
    def __init__(self, length: float):
        self.n = int(length * SR)
        self.L = np.zeros(self.n)
        self.R = np.zeros(self.n)

    def add(self, sig: np.ndarray, t: float, gain: float = 1.0, pan: float = 0.0) -> None:
        i = int(t * SR)
        if i >= self.n:
            return
        sig = sig[: self.n - i] * gain
        lg, rg = np.cos((pan + 1) * np.pi / 4), np.sin((pan + 1) * np.pi / 4)
        self.L[i:i + len(sig)] += sig * lg * 1.414
        self.R[i:i + len(sig)] += sig * rg * 1.414


def env(n: int, a: float, d: float) -> np.ndarray:
    t = np.arange(n) / SR
    return np.minimum(1.0, t / max(a, 1e-4)) * np.exp(-t / d)


# ------------------------------------------------------------------ instruments
def zheng(f: float, dur: float = 2.2, bright: float = 1.0) -> np.ndarray:
    """Plucked silk string: decaying harmonics (upper ones die faster), a tiny pitch bend at the onset."""
    n = int(dur * SR)
    t = np.arange(n) / SR
    bend = 1.0 + 0.012 * np.exp(-t / 0.04)
    out = np.zeros(n)
    for h in range(1, 11):
        inh = 1 + 0.0004 * h * h
        amp = (1.0 / h ** 1.1) * (1.0 if h < 4 else bright)
        out += amp * np.sin(2 * np.pi * f * h * inh * np.cumsum(bend) / SR) * np.exp(-t * (1.2 + 0.9 * h))
    out += rng.normal(0, 1, n) * np.exp(-t / 0.004) * 0.15            # the pick
    return out * np.minimum(1.0, t / 0.002)


def dizi(phrase: list[tuple[float, float]], start_gap: float = 0.0) -> np.ndarray:
    """Bamboo flute line: [(freq, seconds)…] played legato with glides, vibrato that grows on long notes,
    and breath noise."""
    total = sum(d for _, d in phrase) + 0.6
    n = int(total * SR)
    freq = np.zeros(n)
    amp = np.zeros(n)
    i = 0
    prev = phrase[0][0]
    for f, d in phrase:
        m = int(d * SR)
        seg_t = np.arange(m) / SR
        glide = np.minimum(1.0, seg_t / 0.07)
        fr = prev * (f / prev) ** glide if f > 0 else np.full(m, prev)
        vib = 1 + 0.009 * np.sin(2 * np.pi * 5.2 * seg_t) * np.clip((seg_t - 0.25) / 0.4, 0, 1)
        freq[i:i + m] = fr * vib
        a = np.ones(m) if f > 0 else np.zeros(m)
        if f > 0:
            a *= np.minimum(1.0, seg_t / 0.06) * (0.85 + 0.15 * np.exp(-seg_t / 0.15))
        amp[i:i + m] = a
        i += m
        if f > 0:
            prev = f
    freq[i:] = prev
    amp = np.convolve(amp, np.ones(800) / 800, mode="same")
    ph = 2 * np.pi * np.cumsum(freq) / SR
    tone = np.sin(ph) + 0.28 * np.sin(2 * ph) + 0.12 * np.sin(3 * ph) + 0.05 * np.sin(4 * ph)
    breath = sosfilt(butter(2, [1800, 6000], btype="band", fs=SR, output="sos"), rng.normal(0, 1, n))
    return (tone + breath * 0.12) * amp


def drum(big: float = 1.0, f0: float = 95.0, f1: float = 48.0, dur: float = 0.9) -> np.ndarray:
    """A war drum: a skin dropping in pitch, a thump of noise."""
    n = int(dur * SR)
    t = np.arange(n) / SR
    f = f1 + (f0 - f1) * np.exp(-t / 0.05)
    body = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / (0.32 * big))
    hit = sosfilt(butter(2, 900, fs=SR, output="sos"), rng.normal(0, 1, n)) * np.exp(-t / 0.03)
    return body + hit * 0.9


def rim(dur: float = 0.15) -> np.ndarray:
    n = int(dur * SR)
    t = np.arange(n) / SR
    return (sosfilt(butter(2, [700, 2500], btype="band", fs=SR, output="sos"), rng.normal(0, 1, n)) * 1.6
            + np.sin(2 * np.pi * 420 * t) * 0.5) * np.exp(-t / 0.035)


def gong(dur: float = 7.0, f: float = 110.0) -> np.ndarray:
    """A large gong: inharmonic partials blooming after the strike, long shimmer."""
    n = int(dur * SR)
    t = np.arange(n) / SR
    out = np.zeros(n)
    for r, a, dcy in [(1.0, 1.0, 2.6), (1.48, 0.7, 2.0), (2.03, 0.55, 1.6), (2.74, 0.4, 1.3), (3.6, 0.3, 1.0), (4.9, 0.2, 0.8)]:
        swell = 1 - np.exp(-t / (0.08 + 0.05 * r))
        out += a * np.sin(2 * np.pi * f * r * t * (1 + 0.004 * np.sin(2 * np.pi * 0.7 * t))) * swell * np.exp(-t / dcy)
    out += rng.normal(0, 1, n) * np.exp(-t / 0.02) * 0.4
    return out


def strings(f: float, dur: float, att: float = 0.25) -> np.ndarray:
    """Low bowed strings: detuned saw-like voices, low-passed, slow attack."""
    while f < 65.0:
        f *= 2.0                    # keep out of the sub-bass (it only muddies small speakers)
    n = int(dur * SR)
    t = np.arange(n) / SR
    out = np.zeros(n)
    for det in (-0.004, 0.0, 0.005):
        ph = 2 * np.pi * f * (1 + det) * t
        for h in range(1, 9):
            out += np.sin(h * ph) / h * (0.92 ** h)
    out = sosfilt(butter(2, 1400, fs=SR, output="sos"), out)
    a = np.minimum(1.0, t / att) * np.minimum(1.0, (dur - t) / 0.25)
    return out * np.clip(a, 0, 1) / 3


def pad(freqs: list[float], dur: float, att: float = 1.5) -> np.ndarray:
    n = int(dur * SR)
    out = sum(strings(f, dur, att) for f in freqs)
    return out[:n]


# ------------------------------------------------------------------ the score (times in seconds, from cut.json)
CUTS = {"title": 0.0, "map": 3.5, "field": 16.8, "cav": 27.0, "melee": 32.7, "over": 44.2,
        "siege": 50.2, "ladder": 57.2, "wall": 66.4, "resolve": 76.4, "end": 81.9}


def compose(length: float) -> Track:
    tr = Track(length)
    zh = Track(length)          # plucked strings bus (gets more reverb)
    dr = Track(length)          # drums bus
    q = BEAT / 2                # an eighth

    # title: a gong and two heavy drums over a low drone
    tr.add(gong(7.0, 98.0), 0.25, 0.55)
    dr.add(drum(1.6, 80, 40, 1.6), 0.25, 1.0)
    dr.add(drum(1.6, 80, 40, 1.6), 1.9, 0.8)
    tr.add(pad([note(0, -1), note(3, -1)], 4.2, 1.2), 0.0, 0.5)

    # the map: zither arpeggios over a drone, the flute's first phrase
    t = CUTS["map"]
    arp = [0, 2, 3, 5, 3, 2, 4, 3]
    k = 0
    while t < CUTS["field"] - 0.2:
        deg = arp[k % len(arp)] + (5 if k % 16 >= 8 else 0)
        zh.add(zheng(note(deg, 1), 2.0, 0.8), t, 0.32, pan=-0.35 + 0.1 * (k % 3))
        k += 1
        t += q
    tr.add(pad([note(0, -1), note(3, 0), note(0, 1)], CUTS["field"] - CUTS["map"] + 1.0, 2.0), CUTS["map"], 0.32)
    B = BEAT
    phrase1 = [(note(3, 2), B), (note(4, 2), B * 0.5), (note(5, 2), B * 2.5), (note(4, 2), B * 0.5), (note(3, 2), B * 0.5),
               (note(2, 2), B), (note(3, 2), B * 3), (0, B * 0.5),
               (note(5, 2), B * 0.5), (note(6, 2), B * 0.5), (note(8, 2), B * 1.5), (note(7, 2), B * 0.5), (note(6, 2), B),
               (note(5, 2), B * 3)]
    tr.add(dizi(phrase1), 6.2, 0.22, pan=0.25)

    # the field battle: drums come in, build to the charge, then everything for the melee
    t0 = CUTS["field"]
    dr.add(drum(1.8, 85, 42, 1.8), t0, 1.0)
    tr.add(gong(5.0, 104.0), t0, 0.35)
    t = t0
    beat = 0
    while t < CUTS["over"]:
        sec = "build" if t < CUTS["cav"] else ("charge" if t < CUTS["melee"] else "melee")
        b = beat % 8
        if sec == "build":
            if b in (0, 4):
                dr.add(drum(1.0), t, 0.75)
            if b in (3, 7):
                dr.add(drum(0.6, 120, 70, 0.5), t, 0.35, pan=0.3)
        else:
            # gallop: da-da-DUM on every beat in the charge; full kit in the melee
            dr.add(drum(1.0), t, 0.85 if b % 2 == 0 else 0.55)
            dr.add(drum(0.5, 130, 75, 0.4), t + q * 0.66, 0.3, pan=-0.3)
            dr.add(drum(0.5, 130, 75, 0.4), t + q * 1.33, 0.3, pan=0.3)
            if sec == "melee":
                dr.add(rim(), t + q, 0.28, pan=0.5)
                if b == 0:
                    dr.add(drum(1.8, 80, 38, 1.4), t, 0.6)
        t += BEAT
        beat += 1
    # low strings ostinato from the build on; the zither in tremolo; the flute's war phrase in the melee
    ost = [0, 0, 1, 0, 2, 0, 1, -1]
    t = t0 + BEAT * 4
    k = 0
    while t < CUTS["over"]:
        deg = ost[k % len(ost)]
        f = note(deg if deg >= 0 else 4, -1 if deg >= 0 else -2)
        tr.add(strings(f, q * 0.95, 0.02), t, 0.55 if t > CUTS["cav"] else 0.35)
        k += 1
        t += q
    t = CUTS["cav"]
    while t < CUTS["over"]:
        zh.add(zheng(note(3 if t < CUTS["melee"] else 5, 1), 0.6, 1.2), t, 0.16, pan=-0.4)
        t += q / 2
    phrase2 = [(note(5, 2), B), (note(7, 2), B), (note(8, 2), B * 2), (note(7, 2), B * 0.5), (note(6, 2), B * 0.5),
               (note(5, 2), B), (note(6, 2), B * 0.5), (note(5, 2), B * 0.5), (note(3, 2), B * 2),
               (note(5, 2), B), (note(8, 2), B), (note(10, 2), B * 2.5), (note(9, 2), B * 0.5), (note(8, 2), B * 3)]
    tr.add(dizi(phrase2), CUTS["melee"] + 0.3, 0.26, pan=0.2)
    tr.add(pad([note(0, -1), note(3, -1), note(0, 0)], CUTS["over"] - CUTS["cav"] + 0.5, 2.5), CUTS["cav"], 0.28)

    # overview: one great hit, a held chord, sparse drums
    tr.add(gong(6.0, 98.0), CUTS["over"], 0.5)
    dr.add(drum(1.8, 80, 38, 1.8), CUTS["over"], 1.0)
    tr.add(pad([note(0, -1), note(3, 0), note(4, 0), note(0, 1)], CUTS["siege"] - CUTS["over"] + 1.0, 0.6), CUTS["over"], 0.42)
    for i in range(2):
        dr.add(drum(1.2), CUTS["over"] + BEAT * 4 * (i + 1), 0.6)

    # the siege: tension — a slow heavy pulse, low tremolo climbing
    t = CUTS["siege"]
    k = 0
    while t < CUTS["ladder"]:
        if k % 2 == 0:
            dr.add(drum(1.5, 70, 36, 1.4), t, 0.8)
        t += BEAT
        k += 1
    t = CUTS["siege"]
    while t < CUTS["ladder"]:
        frac = (t - CUTS["siege"]) / (CUTS["ladder"] - CUTS["siege"])
        zh.add(zheng(note(int(frac * 5), 0), 0.5, 1.0), t, 0.18 + 0.12 * frac, pan=0.3)
        t += q / 2
    tr.add(pad([note(0, -2), note(4, -1)], CUTS["ladder"] - CUTS["siege"] + 0.5, 2.0), CUTS["siege"], 0.45)

    # the ladders and the wall: the climax — faster drums, strings, the flute high
    t = CUTS["ladder"]
    beat = 0
    while t < CUTS["resolve"]:
        b = beat % 8
        dr.add(drum(1.0), t, 0.9 if b % 2 == 0 else 0.6)
        dr.add(drum(0.5, 130, 75, 0.4), t + q, 0.4, pan=-0.3 if b % 2 else 0.3)
        if t > CUTS["wall"]:
            dr.add(drum(0.4, 150, 90, 0.3), t + q * 0.5, 0.25, pan=0.4)
            dr.add(rim(), t + q * 1.5, 0.25, pan=-0.5)
        if b == 0:
            dr.add(drum(1.8, 80, 38, 1.4), t, 0.65)
        t += BEAT
        beat += 1
    ost2 = [0, 0, 3, 0, 2, 0, 4, 3]
    t = CUTS["ladder"]
    k = 0
    while t < CUTS["resolve"]:
        tr.add(strings(note(ost2[k % 8], -1), q * 0.95, 0.02), t, 0.6)
        k += 1
        t += q
    t = CUTS["wall"]
    while t < CUTS["resolve"]:
        zh.add(zheng(note(5 + (int((t - CUTS["wall"]) / (BEAT * 2)) % 3), 1), 0.5, 1.3), t, 0.15, pan=-0.4)
        t += q / 2
    phrase3 = [(note(8, 2), B * 2), (note(7, 2), B * 0.5), (note(8, 2), B * 0.5), (note(10, 2), B * 3),
               (note(9, 2), B), (note(8, 2), B), (note(7, 2), B * 0.5), (note(5, 2), B * 0.5), (note(7, 2), B * 2),
               (note(8, 2), B), (note(10, 2), B), (note(11, 2), B * 1.5), (note(10, 2), B * 0.5), (note(8, 2), B * 4)]
    tr.add(dizi(phrase3), CUTS["wall"] - 0.2, 0.28, pan=0.2)
    tr.add(pad([note(0, -1), note(3, 0), note(0, 1)], CUTS["resolve"] - CUTS["ladder"] + 0.5, 3.0), CUTS["ladder"], 0.3)

    # resolve: drums stop on one hit, the zither comes down, the end card: gong and the last chord
    dr.add(drum(2.0, 80, 36, 2.0), CUTS["resolve"], 1.0)
    tr.add(gong(6.0, 92.0), CUTS["resolve"], 0.45)
    desc = [10, 8, 7, 5, 3, 2, 0]
    for i, deg in enumerate(desc):
        zh.add(zheng(note(deg, 1), 2.5, 0.8), CUTS["resolve"] + 0.4 + i * q * 1.5, 0.3, pan=-0.2 + 0.07 * i)
    tr.add(pad([note(0, -1), note(3, 0), note(0, 1)], length - CUTS["resolve"], 0.8), CUTS["resolve"], 0.4)
    dr.add(drum(2.0, 75, 34, 2.4), CUTS["end"] + 0.1, 0.9)
    tr.add(gong(5.0, 98.0), CUTS["end"] + 0.1, 0.5)
    zh.add(zheng(note(0, 1), 4.0, 0.7), CUTS["end"] + 0.1, 0.35)
    zh.add(zheng(note(3, 1), 4.0, 0.7), CUTS["end"] + 0.18, 0.28)
    zh.add(zheng(note(0, 2), 4.0, 0.7), CUTS["end"] + 0.26, 0.25)

    # buses: reverb (a decaying noise tail per channel), then sum
    def verb(L: np.ndarray, R: np.ndarray, secs: float, wet: float) -> tuple[np.ndarray, np.ndarray]:
        n = int(secs * SR)
        t = np.arange(n) / SR
        irL = rng.normal(0, 1, n) * np.exp(-t / (secs / 5))
        irR = rng.normal(0, 1, n) * np.exp(-t / (secs / 5))
        irL /= np.sqrt(np.sum(irL ** 2))
        irR /= np.sqrt(np.sum(irR ** 2))
        return (L + wet * fftconvolve(L, irL)[: len(L)], R + wet * fftconvolve(R, irR)[: len(R)])

    zL, zR = verb(zh.L, zh.R, 3.0, 0.55)
    dL, dR = verb(dr.L, dr.R, 1.6, 0.25)
    tL, tR = verb(tr.L, tr.R, 2.6, 0.45)
    tr.L = tL + zL + dL * 0.9
    tr.R = tR + zR + dR * 0.9
    return tr


def main() -> None:
    out = sys.argv[1]
    length = float(sys.argv[2]) if len(sys.argv) > 2 else 86.0
    tr = compose(length)
    st = np.stack([tr.L, tr.R], axis=1)
    st = np.tanh(st / np.max(np.abs(st)) * 1.4) / np.tanh(1.4)       # gentle saturation, then peak at -1 dBFS
    fade = int(1.5 * SR)
    st[-fade:] *= np.linspace(1, 0, fade)[:, None]
    st = st * 10 ** (-1 / 20)
    wavfile.write(out, SR, (st * 32767).astype(np.int16))
    print("wrote", out, f"{length:.1f}s")


if __name__ == "__main__":
    main()
