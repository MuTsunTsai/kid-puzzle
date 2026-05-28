// 非 web 平台的 stub：web 專屬的 interop 全部 no-op；
// 跨平台的 [openExternalUrlImpl] 走 url_launcher（Android/iOS 都吃）。

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
