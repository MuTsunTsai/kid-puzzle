// Web 平台特有操作的統一入口；其他平台一律 no-op。
//
// 透過 conditional import 自動切換實作：
// - Web：interop_web.dart — 走 dart:js_interop 與 package:web。
// - 其他：interop_stub.dart。
import "interop_stub.dart" if (dart.library.js_interop) "interop_web.dart";

/// 嘗試請求「全螢幕 + 鎖定橫向」。
///
/// 只在 web 手機瀏覽器有效；必須在 user gesture handler 內呼叫。
/// 失敗（瀏覽器不支援、user 拒絕、已是全螢幕）一律靜默吞掉。
Future<void> requestFullscreenLandscape() => requestFullscreenLandscapeImpl();

/// Dispatch `flutter-fonts-ready` DOM event。
///
/// 給 web/index.html 的 spinner 隱藏邏輯收訊號用；其他平台 no-op。
void dispatchFontsReadyEvent() => dispatchFontsReadyEventImpl();
