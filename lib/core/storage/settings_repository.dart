import "package:flutter/foundation.dart";
import "package:hive_ce/hive.dart";

import "../../features/puzzle/domain/services/cell_planner.dart";

/// App 設定的持久化倉庫，包裝 Hive box "settings"。
///
/// 存單純的原始型別（int / bool / String），不用 TypeAdapter；
/// 之後新增設定欄位也只要加 getter/setter。
class SettingsRepository {
	SettingsRepository._(this._box);

	final Box<Object?> _box;

	static const String _boxName = "settings";
	static const String _kMinPieces = "minPieces";
	static const String _kMaxPieces = "maxPieces";
	static const String _kShowHint = "showHint";
	static const String _kCutModes = "cutModes"; // List<String> of CutMode.name
	static const String _kRotationEnabled = "rotationEnabled";
	static const String _kScreenLockEnabled = "screenLockEnabled";
	static const String _kAudioEnabled = "audioEnabled";
	/// Hive key 沿用 "ttsEnabled" 字面值（早期專案曾用 flutter_tts，後來改成
	/// 預錄人聲）— 這條 raw string 不能改，否則使用者既有「語音」開關設定
	/// 會被當成沒設過、套預設 true。對外 API 名稱都用 "voice" 系列。
	static const String _kVoiceEnabled = "ttsEnabled";
	static const String _kBigKidMode = "bigKidMode";

	/// 嵌入拼圖：每關物件數範圍上下界。
	static const String _kInsetMinPieces = "insetMinPieces";
	static const String _kInsetMaxPieces = "insetMaxPieces";
	/// 嵌入拼圖：是否允許剪影相似度高的物件出現在同一關。
	/// 關閉（預設）→ 抽 item 時門檻 0.85、剪影差異要求嚴格；
	/// 開啟 → 門檻放寬到 0.95、只擋「剪影幾乎完全相同」的少數對。
	static const String _kInsetAllowSimilarSilhouette =
			"insetAllowSimilarSilhouette";

	/// 各畫面教學流程「最後看過的版本」存檔。
	/// key 形如 "tutorialVersion.home"、"tutorialVersion.setup"。
	/// 新版教學流程要強制重播時、把對應畫面常數 bump 即可。
	static const String _kTutorialVersionPrefix = "tutorialVersion.";

	/// 舊版只存單一模式的 key；如果新版讀不到 [_kCutModes] 就退回讀它做遷移。
	static const String _kLegacyCutMode = "cutMode";

	/// app 啟動時呼叫一次，回傳已開好的 repo。
	static Future<SettingsRepository> open() async {
		final Box<Object?> box = await Hive.openBox<Object?>(_boxName);
		return SettingsRepository._(box);
	}

	int get minPieces => (_box.get(_kMinPieces) as int?) ?? 4;
	int get maxPieces => (_box.get(_kMaxPieces) as int?) ?? 9;
	bool get showHint => (_box.get(_kShowHint) as bool?) ?? true;
	bool get rotationEnabled =>
			(_box.get(_kRotationEnabled) as bool?) ?? false;
	bool get screenLockEnabled =>
			(_box.get(_kScreenLockEnabled) as bool?) ?? false;
	bool get audioEnabled => (_box.get(_kAudioEnabled) as bool?) ?? true;
	bool get voiceEnabled => (_box.get(_kVoiceEnabled) as bool?) ?? true;

	/// 「大朋友模式」開關。
	///
	/// 啟用時：
	/// - 拼圖片數範圍改成 20~300（以 10 為遞增單位），適合年紀較大的孩子。
	/// - 拼圖塊邊框變細一半，減少視覺干擾。
	/// - 所有需要「長按」的按鈕（齒輪、X 關閉）改成輕觸即可。
	bool get bigKidMode => (_box.get(_kBigKidMode) as bool?) ?? false;

	/// 啟用的切割模式集合。允許多選；遊戲每關隨機從中抽一個。
	///
	/// 永遠保證集合非空：讀到空集合（或從未存過）會 fallback 到 `{grid}`，
	/// 同樣保證寫入時不會存空集合（呼叫端應在 UI 上避免）。
	/// 也會自動遷移舊版單一 `cutMode` key。
	Set<CutMode> get cutModes {
		final Object? raw = _box.get(_kCutModes);
		if (raw is List) {
			final Set<CutMode> set = <CutMode>{};
			for (final Object? item in raw) {
				if (item is String) {
					final CutMode? mode = _parseCutMode(item);
					if (mode != null) set.add(mode);
				}
			}
			if (set.isNotEmpty) return set;
		}
		// 沒新版資料 → 試遷移舊版單一 cutMode key
		final String? legacy = _box.get(_kLegacyCutMode) as String?;
		if (legacy != null) {
			final CutMode? mode = _parseCutMode(legacy);
			if (mode != null) return <CutMode>{mode};
		}
		// 預設：兩種都啟用，讓玩家第一次進來會交替體驗
		return <CutMode>{CutMode.grid, CutMode.voronoi};
	}

