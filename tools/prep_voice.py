# 練習數數的語音處理（taiwan-tts 產生的 wav）。處理 taiwan-tts 產的語音：去掉開頭的鼓聲雜音與多餘靜音、正規化到 -16 LUFS（峰值 ≤ -1.5 dBTP）、
# 轉成 44.1 kHz mono 128 kbps mp3。
# 用法：python prep_voice.py <in.wav> <out.mp3> <tmp_dir>
import re
import subprocess
import sys
import wave

import numpy as np

src, dst, tmp = sys.argv[1], sys.argv[2], sys.argv[3]

with wave.open(src, "rb") as w:
	sr = w.getframerate()
	ch = w.getnchannels()
	sw = w.getsampwidth()
	raw = w.readframes(w.getnframes())
assert sw == 2, "只處理 16-bit"
x = np.frombuffer(raw, dtype=np.int16).astype(np.float64) / 32768
if ch > 1:
	x = x.reshape(-1, ch).mean(axis=1)

hop = int(sr * 0.02)
frames = [x[i:i + hop] for i in range(0, len(x) - hop, hop)]
db = [20 * np.log10(max(np.sqrt(np.mean(f * f)), 1e-9)) for f in frames]
onset = next(i for i, v in enumerate(db) if v > -35)
start = onset
while start > 0 and db[start - 1] > -55:
	start -= 1
cut = max(0, start * hop - int(sr * 0.05))  # 人聲前留 50 ms
voice_at = start * hop
y = x[cut:].copy()
# 人聲之前（雜音區）一律消音，起點前 10 ms 淡入
pre = voice_at - cut
fade = int(sr * 0.01)
y[:max(0, pre - fade)] = 0
for i in range(max(0, pre - fade), pre):
	y[i] *= (i - (pre - fade)) / fade
mid = f"{tmp}/mid.wav"
with wave.open(mid, "wb") as w:
	w.setnchannels(1)
	w.setsampwidth(2)
	w.setframerate(sr)
	w.writeframes((np.clip(y, -1, 1) * 32767).astype(np.int16).tobytes())


def measure(path):
	out = subprocess.run(["ffmpeg", "-hide_banner", "-i", path, "-af", "loudnorm=print_format=summary", "-f", "null", "-"],
		capture_output=True, text=True).stderr
	i = float(re.search(r"Input Integrated:\s+(-?[\d.]+)", out).group(1))
	tp = float(re.search(r"Input True Peak:\s+(-?[\d.]+)", out).group(1))
	return i, tp


i, tp = measure(mid)
# 目標寫 -15.6：mp3 頭尾補的靜音讓量測固定低約 0.4 LU（見 CLAUDE.md）
gain = min(-15.6 - i, -1.5 - tp)
subprocess.run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-i", mid, "-af",
	f"aresample=44100:resampler=soxr,volume={gain:.2f}dB", "-ac", "1", "-ar", "44100", "-c:a", "libmp3lame", "-b:a", "128k", dst],
	check=True)
i2, tp2 = measure(dst)
print(f"onset={onset * 0.02:.2f}s start={start * 0.02:.2f}s cut={cut / sr:.2f}s gain={gain:+.1f}dB -> I={i2} TP={tp2}")
