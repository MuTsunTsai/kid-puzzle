// Web 端背景下載 + cache 追蹤。
//
// 兩條 sub-queue：
// - _puzzleQueue：多片拼圖內建圖 asset path（不含 query；SW 寫到 cache name
//   "runtime"、走 StaleWhileRevalidate）
// - _spriteQueue：sprite 資源完整 URL（含 ?rev=...；SW 寫到 cache name
//   "sprite-revisioned-v1"、走自製 reconcile）
//
// Worker 每次取下一個任務時依當下 [DownloadPriority] 決定先取哪條：
// - puzzle  → puzzle 空了才拿 sprite
// - sprite  → sprite 空了才拿 puzzle
// - none    → 哪條長度多就取那條（簡單 fair 策略，避免單側餓死）

import "dart:async";
import "dart:js_interop";
import "dart:math";

import "package:web/web.dart" as web;

import "background_asset_cache.dart";

BackgroundAssetCache createBackgroundAssetCache() => _WebBackgroundAssetCache();

/// SW 內 StaleWhileRevalidate 用的 cache 名稱（與 [service/src/sw.ts] 內
/// 預設 handler 的 cacheName 一致）。多片拼圖內建圖走這條。
const String _kRuntimeCacheName = "runtime";

/// SW 內 sprite reconcile handler 用的 cache 名稱（與 sw.ts 內
/// `SPRITE_CACHE` 常數一致）。sprite 資源走這條。
const String _kSpriteCacheName = "sprite-revisioned-v1";

class _WebBackgroundAssetCache extends BackgroundAssetCache {
	// === Puzzle ===
	final Set<String> _puzzleCached = <String>{};
	final List<String> _puzzleQueue = <String>[];

	// === Sprite ===
	/// catId → 該類別的兩個 URL（sheet / voice，含 rev query）
	final Map<String, SpriteAssetGroup> _spriteAssets =
			<String, SpriteAssetGroup>{};
	/// 已下載的 sprite asset URL（含 query）集合。
	final Set<String> _spriteCachedUrls = <String>{};
	final List<String> _spriteQueue = <String>[];

	/// Shuffle queue 用。每次 app 啟動 enqueue 順序不同。
	final Random _shuffleRandom = Random();

	bool _started = false;
	bool _workerRunning = false;
	bool _online = true;
	DownloadPriority _priority = DownloadPriority.none;

	@override
	bool isCached(String assetPath) => _puzzleCached.contains(assetPath);

	@override
	bool isSpriteCategoryCached(String categoryId) {
		final SpriteAssetGroup? g = _spriteAssets[categoryId];
		if (g == null) return false;
		return _spriteCachedUrls.contains(g.sheetUrl) &&
				_spriteCachedUrls.contains(g.voiceUrl);
	}

	@override
	bool get isOnline => _online;

	@override
	Future<void> startPuzzleAssets(List<String> assetPaths) async {
		final bool firstTime = !_started;
		_started = true;
		if (firstTime) {
			_online = web.window.navigator.onLine;
			// 監聽 online / offline：online 重啟 worker、offline 讓 worker 自然停。
			web.window.addEventListener("online", ((web.Event _) {
				_online = true;
				unawaited(_kickWorker());
				notifyListeners();
			}).toJS);
			web.window.addEventListener("offline", ((web.Event _) {
				_online = false;
				notifyListeners();
			}).toJS);
		}

		// 掃 SW cache：已下載過的不再 enqueue
		await _rescanPuzzleCache(assetPaths);
		// 隨機順序下載 — 避免每次 app 啟動都先 drain 圖庫前段的圖；玩家比較
		// 不會出現「總是同一批先 cache」的偏差。
		final List<String> pending = <String>[
			for (final String p in assetPaths)
				if (!_puzzleCached.contains(p) && !_puzzleQueue.contains(p)) p,
		]..shuffle(_shuffleRandom);
		_puzzleQueue.addAll(pending);
		notifyListeners();
		unawaited(_kickWorker());
	}

	@override
	void setSpriteAssets({
		required Map<String, SpriteAssetGroup> assets,
		required List<String> orderedCategoryIds,
	}) {
		// 整份覆寫類別 → URL 對應；同步把 queue 內舊 URL（已經被新 rev 取代）
		// 清掉，避免下載過時資源。
		_spriteAssets
			..clear()
			..addAll(assets);

		// 先 rescan cache：用實際 URL 對 sprite-cache 比對，已 cache 的記下來。
		_rescanSpriteCache().then((_) {
			_rebuildSpriteQueue(orderedCategoryIds);
			notifyListeners();
			unawaited(_kickWorker());
		});
	}

	void _rebuildSpriteQueue(List<String> orderedCategoryIds) {
		_spriteQueue.clear();
		// 已選類別段、未選類別段各自獨立隨機 — 已選的仍會排在前段（呼應
		// setSpriteAssets 的優先順序語意）、但兩段內部都打散，避免每次都按
		// manifest 順序下載。
		final Set<String> orderedSet = orderedCategoryIds.toSet();
		final List<String> selected = <String>[...orderedCategoryIds]
			..shuffle(_shuffleRandom);
		final List<String> rest = <String>[
			for (final String id in _spriteAssets.keys)
				if (!orderedSet.contains(id)) id,
		]..shuffle(_shuffleRandom);
		for (final String catId in <String>[...selected, ...rest]) {
			final SpriteAssetGroup? g = _spriteAssets[catId];
			if (g == null) continue;
			if (!_spriteCachedUrls.contains(g.sheetUrl)) _spriteQueue.add(g.sheetUrl);
			if (!_spriteCachedUrls.contains(g.voiceUrl)) _spriteQueue.add(g.voiceUrl);
		}
	}