	static CutMode? _parseCutMode(String name) {
		for (final CutMode m in CutMode.values) {
			if (m.name == name) return m;
		}
		return null;
	}

	Future<void> saveSetupConfig({
		required int minPieces,
		required int maxPieces,
		required bool showHint,
		required Set<CutMode> cutModes,
		required bool rotationEnabled,
		required bool screenLockEnabled,
	}) async {
		try {
			await _box.putAll(<String, Object?>{
				_kMinPieces: minPieces,
				_kMaxPieces: maxPieces,
				_kShowHint: showHint,
				_kCutModes: cutModes.map((CutMode m) => m.name).toList(),
				_kRotationEnabled: rotationEnabled,
				_kScreenLockEnabled: screenLockEnabled,
			});
			// 清掉舊版單一 key，避免下次讀取又走 legacy 分支
			await _box.delete(_kLegacyCutMode);
		} catch (e) {
			debugPrint("SettingsRepository.saveSetupConfig failed: $e");
		}
	}

	/// 獨立更新「鎖定畫面」設定（兩個遊戲模式共用此 setting；嵌入拼圖 setup
	/// 頁沒有跑 [saveSetupConfig]、需要單獨寫入）。
	Future<void> setScreenLockEnabled(bool value) async {
		try {
			await _box.put(_kScreenLockEnabled, value);
		} catch (e) {
			debugPrint("SettingsRepository.setScreenLockEnabled failed: $e");
		}
	}

	Future<void> setAudioEnabled(bool value) async {
		try {
			await _box.put(_kAudioEnabled, value);
		} catch (e) {
			debugPrint("SettingsRepository.setAudioEnabled failed: $e");
		}
	}

	Future<void> setVoiceEnabled(bool value) async {
		try {
			await _box.put(_kVoiceEnabled, value);
		} catch (e) {
			debugPrint("SettingsRepository.setVoiceEnabled failed: $e");
		}
	}

	/// 素材分類 / 子類別啟用狀態。
	///
	/// 編碼：`Map<String, bool>`，key 形如：
	/// - `"zhuyin"`（分類本身）
	/// - `"alphabet/uppercase"`（分類 alphabet 的 uppercase 子類別）
	///
	/// **三種狀態都要能區分**：
	/// - key 不在 map 中 → 「使用者從未處理」→ 套預設規則
	/// - key 對應 `true` → 「明確選取」
	/// - key 對應 `false` → 「明確取消」（**不**重設為預設值）
	///
	/// 用 `Set<String>` 無法區分後兩種狀態 — 那是這個改版要解的痛點。
	static const String _kEnabledSpriteSelections = "enabledSpriteSelections";

	/// 舊版（v0.2.x）的 Set-based key；存在的話啟動時自動 migrate 到新 key
	/// 後清除。
	static const String _kEnabledSpriteSelectionsLegacy =
			"enabledSpriteSelections_legacySet";

	Map<String, bool> get spriteSelections {
		final Object? raw = _box.get(_kEnabledSpriteSelections);
		if (raw is Map) {
			return <String, bool>{
				for (final MapEntry<Object?, Object?> e in raw.entries)
					if (e.key is String && e.value is bool) e.key as String: e.value as bool,
			};
		}
		// 偵測舊版 Set-based 紀錄、in-memory migrate（沒寫回 box；下一次 toggle
		// 會把新格式 persist 進去）。舊紀錄本身在 [_migrateLegacy] 改寫過後
		// 就不會再走到這條。
		final Object? legacy = _box.get(_kEnabledSpriteSelections);
		if (legacy is List) {
			return <String, bool>{
				for (final Object? e in legacy)
					if (e is String) e: true,
			};
		}
		return const <String, bool>{};
	}

	/// 啟動時呼叫一次：把舊 `Set<String>` 結構轉成 `Map<String, bool>`。
	/// 找不到舊資料時 no-op。
	Future<void> migrateLegacySpriteSelections() async {
		final Object? current = _box.get(_kEnabledSpriteSelections);
		if (current is Map) return; // 已是新格式
		if (current is! List) return; // 沒設定過 → 不用 migrate
		final Map<String, bool> migrated = <String, bool>{
			for (final Object? e in current)
				if (e is String) e: true,
		};
		try {
			await _box.put(_kEnabledSpriteSelections, migrated);
			// 順便記一份 backup 給 debug 用（之後若無需可刪）
			await _box.put(_kEnabledSpriteSelectionsLegacy, current);
		} catch (e) {
			debugPrint("SettingsRepository.migrateLegacySpriteSelections failed: $e");
		}
	}

