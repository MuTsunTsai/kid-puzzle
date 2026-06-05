// 非 web 平台的 stub：內建圖 / sprite 都是 bundled asset、不需要下載判定。

import "background_asset_cache.dart";

BackgroundAssetCache createBackgroundAssetCache() => _StubBackgroundAssetCache();

class _StubBackgroundAssetCache extends BackgroundAssetCache {
	@override
	bool isCached(String assetPath) => true;

	@override
	bool isSpriteCategoryCached(String categoryId) => true;

	@override
	bool get isOnline => true;

	@override
	Future<void> startPuzzleAssets(List<String> assetPaths) async {}

	@override
	void setSpriteAssets({
		required Map<String, SpriteAssetGroup> assets,
		required List<String> orderedCategoryIds,
	}) {}

	@override
	void setPriority(DownloadPriority priority) {}
}
