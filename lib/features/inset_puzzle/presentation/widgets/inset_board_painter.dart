import "dart:ui" as ui;

import "package:flutter/material.dart";

import "../../../../core/sprites/sprite_manifest.dart";
import "../../domain/inset_piece.dart";
import "../inset_puzzle_controller.dart";

/// 嵌入拼圖底板的「靜態」繪製 — 馬卡龍底色、外圍立體光影、每片凹槽。
///
/// 凹槽繪製手法：對 sprite alpha mask
/// 1. 染成「比底色稍深一點」當凹槽底色（凹陷感）
/// 2. 往 (+1, +1) 偏移畫一次「亮色」、往 (-1, -1) 偏移畫一次「暗色」當 inner shadow
/// 3. 中間再畫一次「白色」當凹槽主體
///
/// 整個底板會被 [InsetBoardCache] 烤成 bitmap，畫面只 drawImage 一次。
class InsetBoardPainter extends CustomPainter {
	InsetBoardPainter({
		required this.controller,
		required this.cache,
	}) : super(repaint: cache);

	final InsetPuzzleController controller;
	final InsetBoardCache cache;

	@override
	void paint(Canvas canvas, Size size) {
		// 1. 全螢幕底色
		canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFFFFFFF));

		// 2. 用 cache 提供的 bitmap（含 board + 全部凹槽）
		final ui.Image? bm = cache.image;
		if (bm == null) return;
		canvas.drawImageRect(
			bm,
			ui.Rect.fromLTWH(0, 0, bm.width.toDouble(), bm.height.toDouble()),
			ui.Rect.fromLTWH(0, 0, size.width, size.height),
			Paint()..filterQuality = FilterQuality.low,
		);
	}

	@override
	bool shouldRepaint(covariant InsetBoardPainter oldDelegate) =>
			oldDelegate.cache != cache;
}

/// 底板 bitmap 快取。controller 改變（rescale / 換關）時呼叫 [rebuild]。
class InsetBoardCache extends ChangeNotifier {
	ui.Image? _image;
	ui.Image? get image => _image;

	/// 重建 bitmap。[totalSize] 是整個 canvas 尺寸（logical pixels）。
	/// 內部會放大 [devicePixelRatio] 倍輸出 bitmap，painter 端用 drawImageRect
	/// 縮回 logical 尺寸時不會糊。
	Future<void> rebuild({
		required InsetPuzzleController controller,
		required Size totalSize,
		required double devicePixelRatio,
	}) async {
		final ui.PictureRecorder recorder = ui.PictureRecorder();
		final Canvas canvas = Canvas(recorder);
		canvas.scale(devicePixelRatio);
		_drawBoardAndSlots(canvas, totalSize, controller);
		final ui.Picture picture = recorder.endRecording();
		final int w = (totalSize.width * devicePixelRatio).round();
		final int h = (totalSize.height * devicePixelRatio).round();
		final ui.Image img = await picture.toImage(w, h);
		picture.dispose();
		_image?.dispose();
		_image = img;
		notifyListeners();
	}

	@override
	void dispose() {
		_image?.dispose();
		_image = null;
		super.dispose();
	}

	void _drawBoardAndSlots(
		Canvas canvas,
		Size totalSize,
		InsetPuzzleController controller,
	) {
		final ui.Rect board = controller.boardRect;
		final Color boardColor = controller.boardColor;

		// 整片白底已由 PuzzleCanvas 處理；這裡只負責「左半 + 散落區底色」。
		// 散落區底色（淺灰）
		canvas.drawRect(
			controller.stageLayout.scatterRect,
			Paint()..color = const Color(0xFFF5F5F5),
		);

		// 底板（馬卡龍色矩形 + 外圍立體感）
		_drawBoard(canvas, board, boardColor);

		// 每片凹槽
		for (final InsetPiece p in controller.pieces) {
			_drawSlot(canvas, controller, p);
		}
	}

	void _drawBoard(Canvas canvas, ui.Rect board, Color boardColor) {
		// 底板矩形
		canvas.drawRRect(
			RRect.fromRectAndRadius(board, const Radius.circular(16)),
			Paint()..color = boardColor,
		);
		// 外圍立體光影：左上偏亮、右下偏暗（凸起感）
		final double t = 4.0;
		// 左 + 上 高光
		final Paint hi = Paint()
			..color = Colors.white.withValues(alpha: 0.5)
			..strokeWidth = t
			..style = PaintingStyle.stroke;
		final Paint lo = Paint()
			..color = Colors.black.withValues(alpha: 0.18)
			..strokeWidth = t
			..style = PaintingStyle.stroke;
		// 用 RRect stroke 出整圈，再用 clip 切上半/下半看不太出來；
		// 簡化：直接全圈一個淡暗影 + 全圈一個淡高光 offset。
		canvas.save();
		canvas.clipRRect(RRect.fromRectAndRadius(board, const Radius.circular(16)));
		// 假裝光源左上：右下畫暗影內邊
		canvas.drawRRect(
			RRect.fromRectAndRadius(board.translate(-1, -1), const Radius.circular(16)),
			lo,
		);
		canvas.drawRRect(
			RRect.fromRectAndRadius(board.translate(1, 1), const Radius.circular(16)),
			hi,
		);
		canvas.restore();
	}

	void _drawSlot(
		Canvas canvas,
		InsetPuzzleController controller,
		InsetPiece p,
	) {
		final SpriteCategory cat = controller.category;
		final SpriteSheet sheet = cat.sheet;
		final ({int sheet, int row, int col})? g = cat.gridOf(p.item);
		if (g == null) return;
		final ui.Image? img = controller.registry.atlas.cachedImage(sheet.file);
		if (img == null) return;
		final double tileD = sheet.tile.toDouble();
		final ui.Rect src = ui.Rect.fromLTWH(
			g.col * tileD,
			g.row * tileD,
			tileD,
			tileD,
		);
		final ui.Rect dst = p.slotRect;

		// 1. 凹槽暗影：sprite 染深、往左上偏 — 上方陰影感
		final Paint dark = Paint()
			..colorFilter = const ColorFilter.mode(Color(0x66000000), BlendMode.srcIn)
			..filterQuality = FilterQuality.medium;
		canvas.drawImageRect(img, src, dst.translate(-1.5, -1.5), dark);

		// 2. 凹槽亮邊：往右下偏
		final Paint light = Paint()
			..colorFilter = const ColorFilter.mode(Color(0x88FFFFFF), BlendMode.srcIn)
			..filterQuality = FilterQuality.medium;
		canvas.drawImageRect(img, src, dst.translate(1.5, 1.5), light);

		// 3. 凹槽主體：純白
		final Paint white = Paint()
			..colorFilter = const ColorFilter.mode(Color(0xFFFFFFFF), BlendMode.srcIn)
			..filterQuality = FilterQuality.medium;
		canvas.drawImageRect(img, src, dst, white);
	}
}
