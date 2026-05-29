// Web 端內建圖快取追蹤 + 背景下載。
//
// 設計：service worker（sw.ts）已配置 StaleWhileRevalidate + cacheName="runtime"
// 對所有 same-origin GET 攔截寫入 cache。本服務只需：
// 1. 啟動時掃 `caches.open("runtime")` 看哪些 asset 已 cache → _cached
// 2. 未 cache 的丟進 queue，連網時 sequentially fetch（讀完 body 才算下載完
//    —— 讓 SW 完成 cache write）
// 3. 監聽 online/offline event：online → 重啟 worker；offline → worker 暫停
//
// _cached 是 in-memory；SW cache 是 source of truth、_cached 是給 UI 快查用。

import "dart:async";
import "dart:js_interop";

import "package:web/web.dart" as web;

import "builtin_image_cache.dart";

BuiltinImageCache createBuiltinImageCache() => _WebBuiltinImageCache();

/// SW 內 StaleWhileRevalidate 用的 cache 名稱（必須與 [service/src/sw.ts]
/// 內的 `setDefaultHandler` cacheName 一致）。
const String _kRuntimeCacheName = "runtime";

class _WebBuiltinImageCache extends BuiltinImageCache {
	final Set<String> _cached = <String>{};
	final List<String> _queue = <String>[];
	bool _started = false;
	bool _workerRunning = false;
	bool _online = true;

	@override
	bool isCached(String assetPath) => _cached.contains(assetPath);

	@override
	bool get isOnline => _online;

	@override
	Future<void> start(List<String> assetPaths) async {
		if (_started) return;
		_started = true;
		_online = web.window.navigator.onLine;

		// 監聽 online / offline：online 重啟 worker、offline 讓 worker 自然停。
		web.window.addEventListener("online", ((web.Event _) {
			_online = true;
			_kickWorker();
			notifyListeners();
		}).toJS);
		web.window.addEventListener("offline", ((web.Event _) {
			_online = false;
			notifyListeners();
		}).toJS);

		// 初次掃 SW cache，看哪些 asset 已下載。
		await _rescanCache(assetPaths);
		// 未下載的進 queue
		for (final String p in assetPaths) {
			if (!_cached.contains(p)) _queue.add(p);
		}
		notifyListeners();
		_kickWorker();
	}

	/// 一張一張 fetch；失敗 / 斷網就停、留待下次 online event 重啟。
	Future<void> _kickWorker() async {
		if (_workerRunning) return;
		if (!_online) return;
		_workerRunning = true;
		try {
			while (_queue.isNotEmpty && _online) {
				final String assetPath = _queue.removeAt(0);
				final bool ok = await _fetchAndCheck(assetPath);
				if (ok) {
					_cached.add(assetPath);
					notifyListeners();
				} else {
					// 失敗丟回隊伍末端、下次 online tick 再試；避免單張壞圖卡死
					// 整條 queue，先離開讓使用者操作 UI 不阻塞。
					_queue.add(assetPath);
					break;
				}
				// 避免一口氣塞滿瀏覽器 fetch queue / 跟 Flutter 載入搶頻寬
				await Future<void>.delayed(const Duration(milliseconds: 200));
			}
		} finally {
			_workerRunning = false;
		}
	}

	Future<bool> _fetchAndCheck(String assetPath) async {
		try {
			final String url = _assetUrl(assetPath);
			final web.Response res = await web.window
					.fetch(url.toJS)
					.toDart;
			if (!res.ok) return false;
			// 讀完 body 才算下載完成（讓 SW 的 SWR strategy 把 body 寫進 cache）
			await res.arrayBuffer().toDart;
			return true;
		} catch (_) {
			return false;
		}
	}

	/// 對應每張 asset 在 web build 後的實際 URL。
	///
	/// Flutter web 把 pubspec 內 `assets/...` 路徑放在 `assets/` 子目錄下、
	/// 所以實際 URL 是 `assets/<原 asset path>`。
	String _assetUrl(String assetPath) => "assets/$assetPath";

	Future<void> _rescanCache(List<String> assetPaths) async {
		try {
			final web.Cache cache = await web.window.caches
					.open(_kRuntimeCacheName)
					.toDart;
			for (final String p in assetPaths) {
				final web.Response? r = await cache
						.match(_assetUrl(p).toJS)
						.toDart;
				if (r != null) _cached.add(p);
			}
		} catch (_) {
			// cache 不存在 / 權限失敗：全當未 cache
		}
	}
}
