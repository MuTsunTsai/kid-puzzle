import "package:firebase_analytics/firebase_analytics.dart";
import "package:flutter/foundation.dart";

/// Firebase Analytics 薄包裝。
///
/// - 集中所有事件名稱與參數結構，避免 callsite 拼錯字串
/// - 任何呼叫失敗都會吞掉 — Analytics 故障不該影響遊戲本身
/// - debug 模式 print 出送出的事件，方便驗證
/// - Firebase 的事件參數只接受字串與數字：布林一律用 [flag] 轉成
///   `"true"` / `"false"`
///
/// 事件與參數一覽見 CLAUDE.md「Analytics」一節。
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

	/// 布林轉成事件參數 / 使用者屬性可用的字串。
	static String flag(bool value) => value ? "true" : "false";

	/// 目前的 renderer：`wasm` / `js`（web）或 `native`。
	static String get renderer => kIsWasm ? "wasm" : (kIsWeb ? "js" : "native");

	Future<void> _log(String name, Map<String, Object?> params) async {
		final FirebaseAnalytics? ga = _ga;
		if (ga == null) return;
		// 過濾掉 null 值；Firebase 不允許 null 參數
		final Map<String, Object> cleaned = <String, Object>{};
		params.forEach((String k, Object? v) {
			if (v == null) return;
			cleaned[k] = v is bool ? flag(v) : v;
		});
		if (kDebugMode) {
			debugPrint("[analytics] $name $cleaned");
		}
		try {
			await ga.logEvent(name: name, parameters: cleaned);
		} catch (_) {}
	}

	// ===== 使用者屬性 =====

	/// 設定使用者屬性（名稱 ≤ 24 字元、值 ≤ 36 字元）。
	///
	/// 目前使用：`big_kid_mode` / `audio_enabled` / `voice_enabled`（"true" /
	/// "false"）、`launch_mode`（pwa / browser / android_app / ios_app）、
	/// `renderer`（wasm / js / native）。
	Future<void> setUserProperty(String name, String value) async {
		final FirebaseAnalytics? ga = _ga;
		if (ga == null) return;
		if (kDebugMode) {
			debugPrint("[analytics] user_property $name=$value");
		}
		try {
			await ga.setUserProperty(name: name, value: value);
		} catch (_) {}
	}

	// ===== 關卡事件（三個遊戲模式共用，經由 [LevelTracker] 送出）=====

	static const String gameModePuzzle = "puzzle";
	static const String gameModeInset = "inset";
	static const String gameModeMemory = "memory";

	Future<void> _logLevelEvent(String name, Map<String, Object?> params) =>
			_log(name, params);

	// ===== 教學 =====

	/// 本次 app 執行期間已開始、尚未結束的教學（key = 畫面名稱）。
	/// 用來確保 tutorial_complete 只對真的開始過的教學送出（例如多片拼圖
	/// 設定頁「至少選一種切割模式」的提示也走 showcase，但不算教學）。
	final Set<String> _activeTutorials = <String>{};

	/// 教學開始（GA 建議事件 `tutorial_begin`）。
	Future<void> logTutorialBegin(String screen) {
		_activeTutorials.add(screen);
		return _log("tutorial_begin", <String, Object?>{"tutorial_screen": screen});
	}

	/// 教學走完最後一步（GA 建議事件 `tutorial_complete`）。
	/// 中途離開頁面不會送，begin 與 complete 的差即為中途放棄。
	Future<void> logTutorialComplete(String screen) async {
		if (!_activeTutorials.remove(screen)) return;
		await _log("tutorial_complete", <String, Object?>{"tutorial_screen": screen});
	}

	// ===== 技術退回 / 保險機制 =====

	/// 記錄技術退回或保險機制被觸發（給除錯與裝置相容性觀察用）。
	///
	/// [kind]：
	/// - `pixel_to_byte_data`：web 的 canvas 像素解碼失敗、退回 toByteData
	/// - `voice_watchdog`：物件名稱語音沒收到播完事件、由逾時保險結束
	/// - `voice_wait_timeout`：過關前等最後一句語音逾時
	/// - `inset_layout_shrink`：嵌入拼圖排版需縮小 tile 才不重疊（[value] = 縮小輪數）
	/// - `inset_layout_overlap`：縮小到上限仍有重疊（[value] = 縮小輪數）
	Future<void> logTechFallback(String kind, {int? value}) =>
			_log("tech_fallback", <String, Object?>{
				"fallback_kind": kind,
				"fallback_value": value,
				"renderer": renderer,
			});

	// ===== 載入效能 =====

	/// Web：頁面開始載入到 Flutter 第一個畫面的時間。
	/// [swControlled] = 頁面由 Service Worker 提供（通常代表有快取、非首次造訪）。
	Future<void> logAppLoad({required int loadMs, required bool swControlled}) =>
			_log("app_load", <String, Object?>{
				"load_ms": loadMs,
				"sw_controlled": swControlled,
				"renderer": renderer,
			});

	// ===== 內容使用 =====

	/// 家長在素材管理頁改了勾選（離開頁面時送一次）。
	Future<void> logSpriteSelection(List<String> enabledCategories) =>
			_log("sprite_selection", <String, Object?>{
				"enabled_count": enabledCategories.length,
				// 參數值上限 100 字元；9 個類別 id 用逗號串起來約 70 字元。
				"enabled_categories": enabledCategories.join(","),
			});

	/// 圖庫匯入完成（含中途停止）。
	Future<void> logGalleryImport({
		required int imported,
		required int skipped,
		required bool aborted,
	}) => _log("gallery_import", <String, Object?>{
				"image_count": imported,
				"skipped_count": skipped,
				"aborted": aborted,
			});

	// ===== 家長頁 =====

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

