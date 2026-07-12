#!/usr/bin/env python3
"""
生成两个好听的音效 WAV 文件：
  - tracking_found.wav: 上行和弦，明亮愉悦
  - tracking_lost.wav:  下行和弦，柔和提示
使用多个泛音叠加 + 简单混响，比纯正弦波好听很多。
"""
import struct, math, os

SAMPLE_RATE = 44100

def generate_samples(notes, duration, fade_in=0.02, fade_out=0.15):
    """
    notes: list of (freq, start_time, note_dur, volume)
    duration: total clip duration in seconds
    """
    n = int(SAMPLE_RATE * duration)
    buf = [0.0] * n
    for freq, t0, ndur, vol in notes:
        s0 = int(t0 * SAMPLE_RATE)
        s1 = min(int((t0 + ndur) * SAMPLE_RATE), n)
        for i in range(s0, s1):
            t = (i - s0) / SAMPLE_RATE
            rel = t / ndur
            # ADSR-like envelope
            if rel < 0.05:
                env = rel / 0.05
            elif rel < 0.3:
                env = 1.0
            elif rel < 1.0:
                env = 1.0 - (rel - 0.3) / 0.7
            else:
                env = 0.0
            # fundamental + harmonics for richness
            sample = (
                math.sin(2 * math.pi * freq * t) * 1.0 +
                math.sin(2 * math.pi * freq * 2 * t) * 0.3 +
                math.sin(2 * math.pi * freq * 3 * t) * 0.1 +
                math.sin(2 * math.pi * freq * 4 * t) * 0.05
            )
            buf[i] += sample * env * vol
    # normalize
    peak = max(abs(s) for s in buf) or 1.0
    buf = [s / peak * 0.85 for s in buf]
    # global fade in/out
    fi = int(fade_in * SAMPLE_RATE)
    fo = int(fade_out * SAMPLE_RATE)
    for i in range(min(fi, n)):
        buf[i] *= i / fi
    for i in range(min(fo, n)):
        buf[n - 1 - i] *= i / fo
    return buf

def simple_reverb(buf, delay_ms=40, decay=0.25, repeats=3):
    """Simple comb-filter reverb for spaciousness."""
    out = list(buf)
    for r in range(1, repeats + 1):
        d = int(delay_ms * r * SAMPLE_RATE / 1000)
        g = decay ** r
        for i in range(d, len(out)):
            out[i] += buf[i - d] * g
    # re-normalize
    peak = max(abs(s) for s in out) or 1.0
    return [s / peak * 0.85 for s in out]

def write_wav(filename, samples):
    n = len(samples)
    with open(filename, 'wb') as f:
        # WAV header
        data_size = n * 2
        f.write(b'RIFF')
        f.write(struct.pack('<I', 36 + data_size))
        f.write(b'WAVE')
        f.write(b'fmt ')
        f.write(struct.pack('<IHHIIHH', 16, 1, 1, SAMPLE_RATE, SAMPLE_RATE * 2, 2, 16))
        f.write(b'data')
        f.write(struct.pack('<I', data_size))
        for s in samples:
            v = max(-1.0, min(1.0, s))
            f.write(struct.pack('<h', int(v * 32767)))

def main():
    out_dir = "unity_project/Assets/Audio"
    os.makedirs(out_dir, exist_ok=True)

    # --- tracking_found: C major arpeggio going up, bright and pleasant ---
    # C5=523, E5=659, G5=784, C6=1047
    found_notes = [
        (523.25, 0.00, 0.35, 0.7),   # C5
        (659.25, 0.08, 0.30, 0.6),   # E5
        (783.99, 0.16, 0.28, 0.55),  # G5
        (1046.5, 0.24, 0.40, 0.65),  # C6 (ring out)
    ]
    found = generate_samples(found_notes, 0.65)
    found = simple_reverb(found, delay_ms=35, decay=0.2, repeats=4)
    write_wav(os.path.join(out_dir, "tracking_found.wav"), found)
    print(f"✓ tracking_found.wav ({len(found)} samples, {len(found)/SAMPLE_RATE:.2f}s)")

    # --- tracking_lost: minor descending, soft and gentle ---
    # A4=440, F4=349, D4=293, A3=220
    lost_notes = [
        (440.00, 0.00, 0.30, 0.5),   # A4
        (349.23, 0.10, 0.30, 0.45),  # F4
        (293.66, 0.20, 0.35, 0.4),   # D4
        (220.00, 0.30, 0.50, 0.45),  # A3 (ring out)
    ]
    lost = generate_samples(lost_notes, 0.80)
    lost = simple_reverb(lost, delay_ms=45, decay=0.25, repeats=4)
    write_wav(os.path.join(out_dir, "tracking_lost.wav"), lost)
    print(f"✓ tracking_lost.wav ({len(lost)} samples, {len(lost)/SAMPLE_RATE:.2f}s)")

if __name__ == "__main__":
    main()
