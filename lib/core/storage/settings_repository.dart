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
	static const String _kTtsEnabled = "ttsEnabled";

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
	bool get ttsEnabled => (_box.get(_kTtsEnabled) as bool?) ?? true;

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

	Future<void> setAudioEnabled(bool value) async {
		try {
			await _box.put(_kAudioEnabled, value);
		} catch (e) {
			debugPrint("SettingsRepository.setAudioEnabled failed: $e");
		}
	}

	Future<void> setTtsEnabled(bool value) async {
		try {
			await _box.put(_kTtsEnabled, value);
		} catch (e) {
			debugPrint("SettingsRepository.setTtsEnabled failed: $e");
		}
	}
}
