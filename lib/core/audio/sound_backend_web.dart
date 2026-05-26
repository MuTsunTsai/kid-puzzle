import "dart:js_interop";

import "package:flutter/foundation.dart";
import "package:flutter/services.dart";
import "package:web/web.dart" as web;

import "sound_backend.dart";

/// Web 平台用 Web Audio API 實作 [SoundBackend]。
///
/// **流程**：
/// 1. [load] 用 `rootBundle.load` 取出 mp3 bytes、`AudioContext.decodeAudioData`
///    解碼成 PCM `AudioBuffer`，存進 map。
/// 2. [play] 建立 `AudioBufferSourceNode`、接到 destination、`start()`。
///    每次播放是一個全新的 source node（Web Audio 設計上 source 是一次性的）。
///
/// **優於 `<audio>` element 之處**：
/// - 無「載入中」中間狀態 — buffer 已 decode、play 是 sync 的瞬發。
/// - 無 codec race — 不會吐解碼雜訊。
/// - 無 element 數量上限 — 可同時播數十個聲音。
///
/// **首次 user gesture 解鎖**：iOS Safari / 部分 Android Chrome 會把
/// AudioContext 開始於 `suspended` 狀態，必須在 user gesture handler 內呼叫
/// `resume()` 才能播音。[play] 每次都會試著呼叫 `resume()`（已 running 是 no-op）。
class _WebSoundBackend implements SoundBackend {
	_WebSoundBackend() {
		_context = web.AudioContext();
	}

	late final web.AudioContext _context;
	final Map<String, web.AudioBuffer> _buffers = <String, web.AudioBuffer>{};

	/// channel → 該 channel 最近一次仍在播的 source node（停掉舊的用）。
	/// source 在「播完」會自然結束、不需要從這裡清掉；只在 play 同 channel
	/// 新音時主動 stop 並覆蓋。
	final Map<String, web.AudioBufferSourceNode> _channelLastSource =
			<String, web.AudioBufferSourceNode>{};

	@override
	Future<void> load(String assetPath, {bool allowOverlap = false}) async {
		// Web Audio API 本來就是每次 play 建立新 source node、自然支援疊播；
		// 此處 allowOverlap 旗標被忽略。
		try {
			final ByteData data = await rootBundle.load(assetPath);
			final Uint8List bytes = data.buffer.asUint8List(
				data.offsetInBytes,
				data.lengthInBytes,
			);
			// decodeAudioData 需要 ArrayBuffer（不是 view），複製成獨立 buffer
			final JSArrayBuffer ab = bytes.buffer.toJS;
			final JSPromise<web.AudioBuffer> promise = _context.decodeAudioData(ab);
			final web.AudioBuffer buf = await promise.toDart;
			_buffers[assetPath] = buf;
		} catch (e) {
			debugPrint("SoundBackend (web) load failed for $assetPath: $e");
		}
	}

	@override
	void play(String assetPath, {String? channel, double volume = 1.0}) {
		final web.AudioBuffer? buf = _buffers[assetPath];
		if (buf == null) return;
		// iOS Safari：AudioContext 在 user gesture 前是 suspended，每次播都試 resume。
		if (_context.state == "suspended") {
			_context.resume();
		}
		// 若有指定 channel：先把該 channel 上一個還在播的 source 停掉。
		if (channel != null) {
			final web.AudioBufferSourceNode? previous = _channelLastSource[channel];
			if (previous != null) {
				try {
					previous.stop();
				} catch (_) {
					// 已 stop / 已 ended 會丟錯，忽略
				}
				_channelLastSource.remove(channel);
			}
		}
		try {
			final web.AudioBufferSourceNode source = _context.createBufferSource();
			source.buffer = buf;
			final double vol = volume.clamp(0.0, 1.0);
			if (vol < 1.0) {
				// 透過 GainNode 控音量：source → gain → destination
				final web.GainNode gain = _context.createGain();
				gain.gain.value = vol;
				source.connect(gain);
				gain.connect(_context.destination);
			} else {
				source.connect(_context.destination);
			}
			source.start();
			if (channel != null) {
				_channelLastSource[channel] = source;
				// 自然播完時把它從 channel map 清掉（避免下次 stop 一個已 ended 的）
				source.onended = (web.Event _) {
					if (_channelLastSource[channel] == source) {
						_channelLastSource.remove(channel);
					}
				}.toJS;
			}
		} catch (e) {
			debugPrint("SoundBackend (web) play failed for $assetPath: $e");
		}
	}

	@override
	Future<void> dispose() async {
		_buffers.clear();
		_channelLastSource.clear();
		try {
			await _context.close().toDart;
		} catch (_) {}
	}
}

/// 對應 [SoundBackend] 工廠的 web 版實作入口（conditional import 用）。
SoundBackend createSoundBackend() => _WebSoundBackend();
