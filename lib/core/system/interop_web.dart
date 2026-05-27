import "dart:js_interop";

import "package:flutter_web_plugins/url_strategy.dart";
import "package:web/web.dart" as web;

// ===== 全螢幕 + 橫向鎖定 =====

/// 嘗試請求全螢幕 + 鎖定橫向。
///
/// 只在「手機瀏覽器」上做，理由：
/// - 手機才有實體旋轉的概念，全螢幕也才有意義（隱藏網址列、狀態列）。
/// - 桌機瀏覽器 `screen.orientation.lock()` 多半無法成功，且強制全螢幕對桌機使用者反而是干擾。
///
/// 偵測方式：`navigator.maxTouchPoints > 0` 且 user agent 含手機關鍵字。
/// 失敗一律靜默吞掉（包含已是全螢幕、瀏覽器不支援、user 拒絕等）。
Future<void> requestFullscreenLandscapeImpl() async {
	if (!_isMobileBrowser()) return;

	try {
		// 1. 請求全螢幕 — 必須在 user gesture handler 內呼叫
		final JSPromise<JSAny?> fsPromise =
				web.document.documentElement!.requestFullscreen();
		await fsPromise.toDart;
	} catch (_) {
		// 全螢幕失敗就直接返回，不嘗試鎖定方向（lock 多半也會失敗）
		return;
	}

	try {
		// 2. 鎖定橫向 — 必須在全螢幕狀態下才會成功
		final JSPromise<JSAny?> lockPromise =
				web.window.screen.orientation.lock("landscape");
		await lockPromise.toDart;
	} catch (_) {
		// 鎖定失敗就算了；瀏覽器已經是全螢幕，使用者手動轉即可
	}
}

/// 粗略偵測「手機瀏覽器」：
/// - 必須有觸控（maxTouchPoints > 0）
/// - 且 user agent 含 Android / iPhone / iPad / Mobile 等關鍵字
bool _isMobileBrowser() {
	final web.Navigator nav = web.window.navigator;
	final int touch = nav.maxTouchPoints;
	if (touch <= 0) return false;

	final String ua = nav.userAgent.toLowerCase();
	// iPadOS 13+ 預設給桌機 UA（含 "Macintosh"），但會回報 maxTouchPoints > 0，
	// 上面已先過濾觸控；這裡再交集 UA 關鍵字確保不是「外接觸控板的 Mac」。
	const List<String> mobileKeywords = <String>[
		"android",
		"iphone",
		"ipad",
		"ipod",
		"mobile",
	];
	for (final String kw in mobileKeywords) {
		if (ua.contains(kw)) return true;
	}
	// fallback：iPad 上桌機 UA + 有觸控 → 也視為手機
	if (ua.contains("macintosh") && touch > 1) return true;
	return false;
}

// ===== 字型 ready DOM event =====

/// Dispatch `flutter-fonts-ready` 到 window，讓 index.html 的 spinner 隱藏邏輯收到。
void dispatchFontsReadyEventImpl() {
	try {
		web.window.dispatchEvent(web.Event("flutter-fonts-ready"));
	} catch (_) {}
}

// ===== No-history UrlStrategy =====

/// 安裝「永遠不堆 history」的 UrlStrategy。
///
/// Flutter 預設 [HashUrlStrategy] 換頁時走 `history.pushState`，
/// 結果 iOS Safari / standalone PWA 的左右邊緣手勢會 back / forward 換頁。
/// 這裡覆寫 [pushState] 改呼叫 [replaceState]，history 長度永遠 = 1。
void installNoHistoryUrlStrategyImpl() {
	setUrlStrategy(const _NoHistoryHashUrlStrategy());
}

class _NoHistoryHashUrlStrategy extends HashUrlStrategy {
	const _NoHistoryHashUrlStrategy();

	@override
	void pushState(Object? state, String title, String url) {
		// 改用 replaceState：不新增 history entry。
		replaceState(state, title, url);
	}
}

// ===== PWA install hint =====

/// 回傳 PWA「加到主畫面」引導標籤；已 standalone 時回 null。
///
/// 文案不在這裡定義（見 [interop.dart] 的 `pwaInstallHint` 說明）。
String? pwaInstallHintImpl() {
	if (_isStandalone()) return null;
	return _isSafari() ? "safari" : "generic";
}

/// 偵測「已以 standalone PWA 啟動」：
/// - 大多數瀏覽器：`matchMedia("(display-mode: standalone)")`
/// - iOS Safari：non-standard `navigator.standalone === true`
bool _isStandalone() {
	try {
		if (web.window.matchMedia("(display-mode: standalone)").matches) {
			return true;
		}
	} catch (_) {}
	try {
		final bool? s = (web.window.navigator as _NavStandalone).standalone;
		if (s == true) return true;
	} catch (_) {}
	return false;
}

@JS()
extension type _NavStandalone(JSObject _) implements JSObject {
	external bool? get standalone;
}

/// 偵測 Safari（含 iOS Safari）；排除 Chrome / Edge / Firefox（UA 也含 "Safari"）。
bool _isSafari() {
	final String ua = web.window.navigator.userAgent;
	if (ua.contains("CriOS") || ua.contains("FxiOS") || ua.contains("EdgiOS")) {
		return false;
	}
	if (ua.contains("Chrome") || ua.contains("Chromium") || ua.contains("Edg/")) {
		return false;
	}
	return ua.contains("Safari");
}
