import "dart:js_interop";
import "dart:typed_data";

import "package:web/web.dart" as web;

/// Web 平台實作：走 `window.fetch` 抓 `assets/assets/<path>?rev=<rev>`，方便
/// Service Worker 攔截做 reconcile（同 path 不同 rev 視為新版本、舊版
/// cache entry 在新版下載完後刪除）。
///
/// 雙層 `assets/` 不是錯：Flutter web 把所有 pubspec asset 放在
/// `build/web/assets/<原 pubspec 路徑>` 下，pubspec 路徑本身又以 `assets/`
/// 開頭、所以最終是 `assets/assets/...`。與 `rootBundle` 的內部 fetch 行為
/// 一致。
///
/// rev 為 null 時不加 query — 給 `sprites_revision.json` 這種「網路優先、
/// 自帶版本資訊」的小檔用。
Future<Uint8List> fetchSpriteBytes(String assetPath, {String? rev}) async {
	final String url = rev == null || rev.isEmpty
			? "assets/assets/$assetPath"
			: "assets/assets/$assetPath?rev=$rev";
	final web.Response response =
			await web.window.fetch(url.toJS).toDart;
	if (!response.ok) {
		throw StateError("fetch sprite asset failed: $url (${response.status})");
	}
	final JSArrayBuffer buf = await response.arrayBuffer().toDart;
	return buf.toDart.asUint8List();
}
