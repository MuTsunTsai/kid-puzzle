// 內建拼圖圖的「背景下載 / 已下載偵測 / 線上狀態」服務。
//
// 跨平台分流（conditional import）：
// - web：builtin_image_cache_web.dart — 真正去掃 SW cache、發 fetch
// - 其他：builtin_image_cache_stub.dart — 永遠 isCached=true、isOnline=true、
//   start() no-op（Android 等平台、內建圖是 bundled asset、不需要下載）
//
// 用法：
//   final BuiltinImageCache c = BuiltinImageCache.instance;
//   await c.start(assetPaths);                       // app.dart initState 啟動
//   c.addListener(() {  /* UI 更新 */ });            // ChangeNotifier 介面
//   if (c.isCached("assets/images/puzzles/x.jpg"))   // 圖庫頁 / 選圖時查詢

import "package:flutter/foundation.dart";

import "builtin_image_cache_stub.dart"
		if (dart.library.js_interop) "builtin_image_cache_web.dart";

abstract class BuiltinImageCache extends ChangeNotifier {
	BuiltinImageCache();

	static final BuiltinImageCache instance = createBuiltinImageCache();

	/// 是否已下載到 SW cache。非 web 一律 true。
	bool isCached(String assetPath);

	/// 目前是否連網（web：`navigator.onLine`；其他：永遠 true）。
	bool get isOnline;

	/// 啟動背景下載 worker（idempotent；多次呼叫只起一次）。
	///
	/// [assetPaths] 是內建圖的 asset 路徑清單（如
	/// `"assets/images/puzzles/cat.jpg"`），web 端會去 fetch 它們的實際 URL
	/// (`assets/` prefix + 原路徑)，SW 攔截後寫入 runtime cache。
	Future<void> start(List<String> assetPaths);
}
