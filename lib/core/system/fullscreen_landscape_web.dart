import "dart:js_interop";

import "package:web/web.dart" as web;

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
