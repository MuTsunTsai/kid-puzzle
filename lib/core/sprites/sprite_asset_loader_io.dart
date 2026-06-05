import "dart:typed_data";

/// 非 web 平台 stub。實際被 [loadSpriteBytes] 用條件 import 隔開、不會被呼到，
/// 但保留 signature 讓 dart 分析器能 resolve。
Future<Uint8List> fetchSpriteBytes(String assetPath, {String? rev}) {
	throw UnsupportedError(
		"sprite_asset_loader_io.fetchSpriteBytes 只在 web 平台會被呼叫，"
		"非 web 平台請使用 loadSpriteBytes(...) 自動走 rootBundle。",
	);
}
