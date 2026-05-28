import "package:firebase_analytics/firebase_analytics.dart";
import "package:flutter/foundation.dart";

/// Firebase Analytics 薄包裝。
///
/// - 集中所有事件名稱與參數結構，避免 callsite 拼錯字串
/// - 任何呼叫失敗都會吞掉 — Analytics 故障不該影響遊戲本身
/// - debug 模式 print 出送出的事件，方便驗證
class AnalyticsService {
	AnalyticsService._();

	static final AnalyticsService instance = AnalyticsService._();

	FirebaseAnalytics? _ga;

	/// 用 [FirebaseAnalyticsObserver] 接到 Navigator → 自動送 screen_view。
	FirebaseAnalyticsObserver? _observer;

	/// 必須在 [Firebase.initializeApp] 之後呼叫。失敗一律靜默吞掉。
	void init() {
		try {
			_ga = FirebaseAnalytics.instance;
			_observer = FirebaseAnalyticsObserver(analytics: _ga!);
		} catch (_) {}
	}

	/// 給 [MaterialApp.navigatorObservers] 用；未初始化時為 null。
	FirebaseAnalyticsObserver? get observer => _observer;

	Future<void> _log(String name, Map<String, Object?> params) async {
		final FirebaseAnalytics? ga = _ga;
		if (ga == null) return;
		// 過濾掉 null 值；Firebase 不允許 null 參數
		final Map<String, Object> cleaned = <String, Object>{};
		params.forEach((String k, Object? v) {
			if (v != null) cleaned[k] = v;
		});
		if (kDebugMode) {
			debugPrint("[analytics] $name $cleaned");
		}
		try {
			await ga.logEvent(name: name, parameters: cleaned);
		} catch (_) {}
	}

	// ===== 自訂事件 =====

	/// 進入關卡。
	Future<void> logLevelStart({
		required int pieceCount,
		required String cutMode,
	}) => _log("level_start", <String, Object?>{
				"piece_count": pieceCount,
				"cut_mode": cutMode,
			});

	/// 完成關卡。
	Future<void> logLevelComplete({
		required int pieceCount,
		required String cutMode,
		required int durationSec,
	}) => _log("level_complete", <String, Object?>{
				"piece_count": pieceCount,
				"cut_mode": cutMode,
				"duration_sec": durationSec,
			});

	/// 中途離開關卡（未完成）。
	Future<void> logLevelExit({
		required int pieceCount,
		required String cutMode,
		required int durationSec,
	}) => _log("level_exit", <String, Object?>{
				"piece_count": pieceCount,
				"cut_mode": cutMode,
				"duration_sec": durationSec,
			});

	/// 家長頁點下「請作者喝咖啡」項目（外連跳轉前送出）。
	Future<void> logTipJarOpened() => _log("tip_jar_opened", <String, Object?>{});

	/// 家長頁確認「重新觀看教學」（取消不送）。
	Future<void> logResetTutorials() =>
			_log("reset_tutorials", <String, Object?>{});

	/// 切換「大朋友模式」開關。
	Future<void> logBigKidModeToggled({required bool enabled}) =>
			_log("big_kid_mode_toggled", <String, Object?>{
				"enabled": enabled,
			});
}
