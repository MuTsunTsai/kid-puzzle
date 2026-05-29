// Flutter web 載入器（Flutter 3.22+ 推薦用 flutter_bootstrap.js 自訂）。
//
// 主要目的：
// 1. 透過 onEntrypointLoaded 三個階段（entrypoint 下載完 / engine init 完 /
//    runApp 後）dispatch `flutter-loading-progress` 事件，由 index.html 端
//    把進度條推進到 33% / 66% / 90%；最後 100% 由 `flutter-first-frame`
//    觸發。
// 2. 把 canvaskit 自 host（canvasKitBaseUrl: "canvaskit/"），改走自己的
//    origin → service worker 可快取 → PWA 第二次開站近乎瞬開。預設會去
//    gstatic.com 抓、跨網域 SW 抓不到。

{{flutter_js}}
{{flutter_build_config}}

function _progress(value) {
	try {
		window.dispatchEvent(new CustomEvent("flutter-loading-progress", {
			detail: { value: value },
		}));
	} catch (_) {}
}

_progress(10);

// Service worker 由 index.html 在載入這支腳本之前就註冊好（自製、Workbox-based），
// 已棄用的 flutter_service_worker.js 不再產生（build 時 --pwa-strategy=none），
// 因此 loader 不傳 serviceWorkerSettings。
_flutter.loader.load({
	config: {
		// 自 host CanvasKit；對應 build/web/canvaskit/ 由 Flutter 自動產生。
		canvasKitBaseUrl: "canvaskit/",
	},
	onEntrypointLoaded: async function (engineInitializer) {
		_progress(33);
		const appRunner = await engineInitializer.initializeEngine();
		_progress(66);
		await appRunner.runApp();
		_progress(90);
	},
});
