// 背景資源快取 / 已下載偵測 / 線上狀態服務。
//
// 涵蓋三種 Web 端需要背景下載的素材：
// - 多片拼圖內建圖（`assets/images/puzzles/*`）
// - Sprite sheet webp（每類別一張，帶 rev query）
// - Sprite 語音 zip（每類別一份，帶 rev query）
//
// 跨平台分流（conditional import）：
// - web：background_asset_cache_web.dart — 真正去掃 SW cache、發 fetch
// - 其他：background_asset_cache_stub.dart — 永遠 isCached=true、isOnline=true、
//   start*/setPriority/setSpriteAssets no-op（行動平台是 bundled asset、
//   不需要背景下載）
//
// 用法：
//   final BackgroundAssetCache c = BackgroundAssetCache.instance;
//   await c.startPuzzleAssets(assetPaths);            // app 啟動
//   c.setSpriteAssets(...);                            // SpriteRegistry load 完
//   c.setPriority(DownloadPriority.sprite);           // RouteObserver 通知
//   c.addListener(() {  /* UI 更新 */ });
//   if (c.isCached("assets/images/puzzles/x.jpg"))    // 圖庫頁 / 選圖時查詢
//   if (c.isSpriteCategoryCached("food"))             // 嵌入拼圖選類別前查詢

import "package:flutter/foundation.dart";

import "background_asset_cache_stub.dart"
		if (dart.library.js_interop) "background_asset_cache_web.dart";

/// 背景下載 worker 的優先模式。Worker 每次取下一個任務時依此決定先 drain
/// 哪一條 sub-queue。
enum DownloadPriority {
	/// 多片拼圖圖片優先（在「圖庫管理」/「多片拼圖」相關頁面時）。
	puzzle,
	/// Sprite 資源優先（在「素材管理」/ 多片拼圖以外的遊戲模式相關頁面時）。
	sprite,
	/// 沒有偏好 — 隨機從兩條 queue 取（或依工程實作的 fair 規則）。
	none,
}

/// 單一 sprite 類別的資源組（sheet webp + voice zip）。路徑為含 query 的
/// 完整 asset URL，例如 `"assets/images/sprites/food.webp?rev=abc123"`。
class SpriteAssetGroup {
	const SpriteAssetGroup({required this.sheetUrl, required this.voiceUrl});
	final String sheetUrl;
	final String voiceUrl;
}

abstract class BackgroundAssetCache extends ChangeNotifier {
	BackgroundAssetCache();

	static final BackgroundAssetCache instance = createBackgroundAssetCache();

	/// 是否已下載到 SW cache。非 web 一律 true。
	bool isCached(String assetPath);

	/// 某 sprite 類別（id）的 sheet + voice 是否都已下載。
	/// 未透過 [setSpriteAssets] 註冊過的類別回 false（web）/ true（其他）。
	bool isSpriteCategoryCached(String categoryId);

	/// 目前是否連網（web：`navigator.onLine`；其他：永遠 true）。
	bool get isOnline;

	/// 啟動「多片拼圖內建圖」背景下載 worker（idempotent；多次呼叫只起一次）。
	///
	/// [assetPaths] 是內建圖的 asset 路徑清單（如
	/// `"assets/images/puzzles/cat.jpg"`），web 端會去 fetch 它們的實際 URL
	/// (`assets/` prefix + 原路徑)，SW 攔截後寫入 runtime cache。
	Future<void> startPuzzleAssets(List<String> assetPaths);

	/// 註冊 sprite 類別資源組。typically 在 SpriteRegistry load 完後呼叫一次、
	/// 提供所有類別的 (sheet 帶 rev、voice zip 帶 rev) 完整 URL。
	///
	/// [orderedCategoryIds] 是預設下載順序（建議：已選取的類別在前、其餘
	/// 在後）。assets 內找不到的 catId 會被忽略。
	void setSpriteAssets({
		required Map<String, SpriteAssetGroup> assets,
		required List<String> orderedCategoryIds,
	});

	/// 設定當下優先模式。Worker 在跑下一個任務前讀此值決定取哪條 queue。
	void setPriority(DownloadPriority priority);
}
