import "package:flutter/foundation.dart";
import "package:flutter/services.dart";

/// 系統列防誤觸：包裝 Android 的「App Pinning（畫面釘選 / Lock Task Mode）」。
///
/// 進入拼圖頁時呼叫 [enable] 啟動 lock task：系統會把當前 app 釘選在畫面、
/// 完全鎖住 status bar 下拉與 home / recents 手勢、幼兒不會誤觸離開遊戲。
/// 退出時呼叫 [disable] 解除。
///
/// **注意**：解除 lock task 時、Samsung 等某些機型會自動進螢幕鎖定。這是
/// 系統行為、無法繞過；UI 端應在進入前讓家長明確選擇是否啟用本機制。
///
/// **平台支援**：只有 Android。iOS / web 全部回 false / no-op。
class SystemGuard {
	SystemGuard._();

	static const MethodChannel _channel = MethodChannel("kid_puzzle/system");

	/// 啟用 app pinning。回 true 成功；false 通常表示非 Android 平台或 system
	/// 拒絕（極少數機型 / 模式可能無法啟用）。
	static Future<bool> enable() async {
		if (!_isAndroid) return false;
		try {
			final bool? ok = await _channel.invokeMethod<bool>("enableLockTask");
			return ok == true;
		} catch (e) {
			debugPrint("SystemGuard.enable failed: $e");
			return false;
		}
	}

	/// 解除 app pinning。idempotent；本來就沒啟用也回 true。
	static Future<bool> disable() async {
		if (!_isAndroid) return false;
		try {
			final bool? ok = await _channel.invokeMethod<bool>("disableLockTask");
			return ok == true;
		} catch (e) {
			debugPrint("SystemGuard.disable failed: $e");
			return false;
		}
	}

	static bool get _isAndroid =>
			!kIsWeb && defaultTargetPlatform == TargetPlatform.android;
}
