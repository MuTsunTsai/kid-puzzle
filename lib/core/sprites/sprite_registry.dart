import "dart:convert";
import "dart:ui" as ui;

import "package:flutter/foundation.dart";

import "sprite_asset_loader.dart";
import "sprite_atlas.dart";
import "sprite_manifest.dart";
import "sprite_voice_player.dart";

/// Sprite 圖庫的對外統一入口。
///
/// 啟動時呼叫 [load] 一次讀進 `assets/data/sprites.json` 並建立索引；
/// 之後遊戲端透過 [categoryById] / [itemById] 取 metadata，再用
/// [imageOf] 取對應 sheet 的 ui.Image 與 [srcRectOf] 算出 sprite 的
/// `Rect`，餵給 `canvas.drawImageRect`。
///
/// 物件名稱語音透過 [playName] 播放（讀類別共用 mp3 + 切片）。
class SpriteRegistry {
	SpriteRegistry();

	SpriteManifest? _manifest;
	final Map<String, SpriteCategory> _categoryById = <String, SpriteCategory>{};
	final Map<String, _ItemRef> _itemById = <String, _ItemRef>{};

	final SpriteAtlas _atlas = SpriteAtlas();
	final SpriteVoicePlayer _voice = SpriteVoicePlayer();

	/// 對外公開 atlas 以便 painter 直接拿 cached ui.Image 畫圖。
	SpriteAtlas get atlas => _atlas;

	bool get isLoaded => _manifest != null;

	List<SpriteCategory> get categories => _manifest?.categories ?? const <SpriteCategory>[];

	/// 讀取並解析 `assets/data/sprites.json`，建立 id → category / item 索引。
	///
	/// Web 流程：先讀 `sprites_revision.json`（不帶 rev、由 SW network-first）
	/// 拿到 sprites.json 的 rev → 用該 rev 載 sprites.json，確保 SW 不會回
	/// stale 版本。kid-puzzle-sprite build 期會更新這份 revision 檔。
	///
	/// 非 web：直接走 rootBundle、`rev` 參數忽略。
	Future<void> load() async {
		final String? manifestRev = await _loadManifestRev();
		final String text =
				await loadSpriteString("data/sprites.json", rev: manifestRev);
		final Map<String, dynamic> json = jsonDecode(text) as Map<String, dynamic>;
		final SpriteManifest manifest = SpriteManifest.fromJson(json);
		_manifest = manifest;
		_categoryById.clear();
		_itemById.clear();
		for (final SpriteCategory c in manifest.categories) {
			_categoryById[c.id] = c;
			for (final SpriteItem item in c.items) {
				_itemById[item.id] = _ItemRef(category: c, item: item);
			}
		}
	}

	/// 讀 `sprites_revision.json` 拿 manifest 的 rev。
	/// - Web：必經這條才能讓 SW 拿到「manifest 自己」要不要重新 fetch 的決策；
	///   找不到檔或解析失敗時退回 null（行為等同舊版、不帶 rev）。
	/// - 非 web：直接回 null（rootBundle 不需要這層）。
	Future<String?> _loadManifestRev() async {
		if (!kIsWeb) return null;
		try {
			final String text = await loadSpriteString("data/sprites_revision.json");
			final Map<String, dynamic> json =
					jsonDecode(text) as Map<String, dynamic>;
			final Object? rev = json["rev"];
			return rev is String && rev.isNotEmpty ? rev : null;
		} catch (_) {
			return null;
		}
	}

	SpriteCategory? categoryById(String id) => _categoryById[id];

	SpriteItem? itemById(String id) => _itemById[id]?.item;

	SpriteCategory? categoryOfItem(String itemId) => _itemById[itemId]?.category;

	/// 取得指定類別內某子類別的設定。類別沒有子類別 (`subcategories == null`)
	/// 或找不到對應 id 都回 null。
	SpriteSubcategory? subcategoryById(String categoryId, String subId) {
		final SpriteCategory? c = _categoryById[categoryId];
		if (c == null) return null;
		for (final SpriteSubcategory s in c.subcategories ?? const <SpriteSubcategory>[]) {
			if (s.id == subId) return s;
		}
		return null;
	}

	/// 取得子類別涵蓋的所有 [SpriteItem]（依 [SpriteSubcategory.itemIds] 順序、
	/// 找不到的 id 會被略過）。
	List<SpriteItem> itemsOfSubcategory(SpriteSubcategory sub) {
		final List<SpriteItem> result = <SpriteItem>[];
		for (final String id in sub.itemIds) {
			final SpriteItem? item = _itemById[id]?.item;
			if (item != null) result.add(item);
		}
		return result;
	}

