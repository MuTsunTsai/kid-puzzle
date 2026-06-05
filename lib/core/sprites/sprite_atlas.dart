import "dart:ui" as ui;

import "package:flutter/services.dart";

import "sprite_asset_loader.dart";
import "sprite_manifest.dart";

/// Sprite sheet 圖片的 lazy loader + cache。
///
/// 一張 2040×2040 webp 解碼後是 ~17 MB ui.Image（4 bytes × 4M pixels）；
/// 10 張全留約 170 MB，太大。所以採 lazy load：第一次有遊戲要某類別才
/// 把該類所有 sheet 解碼成 ui.Image、放進 [_cache]。
///
/// 目前不主動釋放（[evict] 留給未來判定需要時呼叫）。
class SpriteAtlas {
	SpriteAtlas();

	final Map<String, ui.Image> _cache = <String, ui.Image>{};
	final Map<String, Future<ui.Image>> _inflight = <String, Future<ui.Image>>{};

	/// 每張 sheet 的 RGBA byte buffer（rawStraightRgba 排列、長度 = w*h*4）。
	/// 由 [loadPixels] 按需生成、與 [_cache] 一起在 [evict] / [clear] 釋放。
	///
	/// 用途：對「stage 上某點是否落在物件的非透明像素」的精確判定（例如關閉
	/// 按鈕的隱藏邏輯，要看物件實際輪廓而不是矩形 bounds）。
	final Map<String, ByteData> _pixelCache = <String, ByteData>{};

	/// 取得單一 sheet 的 ui.Image；同一 file 重複呼叫共用 cache。
	Future<ui.Image> load(SpriteSheet sheet) {
		final String key = sheet.file;
		final ui.Image? cached = _cache[key];
		if (cached != null) return Future<ui.Image>.value(cached);
		final Future<ui.Image>? inflight = _inflight[key];
		if (inflight != null) return inflight;
		final Future<ui.Image> future = _decode(sheet).whenComplete(() {
			_inflight.remove(key);
		});
		_inflight[key] = future;
		return future;
	}

	/// 預載入一個類別的 sprite sheet（進入遊戲前呼叫）。
	Future<void> preload(SpriteCategory category) async {
		await load(category.sheet);
	}

	/// 取得已 cache 的 ui.Image（沒 cache 回 null，呼叫端應已先 await [load]）。
	ui.Image? cachedImage(String file) => _cache[file];

	/// 取得 sheet 的 RGBA byte buffer。第一次呼叫會做 [toByteData] 解碼
	/// （比 instantiateImageCodec 更花時間，因此延後到真的有人要查像素時才做）。
	Future<ByteData> loadPixels(SpriteSheet sheet) async {
		final ByteData? cached = _pixelCache[sheet.file];
		if (cached != null) return cached;
		final ui.Image image = await load(sheet);
		final ByteData? data =
				await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
		if (data == null) {
			throw StateError("toByteData returned null: ${sheet.file}");
		}
		_pixelCache[sheet.file] = data;
		return data;
	}

	/// 計算 sheet 內某 tile（左上 (sx, sy)、寬高 [tile]）的「alpha > [threshold]」
	/// bounding box，回傳結果是「相對 tile 左上」的座標（0 ~ tile-1）。
	/// 若整個 tile 都低於門檻則回 null。
	/// 呼叫前需先 [loadPixels]。
	ui.Rect? computeAlphaBounds(SpriteSheet sheet, int sx, int sy, int tile,
			{int threshold = 16}) {
		final ByteData? data = _pixelCache[sheet.file];
		if (data == null) return null;
		final ui.Image? img = _cache[sheet.file];
		if (img == null) return null;
		final int imgW = img.width;
		int minX = tile, minY = tile, maxX = -1, maxY = -1;
		for (int ly = 0; ly < tile; ly++) {
			final int rowOffset = ((sy + ly) * imgW + sx) * 4;
			for (int lx = 0; lx < tile; lx++) {
				final int aOffset = rowOffset + lx * 4 + 3;
				if (aOffset >= data.lengthInBytes) continue;
				final int a = data.getUint8(aOffset);
				if (a > threshold) {
					if (lx < minX) minX = lx;
					if (ly < minY) minY = ly;
					if (lx > maxX) maxX = lx;
					if (ly > maxY) maxY = ly;
				}
			}
		}
		if (maxX < 0) return null;
		return ui.Rect.fromLTRB(
			minX.toDouble(),
			minY.toDouble(),
			(maxX + 1).toDouble(),
			(maxY + 1).toDouble(),
		);
	}

	/// 查詢 sheet 內 (x, y) 像素的 alpha（0~255）。座標必須在 sheet image 尺寸
	/// 內；超出範圍回 0。會在第一次呼叫時 lazy 觸發 [loadPixels]，所以呼叫端
	/// 應先 await [loadPixels] 一次再進入 hit-test 熱迴圈。
	int pixelAlphaAt(SpriteSheet sheet, int x, int y, int sheetPixelWidth) {
		final ByteData? data = _pixelCache[sheet.file];
		if (data == null) return 0;
		if (x < 0 || y < 0) return 0;
		final int offset = (y * sheetPixelWidth + x) * 4 + 3; // RGBA → A
		if (offset < 0 || offset >= data.lengthInBytes) return 0;
		return data.getUint8(offset);
	}

	/// 釋放單張 sheet 的 ui.Image 與其 pixel cache。
	void evict(String file) {
		_cache.remove(file)?.dispose();
		_pixelCache.remove(file);
	}

	/// 釋放全部 cache（例如退出遊戲）。
	void clear() {
		for (final ui.Image img in _cache.values) {
			img.dispose();
		}
		_cache.clear();
		_pixelCache.clear();
	}

	Future<ui.Image> _decode(SpriteSheet sheet) async {
		final Uint8List bytes =
				await loadSpriteBytes(sheet.file, rev: sheet.rev);
		final ui.Codec codec = await ui.instantiateImageCodec(bytes);
		final ui.FrameInfo frame = await codec.getNextFrame();
		_cache[sheet.file] = frame.image;
		return frame.image;
	}
}
