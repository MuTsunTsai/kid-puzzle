import "dart:async";

import "package:archive/archive.dart";
import "package:audioplayers/audioplayers.dart";
import "package:flutter/services.dart";

import "sprite_asset_loader.dart";
import "sprite_manifest.dart";

/// 物件名稱語音播放器。
///
/// 策略：每個類別有一份 store-mode zip（與類別共用 mp3 同檔名、副檔名換 .zip），
/// 內含 N 個獨立小 mp3（檔名 = `[item.id].mp3`）。啟動時 [preload] 把整份 zip
/// 載進記憶體解開，每個 entry 的 bytes 存進 [_clips]。
///
/// 播放：直接拿 bytes 餵 [BytesSource] 給 AudioPlayer 從頭播完即止，靠檔案
/// 本身長度自然結束。沒有 seek、沒有 Timer。多段並行播放 → 每段獨立 player。
///
/// 為什麼要這樣做：原本對共用 mp3 用 seek + Timer 停止，受 mp3 frame 邊界、
/// 各 backend decoder priming（Android ExoPlayer ~100ms、iOS AVPlayer 類似）
/// 影響、開頭會被吃掉、Timer 收尾也不準。切成獨立 mp3 後行為與單檔語音
/// （level_start_*.mp3 那條已驗證可靠的路徑）完全一致。
class SpriteVoicePlayer {
	SpriteVoicePlayer();

	/// 已載入的類別 → (item.id → mp3 bytes)。
	final Map<String, Map<String, Uint8List>> _clips =
			<String, Map<String, Uint8List>>{};

	/// 進行中的播放實例（dispose 時清理）。
	/// 用 List 而非 Set 以保留「加入順序」、throttle 時砍最舊那個。
	final List<AudioPlayer> _active = <AudioPlayer>[];

	bool enabled = true;

	/// 同時最多允許幾個 player 在播。
	///
	/// Android audioplayers 後端在短時間內連續 new AudioPlayer().play() 時
	/// 觀察到：MediaPlayer/ExoPlayer instance 沒有及時釋放、後續播放被無限期
	/// queue、`onPlayerComplete` 事件也跟著延後 fire、整條 await 鏈卡死、
	/// 直到 app 進背景再回前景才一口氣噴出。
	/// 限制同時 ≤ N 個、超過時砍最舊的（玩家最在意當下這片、不是 0.5 秒前那片）。
	static const int _maxConcurrent = 2;

	/// 該類別的某物件是否有可播放的 clip（語音 zip 內存在 `<itemId>.mp3` entry）。
	/// 類別未 [preload] 過、或物件沒設定 voice timing 而被 `sprites slice` 略過時都回 false。
	bool hasClip(String categoryId, String itemId) {
		final Map<String, Uint8List>? clips = _clips[categoryId];
		return clips != null && clips.containsKey(itemId);
	}

	/// 預載類別 zip（從 `assets/audio/sprites/<categoryId>.zip` 載並解 store 模式）。
	/// 重複呼叫安全（已載入時直接 return）。
	Future<void> preload(SpriteCategory category) async {
		if (_clips.containsKey(category.id)) return;
		final Uint8List bytes = await loadSpriteBytes(
			_zipPathOf(category),
			rev: category.voiceRev,
		);
		final Archive archive = ZipDecoder().decodeBytes(bytes);
		final Map<String, Uint8List> clips = <String, Uint8List>{};
		for (final ArchiveFile f in archive) {
			if (!f.isFile) continue;
			final String name = f.name;
			if (!name.endsWith(".mp3")) continue;
			final String id = name.substring(0, name.length - 4);
			clips[id] = f.readBytes() ?? Uint8List(0);
		}
		_clips[category.id] = clips;
	}

	/// 進行中 player → 它的 done completer。throttle 時要 resolve 舊的、
	/// 確保呼叫端 await 不會卡住。
	final Map<AudioPlayer, Completer<void>> _doneByPlayer =
			<AudioPlayer, Completer<void>>{};

	/// 播放某類別中某個物件的名稱語音。
	///
	/// 回傳 Future 在 AudioPlayer 完成（[PlayerState.completed]）時 resolve。
	/// 多段可同時播放、彼此不打斷；但同時播放數 ≤ [_maxConcurrent]、
	/// 超過時砍最舊的、其對應 future 也立即 resolve（不會永久卡住呼叫端）。
	/// enabled = false 或找不到 clip 時立刻 resolve。
	Future<void> play(SpriteCategory category, SpriteItem item) async {
		if (!enabled) return;
		final Map<String, Uint8List>? clips = _clips[category.id];
		final Uint8List? data = clips?[item.id];
		if (data == null) return;

		// Throttle：若已達上限、砍最舊的 player、resolve 其 future。新 player
		// 在 _active 加入前先砍、保持 _active 始終 ≤ _maxConcurrent。
		while (_active.length >= _maxConcurrent) {
			final AudioPlayer oldest = _active.removeAt(0);
			final Completer<void>? oldDone = _doneByPlayer.remove(oldest);
			try {
				await oldest.stop();
			} catch (_) {}
			unawaited(() async {
				try {
					await oldest.dispose();
				} catch (_) {}
			}());
			if (oldDone != null && !oldDone.isCompleted) oldDone.complete();
		}

		final AudioPlayer player = AudioPlayer();
		unawaited(player.setReleaseMode(ReleaseMode.stop));
		_active.add(player);
		final Completer<void> done = Completer<void>();
		_doneByPlayer[player] = done;
		late final StreamSubscription<void> sub;
		sub = player.onPlayerComplete.listen((_) async {
			await sub.cancel();
			try {
				await player.dispose();
			} catch (_) {}
			_active.remove(player);
			_doneByPlayer.remove(player);
			if (!done.isCompleted) done.complete();
		});
		try {
			await player.play(BytesSource(data));
		} catch (_) {
			await sub.cancel();
			try {
				await player.dispose();
			} catch (_) {}
			_active.remove(player);
			_doneByPlayer.remove(player);
			if (!done.isCompleted) done.complete();
		}
		return done.future;
	}

	Future<void> dispose() async {
		for (final AudioPlayer p in _active.toList()) {
			final Completer<void>? c = _doneByPlayer[p];
			if (c != null && !c.isCompleted) c.complete();
			try {
				await p.dispose();
			} catch (_) {}
		}
		_active.clear();
		_doneByPlayer.clear();
		_clips.clear();
	}

	/// 語音 zip 的 asset 路徑：以類別 id 為檔名根，固定放在
	/// `audio/sprites/<id>.zip`。kid-puzzle-sprite build 端產這條 path 的檔。
	static String _zipPathOf(SpriteCategory cat) =>
			"audio/sprites/${cat.id}.zip";
}
