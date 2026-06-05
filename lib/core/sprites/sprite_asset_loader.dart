import "dart:async";
import "dart:convert";

import "package:flutter/foundation.dart";
import "package:flutter/services.dart";

import "sprite_asset_loader_io.dart"
		if (dart.library.js_interop) "sprite_asset_loader_web.dart" as platform;

/// Sprite 資源 fetch 統一入口。
///
/// 設計目的：web 版需要在 URL 帶 `?rev=<hash>` 強迫 cache busting + 給
/// Service Worker reconcile 用；非 web 平台（Android / iOS）打包成 asset
/// bundle、不需要也不能帶 query。
///
/// - 非 web：呼叫 [rootBundle].load — `rev` 參數忽略。
/// - Web：走 conditional import 的 [platform.fetchSpriteBytes] → HTTP fetch
///   `assets/<path>?rev=<rev>`，Service Worker 可以攔到完整 URL。
///
/// [assetPath] 一律是 manifest 內的相對路徑（不含 `assets/` 前綴），例如
/// `"data/sprites.json"`、`"images/sprites/household.webp"`。
Future<Uint8List> loadSpriteBytes(String assetPath, {String? rev}) async {
	if (!kIsWeb) {
		final ByteData bd = await rootBundle.load("assets/$assetPath");
		return bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);
	}
	return platform.fetchSpriteBytes(assetPath, rev: rev);
}

/// 給只需要文字內容的呼叫端用（例如 sprites.json）。
///
/// 一律 UTF-8 解碼。**不要**用 `String.fromCharCodes(bytes)` — 那會把每個
/// byte 當 UTF-16 code unit、中文 / 注音 / 任何非 ASCII 字元全變亂碼。
Future<String> loadSpriteString(String assetPath, {String? rev}) async {
	final Uint8List bytes = await loadSpriteBytes(assetPath, rev: rev);
	return utf8.decode(bytes);
}
