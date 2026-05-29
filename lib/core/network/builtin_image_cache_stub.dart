// 非 web 平台的 stub：內建圖是 bundled asset、不需要下載判定。

import "builtin_image_cache.dart";

BuiltinImageCache createBuiltinImageCache() => _StubBuiltinImageCache();

class _StubBuiltinImageCache extends BuiltinImageCache {
	@override
	bool isCached(String assetPath) => true;

	@override
	bool get isOnline => true;

	@override
	Future<void> start(List<String> assetPaths) async {}
}
