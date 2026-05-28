// 非 web 平台的 stub：所有 web interop 函式皆 no-op。

Future<void> requestFullscreenLandscapeImpl() async {}

void dispatchFontsReadyEventImpl() {}

void installNoHistoryUrlStrategyImpl() {}

String? pwaInstallHintImpl() => null;

({int n, int seed})? readDebugLevelQueryImpl() => null;

void openExternalUrlImpl(String url) {}
