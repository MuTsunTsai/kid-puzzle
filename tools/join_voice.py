# 練習數數的語音處理（taiwan-tts 產生的 wav）。把多段語音各自處理（去開頭雜音、去頭尾靜音、對齊發聲音量）後，中間留空白接成一個 mp3。
# 用法：python join_voice.py <out.mp3> <tmp_dir> <gap 秒> <in1.wav> <in2.wav> ...
import re
import subprocess
import sys
import wave

import numpy as np

dst, tmp, gap = sys.argv[1], sys.argv[2], float(sys.argv[3])
inputs = sys.argv[4:]
SR = 44100


def read(path):
	# 先統一轉成 44.1 kHz mono 16-bit
	conv = f"{tmp}/conv.wav"
	subprocess.run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-i", path, "-ac", "1", "-ar", str(SR),
		"-af", "aresample=resampler=soxr", "-c:a", "pcm_s16le", conv], check=True)
	with wave.open(conv, "rb") as w:
		return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float64) / 32768


def write(path, x):
	with wave.open(path, "wb") as w:
		w.setnchannels(1)
		w.setsampwidth(2)
		w.setframerate(SR)
		w.writeframes((np.clip(x, -1, 1) * 32767).astype(np.int16).tobytes())


def measure(path):
	out = subprocess.run(["ffmpeg", "-hide_banner", "-i", path, "-af", "loudnorm=print_format=summary", "-f", "null", "-"],
		capture_output=True, text=True).stderr
	return (float(re.search(r"Input Integrated:\s+(-?[\d.]+)", out).group(1)),
		float(re.search(r"Input True Peak:\s+(-?[\d.]+)", out).group(1)))


def trim(x):
	"""人聲起點之前消音（開頭鼓聲雜音）、只留 50 ms；結尾留到最後一個有聲音的區塊後 80 ms。"""
	hop = int(SR * 0.02)
	db = [20 * np.log10(max(np.sqrt(np.mean(x[i:i + hop] ** 2)), 1e-9)) for i in range(0, len(x) - hop, hop)]
	onset = next(i for i, v in enumerate(db) if v > -35)
	start = onset
	while start > 0 and db[start - 1] > -55:
		start -= 1
	last = max(i for i, v in enumerate(db) if v > -45)
	cut0 = max(0, start * hop - int(SR * 0.05))
	cut1 = min(len(x), (last + 1) * hop + int(SR * 0.08))
	y = x[cut0:cut1].copy()
	pre = start * hop - cut0
	fade = int(SR * 0.01)
	y[:max(0, pre - fade)] = 0
	for i in range(max(0, pre - fade), pre):
		y[i] *= (i - (pre - fade)) / fade
	# 結尾 20 ms 淡出
	n = min(len(y), int(SR * 0.02))
	y[len(y) - n:] *= np.linspace(1, 0, n)
	return y


def speech_level(x):
	"""發聲部分的 RMS（dBFS）：只算比最大區塊小 30 dB 以內的 20 ms 區塊（不含停頓、字間空白）。"""
	hop = int(SR * 0.02)
	frames = [x[i:i + hop] for i in range(0, len(x) - hop, hop)]
	ms = np.array([np.mean(f ** 2) for f in frames])
	active = ms[ms > ms.max() * 10 ** (-30 / 10)]
	return 10 * np.log10(np.mean(active))


# 各段先對齊「發聲部分的 RMS」再接起來，最後整段正規化到 -16 LUFS。
# 不各自量 LUFS：「答對了！」這種 1 秒內的短句，LUFS 以 400 ms 區塊計、誤差大，
# 實測各自正規化到 -16 LUFS 後，它的發聲 RMS 比後半句低 1.5 dB、聽起來明顯小聲。
parts = []
for p in inputs:
	y = trim(read(p))
	parts.append(y * 10 ** ((-20 - speech_level(y)) / 20))
joined = parts[0]
for y in parts[1:]:
	joined = np.concatenate([joined, np.zeros(int(SR * gap)), y])
write(f"{tmp}/joined.wav", joined)
i, tp = measure(f"{tmp}/joined.wav")
# 整體調到 -15.6（mp3 頭尾靜音讓量測低約 0.4 LU）。「一共有 X 隻」有些帶零星尖峰（< 0.2% 的
# 樣本），整段為了峰值 ≤ -1.5 一起降會變得明顯小聲，所以改用 limiter 只削尖峰（沒超過的地方不動）
adj = -15.6 - i
subprocess.run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-i", f"{tmp}/joined.wav", "-af",
	f"volume={adj:.2f}dB,alimiter=limit=0.79:attack=5:release=50:level=false:asc=1",
	"-ac", "1", "-ar", str(SR), "-c:a", "libmp3lame", "-b:a", "128k", dst], check=True)
i2, tp2 = measure(dst)
print(f"len={len(joined) / SR:.2f}s -> I={i2} TP={tp2}")