	/// 取得某物件所屬 sheet 的 ui.Image（lazy 解碼 + cache）。
	Future<ui.Image> imageOf(SpriteItem item) {
		final SpriteCategory? category = categoryOfItem(item.id);
		if (category == null) {
			throw StateError("Unknown sprite item: ${item.id}");
		}
		return _atlas.load(category.sheet);
	}

	/// 計算某物件在所屬 sheet 圖片中的像素矩形（給 `canvas.drawImageRect` 用）。
	ui.Rect srcRectOf(SpriteItem item) {
		final SpriteCategory? category = categoryOfItem(item.id);
		if (category == null) {
			throw StateError("Unknown sprite item: ${item.id}");
		}
		final ({int sheet, int row, int col})? g = category.gridOf(item);
		if (g == null) {
			throw StateError("Item not in category items: ${item.id}");
		}
		final double tile = category.sheet.tile.toDouble();
		return ui.Rect.fromLTWH(g.col * tile, g.row * tile, tile, tile);
	}

	/// 預載某類別的所有 sheet ui.Image 與語音 mp3（進入遊戲前呼叫）。
	Future<void> preloadCategory(SpriteCategory category) async {
		await Future.wait(<Future<void>>[
			_atlas.preload(category),
			_voice.preload(category),
		]);
	}

	/// 額外把某類別 sheet 的 RGBA byte buffer 也展開、塞進 cache。
	/// 給「需要 per-pixel alpha 查詢」的場景使用（例如關閉按鈕的隱藏判定）。
	Future<void> preloadCategoryPixels(SpriteCategory category) async {
		await _atlas.loadPixels(category.sheet);
	}

	/// 查詢某物件在其 sheet local 座標 (lx, ly) 的 alpha（0~255）。lx/ly 為
	/// 「該物件 tile 內」的像素座標（0 ~ tile-1）。
	int alphaInItemLocal(SpriteItem item, int lx, int ly) {
		final SpriteCategory? c = categoryOfItem(item.id);
		if (c == null) return 0;
		final ({int sheet, int row, int col})? g = c.gridOf(item);
		if (g == null) return 0;
		final SpriteSheet sheet = c.sheet;
		final ui.Image? img = _atlas.cachedImage(sheet.file);
		if (img == null) return 0;
		final int sx = g.col * sheet.tile + lx;
		final int sy = g.row * sheet.tile + ly;
		return _atlas.pixelAlphaAt(sheet, sx, sy, img.width);
	}

	/// 取得某物件的「實際 alpha 不透明區」相對 tile 左上的 bounding box
	/// （tile 像素座標）。第一次呼叫會 cache 結果。
	ui.Rect? alphaBoundsOf(SpriteItem item) {
		final ui.Rect? cached = _alphaBoundsCache[item.id];
		if (cached != null) return cached;
		final SpriteCategory? c = categoryOfItem(item.id);
		if (c == null) return null;
		final ({int sheet, int row, int col})? g = c.gridOf(item);
		if (g == null) return null;
		final SpriteSheet sheet = c.sheet;
		final int sx = g.col * sheet.tile;
		final int sy = g.row * sheet.tile;
		final ui.Rect? rect = _atlas.computeAlphaBounds(sheet, sx, sy, sheet.tile);
		if (rect != null) _alphaBoundsCache[item.id] = rect;
		return rect;
	}

	final Map<String, ui.Rect> _alphaBoundsCache = <String, ui.Rect>{};

	/// 「輪廓 mask」：把 item 的 alpha bounds resample 成固定 [_silhouetteRes]
	/// × [_silhouetteRes] 的 binary（alpha > threshold = 1）。給
	/// [silhouetteOverlapRatio] 用。
	final Map<String, Uint8List> _silhouetteCache = <String, Uint8List>{};

	/// Silhouette mask 解析度。比 dilated mask 大（32 → 64）以便相似度判定
	/// 有足夠細節；但仍遠小於原 tile（340），cross-pair compare 仍夠快。
	static const int _silhouetteRes = 64;

