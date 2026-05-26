import "fullscreen_landscape_stub.dart"
		if (dart.library.js_interop) "fullscreen_landscape_web.dart";

/// 嘗試請求「全螢幕 + 鎖定橫向」。
///
/// - Web 平台：呼叫 `Element.requestFullscreen()` + `ScreenOrientation.lock("landscape")`。
///   兩者都必須在 user gesture handler 內呼叫，瀏覽器才會允許。
/// - 其他平台：直接 no-op（Android 已在 manifest 強制橫向；iOS 不適用）。
///
/// 失敗（使用者已經是橫向、瀏覽器不支援、user 拒絕）一律靜默吞掉，不影響後續流程。
Future<void> requestFullscreenLandscape() => requestFullscreenLandscapeImpl();
