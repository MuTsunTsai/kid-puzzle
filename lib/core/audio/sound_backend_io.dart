import "package:audioplayers/audioplayers.dart";
import "package:flutter/foundation.dart";

import "sound_backend.dart";

/// 非 web 平台用 audioplayers 實作 [SoundBackend]：每個 asset 預載一個或多個
/// player、播放時走 stop + resume（單 player 模式）或輪詢 pool（疊播模式）。
///
/// **channel 行為**：
/// - 無 channel：直接用 asset 對應的 player 播；不同 asset 同時觸發互不影響。
/// - 指定 channel：先把該 channel 上一輪 player 的 stop 叫一下，再用 asset
///   對應 player 播（同 channel 中下一句會打斷上一句）。
///
/// **allowOverlap**：為 asset 預載 [_overlapPoolSize] 個 player、用 round-robin
/// 輪詢；同一 asset 連發時聲音可同時疊起來、不會打斷彼此。代價是記憶體
/// 多吃幾個 player instance。
class _IoSoundBackend implements SoundBackend {
	/// 同 asset 連發可同時播的數量（疊播 pool 大小）。
	static const int _overlapPoolSize = 4;

	/// 單 player 模式：每個 asset 一個 player。
	final Map<String, AudioPlayer> _singlePlayers = <String, AudioPlayer>{};

	/// 疊播模式：每個 asset 一個 player pool（round-robin 使用）。
	final Map<String, List<AudioPlayer>> _overlapPools =
			<String, List<AudioPlayer>>{};

	/// 疊播 pool 的下一個 round-robin 索引。
	final Map<String, int> _overlapNextIndex = <String, int>{};

	/// channel → 該 channel 最近一次 play 用到的 player（用來支援「停掉舊的」）。
	final Map<String, AudioPlayer> _channelLastPlayer = <String, AudioPlayer>{};

	@override
	Future<void> load(String assetPath, {bool allowOverlap = false}) async {
		// 對 audioplayers 的 AssetSource 來說 path 不需要 assets/ 前綴
		final String src = assetPath.startsWith("assets/")
				? assetPath.substring("assets/".length)
				: assetPath;
		if (allowOverlap) {
			final List<AudioPlayer> pool = <AudioPlayer>[];
			for (int i = 0; i < _overlapPoolSize; i++) {
				final AudioPlayer p = AudioPlayer();
				try {
					await p.setSource(AssetSource(src));
					await p.setReleaseMode(ReleaseMode.stop);
					pool.add(p);
				} catch (e) {
					debugPrint(
						"SoundBackend load (overlap #$i) failed for $assetPath: $e",
					);
					await p.dispose();
				}
			}
			if (pool.isNotEmpty) {
				_overlapPools[assetPath] = pool;
				_overlapNextIndex[assetPath] = 0;
			}
			return;
		}
		final AudioPlayer p = AudioPlayer();
		try {
			await p.setSource(AssetSource(src));
			await p.setReleaseMode(ReleaseMode.stop);
			_singlePlayers[assetPath] = p;
		} catch (e) {
			debugPrint("SoundBackend load failed for $assetPath: $e");
			await p.dispose();
		}
	}

	@override
	void play(String assetPath, {String? channel, double volume = 1.0}) {
		final List<AudioPlayer>? pool = _overlapPools[assetPath];
		final AudioPlayer? p;
		if (pool != null) {
			// 疊播模式：取下一個 round-robin player。channel 行為對 overlap
			// 沒意義（每次都用不同 player）、忽略 channel。
			final int idx = _overlapNextIndex[assetPath] ?? 0;
			p = pool[idx % pool.length];
			_overlapNextIndex[assetPath] = (idx + 1) % pool.length;
		} else {
			p = _singlePlayers[assetPath];
		}
		if (p == null) return;
		final AudioPlayer? previous =
				channel != null && pool == null ? _channelLastPlayer[channel] : null;
		final double vol = volume.clamp(0.0, 1.0);
		// fire-and-forget。
		// - 疊播 pool：每次都 seek 到 0 重播；不打斷其他 pool member。
		// - 單 player：stop+resume（會打斷自己上一輪）。
		final AudioPlayer player = p;
		() async {
			try {
				if (previous != null && previous != player) {
					await previous.stop();
				}
				if (pool != null) {
					// 從頭播；正在播的話 seek(0) 會重起播放點。
					await player.seek(Duration.zero);
					await player.setVolume(vol);
					await player.resume();
				} else {
					await player.stop();
					await player.setVolume(vol);
					await player.resume();
				}
			} catch (e) {
				debugPrint("SoundBackend play failed for $assetPath: $e");
			}
		}();
		if (channel != null && pool == null) {
			_channelLastPlayer[channel] = player;
		}
	}

	@override
	Future<void> dispose() async {
		_channelLastPlayer.clear();
		for (final AudioPlayer p in _singlePlayers.values) {
			await p.dispose();
		}
		_singlePlayers.clear();
		for (final List<AudioPlayer> pool in _overlapPools.values) {
			for (final AudioPlayer p in pool) {
				await p.dispose();
			}
		}
		_overlapPools.clear();
		_overlapNextIndex.clear();
	}
}

/// 對應 [SoundBackend] 工廠的 io 版實作入口（conditional import 用）。
SoundBackend createSoundBackend() => _IoSoundBackend();