/// 單一關卡的 Analytics 追蹤：開始時送 `level_start`，之後只會送一次
/// `level_complete` 或 `level_exit`（先到先送）。
///
/// 共通參數（建構時給定、三個事件都帶）：
/// - `game_mode`：puzzle / inset / memory
/// - `piece_count`：這一局的片數（多片拼圖 = 拼片、嵌入拼圖 = 物件、記憶遊戲 = 卡片張數）
/// - `level_index`：這次進入該模式後的第幾關（從 1 起算）
/// - `range_min` / `range_max`：家長設定的範圍（多片拼圖 / 嵌入拼圖 = 片數、
///   記憶遊戲 = 組數）
/// - `screen_lock`：是否啟用鎖定畫面
/// - 各模式專屬：`cut_mode`、`hint_enabled`、`rotation_enabled`（多片拼圖）、
///   `similar_allowed`（嵌入拼圖）、`category`（嵌入拼圖 / 記憶遊戲）、
///   `pair_count`（記憶遊戲）
///
/// complete / exit 另帶：
/// - `duration_sec`
/// - `drop_miss_count`：放下但沒吸附的次數（多片拼圖 / 嵌入拼圖）
/// - `flip_count` / `mismatch_count`：有效翻牌 / 配對失敗次數（記憶遊戲）
///
/// 2026-11 以前的 level_* 事件沒有 game_mode，一律是多片拼圖。
class LevelTracker {
	LevelTracker({
		required String gameMode,
		required int pieceCount,
		required int levelIndex,
		required int rangeMin,
		required int rangeMax,
		required bool screenLock,
		Map<String, Object?> extra = const <String, Object?>{},
	}) : _params = <String, Object?>{
					"game_mode": gameMode,
					"piece_count": pieceCount,
					"level_index": levelIndex,
					"range_min": rangeMin,
					"range_max": rangeMax,
					"screen_lock": screenLock,
					...extra,
				};

	final Map<String, Object?> _params;
	final DateTime _startedAt = DateTime.now();
	bool _ended = false;

	/// 放下但沒吸附的次數（多片拼圖 / 嵌入拼圖）。
	int dropMissCount = 0;

	/// 有效翻牌次數（記憶遊戲；點到已翻開 / 已配對 / 鎖定中的卡不算）。
	int flipCount = 0;

	/// 配對失敗次數（記憶遊戲）。
	int mismatchCount = 0;

	/// 是否還在進行中（尚未送出 complete / exit）。
	bool get isActive => !_ended;

	Future<void> start() =>
			AnalyticsService.instance._logLevelEvent("level_start", _params);

	Future<void> complete() => _end("level_complete");

	Future<void> exit() => _end("level_exit");

	Future<void> _end(String name) async {
		if (_ended) return;
		_ended = true;
		final String mode = _params["game_mode"]! as String;
		await AnalyticsService.instance._logLevelEvent(name, <String, Object?>{
			..._params,
			"duration_sec": DateTime.now().difference(_startedAt).inSeconds,
			if (mode == AnalyticsService.gameModeMemory) ...<String, Object?>{
				"flip_count": flipCount,
				"mismatch_count": mismatchCount,
			} else
				"drop_miss_count": dropMissCount,
		});
	}
}