	Future<void> setSpriteSelections(Map<String, bool> selections) async {
		try {
			await _box.put(_kEnabledSpriteSelections, selections);
		} catch (e) {
			debugPrint("SettingsRepository.setSpriteSelections failed: $e");
		}
	}

	/// 嵌入拼圖：每關物件數範圍下界（slider 範圍 2~12）。
	/// 用 num 接 + toInt 是為了相容 web 端 Hive 序列化後可能變 double 的情況。
	int get insetMinPieces {
		final Object? raw = _box.get(_kInsetMinPieces);
		if (raw is num) return raw.toInt();
		return 4;
	}

	int get insetMaxPieces {
		final Object? raw = _box.get(_kInsetMaxPieces);
		if (raw is num) return raw.toInt();
		return 8;
	}

	Future<void> setInsetPieceRange({
		required int minPieces,
		required int maxPieces,
	}) async {
		try {
			await _box.putAll(<String, Object?>{
				_kInsetMinPieces: minPieces,
				_kInsetMaxPieces: maxPieces,
			});
		} catch (e) {
			debugPrint("SettingsRepository.setInsetPieceRange failed: $e");
		}
	}

	/// 嵌入拼圖：允許剪影相似度高的物件同關出現。預設 false。
	bool get insetAllowSimilarSilhouette {
		final Object? raw = _box.get(_kInsetAllowSimilarSilhouette);
		return raw is bool ? raw : false;
	}

	Future<void> setInsetAllowSimilarSilhouette(bool value) async {
		try {
			await _box.put(_kInsetAllowSimilarSilhouette, value);
		} catch (e) {
			debugPrint(
					"SettingsRepository.setInsetAllowSimilarSilhouette failed: $e");
		}
	}

	Future<void> setBigKidMode(bool value) async {
		try {
			await _box.put(_kBigKidMode, value);
		} catch (e) {
			debugPrint("SettingsRepository.setBigKidMode failed: $e");
		}
	}

	/// 讀指定畫面教學的「已看過版本號」，從未看過回 0。
	int tutorialVersionSeen(String screen) {
		return (_box.get("$_kTutorialVersionPrefix$screen") as int?) ?? 0;
	}

	/// 記錄指定畫面教學的「當前版本已看過」。
	Future<void> setTutorialVersionSeen(String screen, int version) async {
		try {
			await _box.put("$_kTutorialVersionPrefix$screen", version);
		} catch (e) {
			debugPrint("SettingsRepository.setTutorialVersionSeen failed: $e");
		}
	}

	/// 匯出用：把 settings box 內所有資料 dump 成純 JSON-friendly map。
	///
	/// 略過已知的 legacy / internal key（如 [_kEnabledSpriteSelectionsLegacy]），
	/// 避免把過渡期的舊資料帶到備份檔。
	Map<String, Object?> exportAll() {
		const Set<String> skipKeys = <String>{
			_kEnabledSpriteSelectionsLegacy,
			_kLegacyCutMode,
		};
		final Map<String, Object?> out = <String, Object?>{};
		for (final dynamic key in _box.keys) {
			if (key is! String) continue;
			if (skipKeys.contains(key)) continue;
			final Object? value = _box.get(key);
			// Hive 內可能是 Map<dynamic, dynamic> / List<dynamic>；遞迴轉成
			// JSON-safe（key 全 String）。
			out[key] = _toJsonSafe(value);
		}
		return out;
	}

	/// 匯入用：整批覆蓋 settings box。
	///
	/// 注意：**會先 clear box** 再 putAll。匯入後等於完全替換、舊設定全沒了
	/// （tutorialVersion.* 也一起換）。
	Future<void> importAll(Map<String, Object?> data) async {
		await _box.clear();
		await _box.putAll(data);
	}

	static Object? _toJsonSafe(Object? v) {
		if (v == null || v is bool || v is num || v is String) return v;
		if (v is List) return v.map<Object?>(_toJsonSafe).toList();
		if (v is Map) {
			return <String, Object?>{
				for (final MapEntry<Object?, Object?> e in v.entries)
					if (e.key is String) e.key as String: _toJsonSafe(e.value),
			};
		}
		// 其它型別（理論上不會出現）→ 轉成字串、保證可序列化
		return v.toString();
	}

	/// 清掉所有教學畫面的「已看過」紀錄，下次開對應畫面會重新播放教學。
	/// 用於家長區「重新觀看教學」按鈕。
	Future<void> resetAllTutorials() async {
		try {
			final List<dynamic> tutorialKeys = _box.keys
					.where((dynamic k) =>
							k is String && k.startsWith(_kTutorialVersionPrefix))
					.toList();
			await _box.deleteAll(tutorialKeys);
		} catch (e) {
			debugPrint("SettingsRepository.resetAllTutorials failed: $e");
		}
	}
}