	/// 取得 [item] 的 silhouette mask（[_silhouetteRes] × [_silhouetteRes]、
	/// row-major、0/1）。
	///
	/// 處理流程：
	/// 1. 從 [alphaBoundsOf] 取 AABB（裁掉透明邊界）
	/// 2. 等比縮放：scale = `_silhouetteRes / max(bw, bh)`、保留長寬比
	/// 3. **置中**放入 [_silhouetteRes] × [_silhouetteRes] grid（不拉伸、
	///    比例不同的物件 mask 在 grid 內就佔不同形狀的區域）
	///
	/// **不**做 AABB 等比拉伸（之前版本錯誤行為）—— 那會讓「冷氣機 vs 手機」
	/// 這種「兩個都是矩形但比例不同」誤判 ratio 接近 1。
	///
	/// 需先 [preloadCategoryPixels]。回 null 時表示 alpha bounds 拿不到
	/// （pixels 未載入或物件完全透明）。
	Uint8List? silhouetteMaskOf(SpriteItem item, {int threshold = 32}) {
		final Uint8List? cached = _silhouetteCache[item.id];
		if (cached != null) return cached;
		final SpriteCategory? c = categoryOfItem(item.id);
		if (c == null) return null;
		final ({int sheet, int row, int col})? g = c.gridOf(item);
		if (g == null) return null;
		final ui.Rect? bounds = alphaBoundsOf(item);
		if (bounds == null) return null;
		final SpriteSheet sheet = c.sheet;
		final ui.Image? img = _atlas.cachedImage(sheet.file);
		if (img == null) return null;
		final int sheetW = img.width;
		final int sx0 = g.col * sheet.tile + bounds.left.toInt();
		final int sy0 = g.row * sheet.tile + bounds.top.toInt();
		final int bw = bounds.width.toInt();
		final int bh = bounds.height.toInt();
		final int res = _silhouetteRes;

		// 等比縮放、保留長寬比；mask 在 grid 內的實際填充區域可能小於 res×res
		final int longSide = bw > bh ? bw : bh;
		final int tw = bw == longSide
				? res
				: (bw * res / longSide).round().clamp(1, res);
		final int th = bh == longSide
				? res
				: (bh * res / longSide).round().clamp(1, res);
		final int offsetX = (res - tw) ~/ 2;
		final int offsetY = (res - th) ~/ 2;

		final Uint8List mask = Uint8List(res * res);
		for (int ty = 0; ty < th; ty++) {
			final int y0 = sy0 + (ty * bh ~/ th);
			final int y1 = sy0 + ((ty + 1) * bh ~/ th);
			for (int tx = 0; tx < tw; tx++) {
				final int x0 = sx0 + (tx * bw ~/ tw);
				final int x1 = sx0 + ((tx + 1) * bw ~/ tw);
				int hit = 0;
				outer:
				for (int py = y0; py < y1; py++) {
					for (int px = x0; px < x1; px++) {
						if (_atlas.pixelAlphaAt(sheet, px, py, sheetW) > threshold) {
							hit = 1;
							break outer;
						}
					}
				}
				if (hit != 0) {
					mask[(offsetY + ty) * res + (offsetX + tx)] = 1;
				}
			}
		}
		_silhouetteCache[item.id] = mask;
		return mask;
	}

	/// 算兩個 item 的 silhouette 重疊比例：
	/// `intersection(maskA, maskB) / max(|maskA|, |maskB|)`，回傳 0~1。
	/// 兩個 mask 都是 [_silhouetteRes] × [_silhouetteRes]、各自等比縮放後**置中**
	/// 對齊（**不**拉伸到等大）— 比例不同的物件 ratio 不會被誤判逼近 1。
	///
	/// 用 max 而非 min 為分母：只有兩物件**大小相當且形狀高度相似**時 ratio
	/// 才會逼近 1。一個大物件覆蓋一個小物件雖然 intersection 對小者來說
	/// 是 100%、但對大者只是一小部分 → ratio 仍低、不誤殺純粹的大小差異。
	///
	/// 任一 mask 拿不到時回 0（不阻止抽樣）。
	double silhouetteOverlapRatio(SpriteItem a, SpriteItem b) {
		final Uint8List? ma = silhouetteMaskOf(a);
		final Uint8List? mb = silhouetteMaskOf(b);
		if (ma == null || mb == null) return 0;
		int countA = 0, countB = 0, inter = 0;
		for (int i = 0; i < ma.length; i++) {
			if (ma[i] != 0) countA++;
			if (mb[i] != 0) countB++;
			if (ma[i] != 0 && mb[i] != 0) inter++;
		}
		final int maxCount = countA > countB ? countA : countB;
		if (maxCount == 0) return 0;
		return inter / maxCount;
	}

	/// 預烤的「dilated alpha mask」cache。key = "itemId|dilateRatio|threshold"，
	/// value = [DilatedMask]。給布局物理模擬熱迴圈用 — 一次配置 + 一次掃描、
	/// 執行期單點查 = 一次陣列存取，比每 frame 9 次 alphaInItemLocal 快數十倍。
	final Map<String, DilatedMask> _maskCache = <String, DilatedMask>{};

	/// 解析度上限：mask 邊長最多這麼多 pixel。原圖 340×340 → mask 32×32，
	/// 110000+ 像素的掃描變成 ~1000 像素、足以給物理模擬當壓力指標。
	static const int _maskResolution = 32;