	@override
	void setPriority(DownloadPriority priority) {
		if (_priority == priority) return;
		_priority = priority;
		// priority 變動可能讓暫停（worker 已退出迴圈）的下載重新啟動。
		unawaited(_kickWorker());
	}

	/// Worker：一張一張 fetch、依 priority 決定取哪條 queue。
	Future<void> _kickWorker() async {
		if (_workerRunning) return;
		if (!_online) return;
		_workerRunning = true;
		try {
			while (_online) {
				final _Task? task = _pickNextTask();
				if (task == null) break;
				// Puzzle token = pubspec asset 原值（已含 `assets/` 前綴）；Flutter
				// web 對所有 asset 額外加一層 `assets/`，所以實際 URL 是雙層。
				// Sprite URL 是 setSpriteAssets 端組裝好的完整 URL（也是雙層、
				// 含 ?rev=...），直接用。
				final String fullUrl = task.kind == _TaskKind.puzzle
						? _puzzleUrl(task.url)
						: task.url;
				final bool ok = await _fetchAndCheck(fullUrl);
				if (ok) {
					if (task.kind == _TaskKind.puzzle) {
						_puzzleCached.add(task.url);
					} else {
						_spriteCachedUrls.add(task.url);
					}
					notifyListeners();
				} else {
					// 失敗丟回對應 queue 末端；避免壞檔卡住整條
					if (task.kind == _TaskKind.puzzle) {
						_puzzleQueue.add(task.url);
					} else {
						_spriteQueue.add(task.url);
					}
					break;
				}
				// 避免一口氣塞滿瀏覽器 fetch queue / 跟 Flutter 載入搶頻寬
				await Future<void>.delayed(const Duration(milliseconds: 200));
			}
		} finally {
			_workerRunning = false;
		}
	}

	_Task? _pickNextTask() {
		final bool puzzleEmpty = _puzzleQueue.isEmpty;
		final bool spriteEmpty = _spriteQueue.isEmpty;
		if (puzzleEmpty && spriteEmpty) return null;
		_TaskKind kind;
		switch (_priority) {
			case DownloadPriority.puzzle:
				kind = puzzleEmpty ? _TaskKind.sprite : _TaskKind.puzzle;
				break;
			case DownloadPriority.sprite:
				kind = spriteEmpty ? _TaskKind.puzzle : _TaskKind.sprite;
				break;
			case DownloadPriority.none:
				// 取剩餘較多的那條，避免單側餓死；同數量時偏 puzzle（任意決定）。
				if (puzzleEmpty) {
					kind = _TaskKind.sprite;
				} else if (spriteEmpty) {
					kind = _TaskKind.puzzle;
				} else {
					kind = _puzzleQueue.length >= _spriteQueue.length
							? _TaskKind.puzzle
							: _TaskKind.sprite;
				}
				break;
		}
		final String url = kind == _TaskKind.puzzle
				? _puzzleQueue.removeAt(0)
				: _spriteQueue.removeAt(0);
		return _Task(kind: kind, url: url);
	}

	Future<bool> _fetchAndCheck(String fullUrl) async {
		try {
			final web.Response res =
					await web.window.fetch(fullUrl.toJS).toDart;
			if (!res.ok) return false;
			// 讀完 body 才算下載完成（讓 SW 把 body 寫進 cache）
			await res.arrayBuffer().toDart;
			return true;
		} catch (_) {
			return false;
		}
	}

	/// puzzle asset path → 實際 URL。Flutter web 把所有 asset 多包一層
	/// `assets/`，所以最終 URL 是 `assets/<token>`、token 本身又以 `assets/`
	/// 開頭、結果是雙層 `assets/assets/...`。Sprite URL 已由
	/// [setSpriteAssets] 預先組好雙層、不再經過這層。
	String _puzzleUrl(String assetPath) => "assets/$assetPath";

	Future<void> _rescanPuzzleCache(List<String> assetPaths) async {
		try {
			final web.Cache cache =
					await web.window.caches.open(_kRuntimeCacheName).toDart;
			for (final String p in assetPaths) {
				final web.Response? r =
						await cache.match(_puzzleUrl(p).toJS).toDart;
				if (r != null) _puzzleCached.add(p);
			}
		} catch (_) {
			// cache 不存在 / 權限失敗：全當未 cache
		}
	}

	Future<void> _rescanSpriteCache() async {
		_spriteCachedUrls.clear();
		try {
			final web.Cache cache =
					await web.window.caches.open(_kSpriteCacheName).toDart;
			for (final SpriteAssetGroup g in _spriteAssets.values) {
				final web.Response? sheetRes =
						await cache.match(g.sheetUrl.toJS).toDart;
				if (sheetRes != null) _spriteCachedUrls.add(g.sheetUrl);
				final web.Response? voiceRes =
						await cache.match(g.voiceUrl.toJS).toDart;
				if (voiceRes != null) _spriteCachedUrls.add(g.voiceUrl);
			}
		} catch (_) {}
	}
}

enum _TaskKind { puzzle, sprite }

class _Task {
	const _Task({required this.kind, required this.url});
	final _TaskKind kind;
	final String url;
}
