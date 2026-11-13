# 合成 assets/audio/error.mp3：兩聲同音高的短促低音「叭叭」（答錯的蜂鳴器）。
# 用法：uv run --with numpy python tools/gen_error_sfx.py error.wav
#       ffmpeg -i error.wav -ac 1 -ar 44100 -c:a libmp3lame -b:a 128k assets/audio/error.mp3
import sys

import numpy as np
import wave

SR = 44100

# 音高（Hz）、每聲長度、兩聲間隔（秒）
FREQ = 227.0
BEEP = 0.11
GAP = 0.04


def saw(phase):
	return 2 * (phase - np.floor(phase + 0.5))


def square(phase):
	return np.sign(np.sin(2 * np.pi * phase))


def beep(dur):
	t = np.arange(int(SR * dur)) / SR
	sig = np.zeros_like(t)
	# 方波 + 鋸齒波，兩組略為失諧（±0.6%），聲音比較厚、像喇叭
	for detune in (0.994, 1.006):
		ph = FREQ * detune * t
		sig += 0.55 * square(ph) + 0.45 * saw(ph)
	# 起音 5ms、持續、最後 25ms 收掉（不要長尾巴，才是短促的「叭」）
	env = np.minimum(1, t / 0.005) * np.clip((dur - t) / 0.025, 0, 1)
	return sig * env


def lowpass(x, cutoff):
	# 兩次一階低通（約 12 dB/oct），濾掉方波刺耳的高次泛音
	a = np.exp(-2 * np.pi * cutoff / SR)
	for _ in range(2):
		y = np.empty_like(x)
		prev = 0.0
		for i, v in enumerate(x):
			prev = (1 - a) * v + a * prev
			y[i] = prev
		x = y
	return x


out = np.concatenate([beep(BEEP), np.zeros(int(SR * GAP)), beep(BEEP)])
out = lowpass(out, 1800.0)
# 峰值 -9 dBFS：蜂鳴聲是持續音，平均響度比 snap（短促、峰值 -4）高，壓到平均約 -15 dB 才一致
out = out / np.abs(out).max() * 10 ** (-9 / 20)
pcm = (out * 32767).astype(np.int16)
with wave.open(sys.argv[1], "wb") as w:
	w.setnchannels(1)
	w.setsampwidth(2)
	w.setframerate(SR)
	w.writeframes(pcm.tobytes())
