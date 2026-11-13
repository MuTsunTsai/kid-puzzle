// 非 web 平台的 stub：web 專屬的 interop 全部 no-op；
// 跨平台的 [openExternalUrlImpl] 走 url_launcher（Android/iOS 都吃）。

import "package:flutter/foundation.dart" show debugPrint;
import "package:flutter_gpu/gpu.dart" as gpu;
import "package:url_launcher/url_launcher.dart";

Future<void> requestFullscreenLandscapeImpl() async {}

void dispatchFontsReadyEventImpl() {}

void installNoHistoryUrlStrategyImpl() {}

String? pwaInstallHintImpl() => null;

({int n, int seed})? readDebugLevelQueryImpl() => null;

void openExternalUrlImpl(String url) {
	// fire-and-forget；失敗一律靜默吞掉（外連跳轉不該影響家長頁本身）
	final Uri? uri = Uri.tryParse(url);
	if (uri == null) return;
	launchUrl(uri, mode: LaunchMode.externalApplication).catchError((_) => false);
}

String? webLaunchModeImpl() => null;

({int elapsedMs, bool swControlled})? webLoadTimingImpl() => null;

/// Flutter GPU 只能跑在 Impeller 上。Android 10（API 29）以下、或 Vivante GPU 的裝置，引擎
/// 會退回舊的 Skia 渲染器（Android 9 由 MainApplication.kt 騙過去、仍用 Impeller）（log 會印「Impeller opt-out deprecated」，但其實不是我們關的），
/// 這時取用 gpuContext 會拋「Flutter GPU requires the Impeller rendering backend」。
/// 只檢查一次。
final bool supports3dImpl = _checkSupports3d();

bool _checkSupports3d() {
	try {
		gpu.gpuContext;
		return true;
	} catch (e) {
		debugPrint("3D 不支援：$e");
		return false;
	}
}