	/// 取得 [item] 對應的低解析度「dilated alpha mask」。
	///
	/// 流程：
	/// 1. Down-sample：把 tile（340×340）切成 [_maskResolution] × [_maskResolution]
	///    格；每格對應原圖一個 region，任一像素 alpha > [threshold] 視為 1。
	/// 2. Dilate：對 down-sampled 結果做 9 點 dilation，半徑 =
	///    round(_maskResolution × [dilateRatio])。
	/// 3. Cache：以 (itemId, dilateRatio, threshold) 為 key。
	///
	/// [dilateRatio] 占 tile 的比例（與物理模擬同單位）。第一次呼叫前需先
	/// [preloadCategoryPixels]（要求 atlas 已有像素 buffer）。
	DilatedMask? dilatedMaskOf(SpriteItem item, double dilateRatio,
			{int threshold = 32}) {
		final String key = "${item.id}|${dilateRatio.toStringAsFixed(3)}|$threshold";
		final DilatedMask? cached = _maskCache[key];
		if (cached != null) return cached;
		final SpriteCategory? c = categoryOfItem(item.id);
		if (c == null) return null;
		final ({int sheet, int row, int col})? g = c.gridOf(item);
		if (g == null) return null;
		final SpriteSheet sheet = c.sheet;
		final int tile = sheet.tile;
		final ui.Image? img = _atlas.cachedImage(sheet.file);
		if (img == null) return null;
		final int sheetW = img.width;
		final int sx = g.col * tile;
		final int sy = g.row * tile;
		final int res = _maskResolution;

		// Step 1: down-sample 到 res×res，每格內任一 alpha > threshold → 1
		final Uint8List ds = Uint8List(res * res);
		for (int my = 0; my < res; my++) {
			final int y0 = sy + (my * tile ~/ res);
			final int y1 = sy + ((my + 1) * tile ~/ res);
			for (int mx = 0; mx < res; mx++) {
				final int x0 = sx + (mx * tile ~/ res);
				final int x1 = sx + ((mx + 1) * tile ~/ res);
				int hit = 0;
				outer:
				for (int py = y0; py < y1; py++) {
					for (int px = x0; px < x1; px++) {
						if (_atlas.pixelAlphaAt(sheet, px, py, sheetW) > threshold) {
							hit = 1;
							break outer;
						}
					}
				}
				ds[my * res + mx] = hit;
			}
		}

		// Step 2: 9 點 dilation
		final int dilatePx = (res * dilateRatio).round();
		final Uint8List mask;
		if (dilatePx <= 0) {
			mask = ds;
		} else {
			mask = Uint8List(res * res);
			final List<int> dxList = <int>[0, dilatePx, -dilatePx, 0, 0, dilatePx, -dilatePx, dilatePx, -dilatePx];
			final List<int> dyList = <int>[0, 0, 0, dilatePx, -dilatePx, dilatePx, dilatePx, -dilatePx, -dilatePx];
			for (int my = 0; my < res; my++) {
				for (int mx = 0; mx < res; mx++) {
					int hit = 0;
					for (int k = 0; k < 9; k++) {
						final int qx = mx + dxList[k];
						final int qy = my + dyList[k];
						if (qx < 0 || qy < 0 || qx >= res || qy >= res) continue;
						if (ds[qy * res + qx] != 0) { hit = 1; break; }
					}
					mask[my * res + mx] = hit;
				}
			}
		}

		final DilatedMask result = DilatedMask(data: mask, resolution: res);
		_maskCache[key] = result;
		return result;
	}

	/// 此物件是否已配置可播放的名稱語音（語音 zip 內有對應 entry）。
	/// 沒有的話呼叫端應該 fallback 到其他音效（例如 snap.mp3）。
	/// 需要先 [preloadCategory] 過、否則一律回 false。
	bool hasNameVoice(SpriteItem item) {
		final SpriteCategory? c = categoryOfItem(item.id);
		if (c == null) return false;
		return _voice.hasClip(c.id, item.id);
	}

	/// 播放物件名稱語音。
	Future<void> playName(SpriteItem item) async {
		final SpriteCategory? category = categoryOfItem(item.id);
		if (category == null) return;
		await _voice.play(category, item);
	}

	bool get voiceEnabled => _voice.enabled;
	set voiceEnabled(bool v) => _voice.enabled = v;

	Future<void> dispose() async {
		_atlas.clear();
		await _voice.dispose();
	}
}

class _ItemRef {
	const _ItemRef({required this.category, required this.item});
	final SpriteCategory category;
	final SpriteItem item;
}

/// 預烤的低解析度 dilated alpha mask。
///
/// [data] 是 `Uint8List`，長度 = [resolution] × [resolution]，row-major、
/// 值 0 = 透明、1 = 不透明（含 dilation 後）。
/// 查詢方式：`data[my * resolution + mx]`，其中 (mx, my) 是 [resolution] domain
/// 內的整數座標。
class DilatedMask {
	const DilatedMask({required this.data, required this.resolution});
	final Uint8List data;
	final int resolution;
}
