import "dart:math";

import "sound_backend.dart";

/// 預先合成好的語音類別（每類各有多個變體 mp3，每次隨機抽一個播）。
///
/// 對應的 mp3 由開發期手動生成（目前用 ElevenLabs 網站，詳見 CLAUDE.md），
/// 放在 `assets/audio/voice/<kind>_<index>.mp3`。
enum VoiceKind {
	levelStart,
	levelComplete,
}

/// 語音服務：播放預先合成好的台灣口音語音 mp3。
///
/// **離線、零延遲、無 ML runtime**。Runtime 只負責隨機挑檔案、用 [SoundBackend] 播。
///
/// 新增 / 修改台詞流程見 CLAUDE.md 的 ElevenLabs 配置一節。
/// 若新增 [VoiceKind] 變體，要更新 [_variantsCount] map。
///
/// [enabled] 可在執行期切換；切到 false 時 [speakLevelStart] / [speakLevelComplete]
/// 直接 no-op。
class VoiceService {
	VoiceService();

	/// 每個 VoiceKind 對應幾個變體 mp3（檔名後綴 1..count）。
	static const Map<VoiceKind, int> _variantsCount = <VoiceKind, int>{
		VoiceKind.levelStart: 4,
		VoiceKind.levelComplete: 4,
	};

	/// 每個 VoiceKind 對應 mp3 檔名前綴（在 assets/audio/voice/ 之下）。
	static const Map<VoiceKind, String> _filePrefix = <VoiceKind, String>{
		VoiceKind.levelStart: "level_start",
		VoiceKind.levelComplete: "level_complete",
	};

	final SoundBackend _backend = SoundBackend();
	final Random _random = Random();

	bool enabled = true;

	/// 預載所有變體 mp3（Web Audio 後端必要、io 後端也用得到）。
	Future<void> init() async {
		for (final MapEntry<VoiceKind, int> e in _variantsCount.entries) {
			final String? prefix = _filePrefix[e.key];
			if (prefix == null) continue;
			for (int i = 1; i <= e.value; i++) {
				await _backend.load(_assetFor(prefix, i));
			}
		}
	}

	/// 播放「進關卡」語音（隨機抽一個變體）。
	void speakLevelStart() => _play(VoiceKind.levelStart);

	/// 播放「過關完成」語音（隨機抽一個變體）。
	void speakLevelComplete() => _play(VoiceKind.levelComplete);

	/// 所有語音共用一條 channel：新一句立刻把舊一句截掉，避免「過關時還沒講完
	/// 就進下一關、新關卡的 start 與舊關卡的 complete 同時播」的疊聲。
	static const String _voiceChannel = "voice";

	void _play(VoiceKind kind) {
		if (!enabled) return;
		final int count = _variantsCount[kind] ?? 0;
		final String? prefix = _filePrefix[kind];
		if (count <= 0 || prefix == null) return;
		final int index = 1 + _random.nextInt(count);
		_backend.play(_assetFor(prefix, index), channel: _voiceChannel);
	}

	Future<void> stop() async {
		// 不支援打斷已觸發的 buffer source；新版 backend 沒有 stop API。
		// 此 method 留著只為 API 對齊；若未來要支援打斷，可加在 [SoundBackend]。
	}

	Future<void> dispose() => _backend.dispose();

	static String _assetFor(String prefix, int index) =>
			"assets/audio/voice/${prefix}_$index.mp3";
}
