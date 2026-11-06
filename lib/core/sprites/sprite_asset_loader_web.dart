import "dart:js_interop";
import "dart:typed_data";

import "package:web/web.dart" as web;

/// Web 平台實作：走 `window.fetch` 抓 `assets/assets/<path>?rev=<rev>`，方便
/// Service Worker 攔截做 reconcile（同 path 不同 rev 視為新版本、舊版
/// cache entry 在新版下載完後刪除）。
///
/// 雙層 `assets/` 不是錯：Flutter web 把所有 pubspec asset 放在
/// `build/web/assets/<原 pubspec 路徑>` 下，pubspec 路徑本身又以 `assets/`
/// 開頭、所以最終是 `assets/assets/...`。與 `rootBundle` 的內部 fetch 行為
/// 一致。
///
/// rev 為 null 時不加 query — 給 `sprites_revision.json` 這種「網路優先、
/// 自帶版本資訊」的小檔用。
Future<Uint8List> fetchSpriteBytes(String assetPath, {String? rev}) async {
	final String url = rev == null || rev.isEmpty
			? "assets/assets/$assetPath"
			: "assets/assets/$assetPath?rev=$rev";
	final web.Response response =
			await web.window.fetch(url.toJS).toDart;
	if (!response.ok) {
		throw StateError("fetch sprite asset failed: $url (${response.status})");
	}
	final JSArrayBuffer buf = await response.arrayBuffer().toDart;
	return buf.toDart.asUint8List();
}

/// 用瀏覽器 2D canvas 把編碼過的圖片（webp / png）解成 RGBA pixel buffer
/// （straight alpha、長度 = w × h × 4）。
///
/// 為什麼不用 `ui.Image.toByteData`：手機瀏覽器上的 wasm（skwasm）版本，
/// GPU 讀回大張 sprite sheet 會得到全 0 或不完整的資料（實測 Android Chrome、
/// 2040×6120 sheet 整格物件讀回 alpha 全 0），導致嵌入拼圖的物理布局以為
/// 物件是透明的、凹槽大量重疊。2D canvas 的 `getImageData` 搭配
/// `willReadFrequently` 走 CPU 端軟體 canvas，各瀏覽器都可靠。
///
/// 失敗（解碼失敗、canvas 取不到 context 等）回 null，呼叫端退回 toByteData。
Future<({ByteData data, int width, int height})?> decodeRgbaPixels(
		Uint8List encoded) async {
	web.ImageBitmap? bitmap;
	web.HTMLCanvasElement? canvas;
	try {
		final web.Blob blob = web.Blob(<JSAny>[encoded.toJS].toJS);
		bitmap = await web.window.createImageBitmap(blob).toDart;
		final int w = bitmap.width;
		final int h = bitmap.height;
		canvas = web.document.createElement("canvas") as web.HTMLCanvasElement;
		canvas.width = w;
		canvas.height = h;
		final JSObject? ctxObj = canvas.getContext(
			"2d",
			<String, Object>{"willReadFrequently": true}.jsify(),
		);
		if (ctxObj == null) return null;
		final web.CanvasRenderingContext2D ctx =
				ctxObj as web.CanvasRenderingContext2D;
		ctx.drawImage(bitmap, 0, 0);
		final Uint8ClampedList pixels = ctx.getImageData(0, 0, w, h).data.toDart;
		// 複製一份：canvas 釋放後原 buffer 不保證有效。
		final ByteData data = ByteData(pixels.lengthInBytes);
		data.buffer.asUint8List().setAll(0, pixels);
		return (data: data, width: w, height: h);
	} catch (_) {
		return null;
	} finally {
		bitmap?.close();
		if (canvas != null) {
			// 釋放 canvas 的 backing store（大張 sheet 約 50 MB）。
			canvas.width = 0;
			canvas.height = 0;
		}
	}
}
