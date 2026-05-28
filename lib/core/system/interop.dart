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

/// 安裝「不寫入瀏覽器 history」的 UrlStrategy。
///
/// Flutter Web 預設每次 Navigator.pushNamed 都會 `history.pushState`，
/// 結果 iOS Safari / standalone PWA 的左/右邊緣手勢就會觸發 back / forward
/// 換頁。把所有 pushState 改成 replaceState 之後 history 長度永遠 = 1，
/// 邊緣手勢無事可做。其他平台 no-op。
void installNoHistoryUrlStrategy() => installNoHistoryUrlStrategyImpl();

/// 回傳 PWA「加到主畫面」引導種類；不需要顯示時回 null。
///
/// 回傳值為簡單字串標籤，由 UI 端對應到實際文案（文案集中在 UI 端、
/// 一併寫入 FontReadyProbe 預熱字元集，不在 interop 層重複定義）：
/// - `"safari"`：Safari（含 iOS Safari）→ 分享選單 → 加入主畫面
/// - `"generic"`：其他瀏覽器 → 瀏覽器選單 → 加到主畫面
/// - `null`：非 web、或已 standalone（已安裝為 PWA）
///
/// 用字串而非 enum：跨 conditional import 邊界需要共用型別會被迫多開檔，
/// 標籤集合就兩個值、簡單字串更輕。
String? pwaInstallHint() => pwaInstallHintImpl();

/// Debug 後門：讀 URL query 中的 `n` 與 `seed`，回傳 (n, seed)。
///
/// 只在 web 有意義；其他平台 / 缺參數 / 解析失敗一律 null。
/// 用法：`?n=5&seed=1250263700` → 直接跳進拼圖頁用該參數 + voronoi 切割。
({int n, int seed})? readDebugLevelQuery() => readDebugLevelQueryImpl();

/// 在新分頁 / 系統瀏覽器開啟外部 URL（給「請作者喝咖啡」等外連用）。
///
/// Web 走 `window.open` + noopener；其他平台走 url_launcher 的
/// `externalApplication` 模式（Android/iOS 都會跳出系統瀏覽器）。
void openExternalUrl(String url) => openExternalUrlImpl(url);
