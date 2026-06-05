import "dart:ui" as ui;

import "package:flutter/services.dart";

import "../../../core/storage/gallery_repository.dart";

/// 載入完成的圖片 + 原始尺寸；給 [PuzzlePage] 與過渡期 board 共用。
class LoadedImage {
	const LoadedImage(this.image, this.size);
	final ui.Image image;
	final ui.Size size;
}

/// 載入一張圖（assets 路徑或 `imageId:<uuid>` token 都支援），解成 ui.Image。
///
/// - 以 `assets/` 開頭 → 走 rootBundle
/// - 以 `imageId:` 開頭 → 走 [GalleryRepository.readImageBytes]
Future<LoadedImage> loadAssetImage(
	String token,
	GalleryRepository gallery,
) async {
	final Uint8List bytes;
	if (token.startsWith("imageId:")) {
		final String id = token.substring("imageId:".length);
		final Uint8List? data = gallery.readImageBytes(id);
		if (data == null) {
			throw StateError("找不到圖片 bytes：$id");
		}
		bytes = data;
	} else {
		bytes = (await rootBundle.load(token)).buffer.asUint8List();
	}
	final ui.Codec codec = await ui.instantiateImageCodec(bytes);
	final ui.FrameInfo frame = await codec.getNextFrame();
	final ui.Image image = frame.image;
	return LoadedImage(
		image,
		ui.Size(image.width.toDouble(), image.height.toDouble()),
	);
}
