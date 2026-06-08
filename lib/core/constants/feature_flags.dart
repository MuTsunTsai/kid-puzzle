// 編譯期 / 啟動期 feature flag。
//
// 切換方式：
// - 改本檔 default 值（簡單）
// - 或 build 時 `flutter build ... --dart-define=ENABLE_INSET=true`（不改原始碼）

/// 是否啟用「嵌入拼圖」遊戲模式。
///
/// false 時：
/// - 首頁不顯示「嵌入拼圖」按鈕、「開始拼圖」按鈕直接進多片拼圖
/// - 家長頁不顯示「素材管理」入口（避免引導到 sprite 系統）
/// - main.dart 不啟動 SpriteRegistry 載入與 sprite 背景下載（節省啟動時間
///   與頻寬；sprite assets 仍會被 Flutter 打包進 binary、但 runtime 不會
///   實際 fetch）
/// - app_router 不註冊 inset / sprites 相關 route（避免 hash URL deep link
///   進入未準備好的頁面）
///
/// 之所以保留為 flag 而非整段刪除：嵌入拼圖開發仍在進行、預計很快開啟。
/// 修拖曳卡死 bug 需先發 production、暫時關掉這個模式。
const bool kEnableInsetPuzzle = bool.fromEnvironment(
	"ENABLE_INSET",
	defaultValue: false,
);
