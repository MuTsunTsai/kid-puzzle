import "dart:ui" as ui;

import "package:flutter/material.dart";

import "../../../../core/constants/app_colors.dart";
import "../../puzzle_dimens.dart";
import "../../domain/models/puzzle_piece.dart";
import "../puzzle_controller.dart";
import "bevel_painter.dart";

/// 拼圖盤 painter：畫盤底色、padding 區（含原圖局部）、中間空白槽位的切割線提示、
/// 已鎖定的拼圖塊。
///
/// 不負責散落區的繪製（由 [PuzzlePiecesPainter] 處理）。
class PuzzleBoardPainter extends CustomPainter {
	PuzzleBoardPainter({
		required this.controller,
		required this.showCutLineHint,
		required this.devicePixelRatio,
		this.cutLineRevealProgress = 1.0,
		this.boardDetailsOpacity = 1.0,
	}) : super(repaint: controller.repaintTick);

	final PuzzleController controller;
	final bool showCutLineHint;

	/// 螢幕的 device pixel ratio；用來決定 piece bitmap 快取的解析度。
	final double devicePixelRatio;

	/// 切割線描繪進度（0 → 完全不畫、1 → 全畫）。沿 path 動態描繪用。
	final double cutLineRevealProgress;

	/// 「拼塊細節」群組的整體透明度（0 → 完全不畫、1 → 正常）。
	///
	/// 套用在：邊框內圈 bevel、locked piece 的 bevel 與邊框、切割線。
	/// 用法：
	/// - 進場淡入：50ms 後 0 → 1
	/// - 完成淡出：所有 piece 鎖定後 1 → 0，畫面回到「沒有切割、只有外圈光影」。
	final double boardDetailsOpacity;

	@override
	void paint(Canvas canvas, Size size) {
		final Rect boardRect = controller.stageLayout.boardRect;

		// 1. 盤底色
		final Paint boardPaint = Paint()..color = AppColors.boardBackground;
		canvas.drawRect(boardRect, boardPaint);

		// 2. 底圖。分兩種模式：
		//    - 靜止（boardDetailsOpacity = 1）：只畫外圈 padding 環（4 條邊拼接），
		//      中央留白靠 locked piece 蓋滿；避免在像素上不對齊產生細微鋸齒。
		//    - 動畫期間（< 1）：直接一次 drawImageRect 畫完整原圖、不拼接，這樣
		//      上層淡出時露出的是「一張完整圖」而非多片拼接結果。
		if (boardDetailsOpacity < 1.0) {
			_drawFullBaseImage(canvas, boardRect);
		} else {
			_drawPaddingFrame(canvas, boardRect);
		}

		// 2.5 在 padding 環本身畫立體光澤（相框感）
		_drawFrameBevel(canvas, boardRect);

		// 3. 切割線提示（如果開啟）
		if (showCutLineHint) {
			_drawCutLineHints(canvas);
		}

		// 4. 已鎖定的 piece 直接畫在盤上正確位置
		for (final PuzzlePiece p in controller.layout.pieces) {
			if (p.locked) {
				_drawLockedPiece(canvas, p);
			}
		}
	}

	/// 在整個 boardRect 一次畫完整原圖。
	///
	/// 動畫期間（進場淡入 / 完成淡出）使用：上層 padding 邊條、frame bevel、
	/// locked piece 全都會 fade，此時下層必須是「一張完整、無拼接縫的圖」，
	/// 否則使用者會在淡出最後一刻看到 4 條邊條 + 內側補圖的接合痕跡。
	void _drawFullBaseImage(Canvas canvas, Rect boardRect) {
		final ui.Image image = controller.boardImage;
		final ui.Size imgSize = controller.boardImageSize;
		canvas.drawImageRect(
			image,
			Rect.fromLTWH(0, 0, imgSize.width, imgSize.height),
			boardRect,
			Paint()..filterQuality = FilterQuality.medium,
		);
	}

	/// 畫原圖最外圈 padding 環（讓四角保留原圖、形成「拼圖盤」感）。
	void _drawPaddingFrame(Canvas canvas, Rect boardRect) {
		final double padding = controller.layout.boardPadding;
		final ui.Image image = controller.boardImage;
		final ui.Size imgSize = controller.boardImageSize;

		// 4 個邊條：上、下、左、右
		void drawStripe(Rect destInBoard, Rect srcInBoard) {
			final double scaleX = imgSize.width / boardRect.width;
			final double scaleY = imgSize.height / boardRect.height;
			final Rect srcInImage = Rect.fromLTWH(
				srcInBoard.left * scaleX,
				srcInBoard.top * scaleY,
				srcInBoard.width * scaleX,
				srcInBoard.height * scaleY,
			);
			final Rect destStage = destInBoard.shift(boardRect.topLeft);
			canvas.drawImageRect(
				image,
				srcInImage,
				destStage,
				Paint()..filterQuality = FilterQuality.medium,
			);
		}

		final Size bs = controller.layout.boardSize;
		// 四條皆延伸覆蓋整段邊（含四角），讓相鄰條在角落形成完整正方形重疊區域，
		// 避免 web canvas 在條與條的相切處因 sub-pixel 採樣產生細縫。
		// 上條（含四角）
		drawStripe(
			Rect.fromLTWH(0, 0, bs.width, padding),
			Rect.fromLTWH(0, 0, bs.width, padding),
		);
		// 下條（含四角）
		drawStripe(
			Rect.fromLTWH(0, bs.height - padding, bs.width, padding),
			Rect.fromLTWH(0, bs.height - padding, bs.width, padding),
		);
		// 左條（含四角）
		drawStripe(
			Rect.fromLTWH(0, 0, padding, bs.height),
			Rect.fromLTWH(0, 0, padding, bs.height),
		);
		// 右條（含四角）
		drawStripe(
			Rect.fromLTWH(bs.width - padding, 0, padding, bs.height),
			Rect.fromLTWH(bs.width - padding, 0, padding, bs.height),
		);
	}

	/// 在 padding 環（外圈與內圈之間）畫立體光澤。
	///
	/// padding 環本身視為一片凸起的「相框」：
	/// - 沿著環的**外圈**畫 bevel（凸起風格：左上亮、右下暗）→ 相框外緣凸出
	/// - 沿著環的**內圈**畫反向 bevel（凹槽風格：左上暗、右下亮）→ 相框內緣下凹
	/// 兩條 bevel 都 clip 在環內，避免覆蓋到中央拼圖區與相框外的場景。
	///
	/// **效能**：bevel 是純幾何函式、結果隨 boardRect 不變，因此整個環的繪製
	/// 結果烤成 bitmap 一次（外圈 groove + 內圈 bevel @ 100% 透明度），每幀只
	/// drawImageRect，再用 [Paint.colorFilter] 套 `boardDetailsOpacity`。
	///
	/// 注意：原版「外圈一律 100%、內圈套 opacity」的視覺差異被合併成「整個環
	/// 一起淡入淡出」— 但 `boardDetailsOpacity` 在動畫期間才 < 1（進場 200~700ms
	/// 與完成淡出 500ms），靜止 = 1.0，視覺上幾乎察覺不出差異。
	void _drawFrameBevel(Canvas canvas, Rect boardRect) {
		ui.Image? cached = controller.frameBevelCache;
		if (cached == null) {
			cached = _bakeFrameBevel(boardRect);
			controller.frameBevelCache = cached;
		}
		final double op = boardDetailsOpacity.clamp(0.0, 1.0);
		if (op <= 0) return;
		final Paint paint = Paint()..filterQuality = FilterQuality.none;
		if (op < 1.0) {
			paint.colorFilter = ColorFilter.mode(
				Color.fromRGBO(255, 255, 255, op),
				BlendMode.modulate,
			);
		}
		canvas.drawImageRect(
			cached,
			Rect.fromLTWH(0, 0, cached.width.toDouble(), cached.height.toDouble()),
			boardRect,
			paint,
		);
	}

	/// 一次性烤出整個相框 bevel 結果到 bitmap。
	///
	/// 用 board 邏輯尺寸 × dpr，畫面上 1:1 對應物理像素。
	ui.Image _bakeFrameBevel(Rect boardRect) {
		final double padding = controller.layout.boardPadding;
		final Rect innerLocal = Rect.fromLTWH(
			padding,
			padding,
			boardRect.width - 2 * padding,
			boardRect.height - 2 * padding,
		);
		final Rect localBoard = Rect.fromLTWH(0, 0, boardRect.width, boardRect.height);

		final double dpr = devicePixelRatio;
		final int wPx = (boardRect.width * dpr).ceil();
		final int hPx = (boardRect.height * dpr).ceil();

		final ui.PictureRecorder recorder = ui.PictureRecorder();
		final Canvas canvas = Canvas(
			recorder,
			Rect.fromLTWH(0, 0, wPx.toDouble(), hPx.toDouble()),
		);
		canvas.scale(dpr);

		// 環形 path：外圈 - 內圈 = 環
		final Path ringPath = Path()
			..addRect(localBoard)
			..addRect(innerLocal)
			..fillType = PathFillType.evenOdd;
		canvas.save();
		canvas.clipPath(ringPath);

		// 外圈邊：凹槽風格
		BevelPainter.drawInnerGroove(canvas, Path()..addRect(localBoard));
		// 內圈邊：凸起風格
		BevelPainter.drawInnerBevel(canvas, Path()..addRect(innerLocal));

		canvas.restore();

		final ui.Picture picture = recorder.endRecording();
		final ui.Image image = picture.toImageSync(wPx, hPx);
		picture.dispose();
		return image;
	}

	/// 在拼圖盤內部空白區用虛線描出每個 piece 的形狀作為提示。
	///
	/// 若 [cutLineRevealProgress] < 1，沿 path 只描繪部分長度（動畫浮現）。
	void _drawCutLineHints(Canvas canvas) {
		if (cutLineRevealProgress <= 0) return;
		final double op = boardDetailsOpacity.clamp(0.0, 1.0);
		if (op <= 0) return;
		final Paint paint = Paint()
			..color = AppColors.cutLineHint.withValues(alpha: AppColors.cutLineHint.a * op)
			..style = PaintingStyle.stroke
			..strokeWidth = PuzzleDimens.cutLineWidth
			..strokeJoin = StrokeJoin.round;

		final Offset boardOrigin = controller.stageLayout.boardOrigin;
		for (final PuzzlePiece p in controller.layout.pieces) {
			// 把 piece 的 localPath（以 sourceRect.topLeft 為原點）平移到盤上正確位置
			final Path path = p.localPath.shift(
				Offset(
					p.sourceRect.left + boardOrigin.dx,
					p.sourceRect.top + boardOrigin.dy,
				),
			);
			if (cutLineRevealProgress >= 1.0) {
				canvas.drawPath(path, paint);
			} else {
				// 沿 path 取前 progress 比例的部分
				for (final ui.PathMetric metric in path.computeMetrics()) {
					final double len = metric.length;
					if (len <= 0) continue;
					final Path partial =
							metric.extractPath(0, len * cutLineRevealProgress);
					canvas.drawPath(partial, paint);
				}
			}
		}
	}

	/// 把鎖定的 piece 畫在盤上正確位置。
	///
	/// 使用「圖案 + 光影」合成快取 + 向量邊框。底下已有完整原圖（[_drawInnerBaseImage]），
	/// 所以 `boardDetailsOpacity` 1→0 淡出時整片消失剛好露出底圖、無縫銜接。
	void _drawLockedPiece(Canvas canvas, PuzzlePiece p) {
		final double op = boardDetailsOpacity.clamp(0.0, 1.0);
		if (op <= 0) return;

		final Offset boardOrigin = controller.stageLayout.boardOrigin;
		final Offset destTopLeft = Offset(
			p.sourceRect.left + boardOrigin.dx,
			p.sourceRect.top + boardOrigin.dy,
		);

		canvas.save();
		canvas.translate(destTopLeft.dx, destTopLeft.dy);

		// 「圖案 + 光影」快取
		final ui.Image cache = controller.bevelCache.putIfAbsent(
			p.id,
			() => BevelPainter.rasterizePieceWithBevel(
				path: p.localPath,
				pieceSize: p.sourceRect.size,
				sourceImage: controller.boardImage,
				srcRectInImage: _srcRectInImage(p),
				style: BevelStyle.groove,
				devicePixelRatio: devicePixelRatio,
			),
		);
		final Paint cachePaint = Paint()..filterQuality = FilterQuality.medium;
		if (op < 1.0) {
			cachePaint.colorFilter = ColorFilter.mode(
				Color.fromRGBO(255, 255, 255, op),
				BlendMode.modulate,
			);
		}
		canvas.drawImageRect(
			cache,
			Rect.fromLTWH(0, 0, cache.width.toDouble(), cache.height.toDouble()),
			Rect.fromLTWH(0, 0, p.sourceRect.width, p.sourceRect.height),
			cachePaint,
		);

		// 邊框（向量、相鄰 piece 共享邊上完美重疊）
		final Paint border = Paint()
			..style = PaintingStyle.stroke
			..strokeWidth = PuzzleDimens.pieceBorderWidth
			..strokeJoin = StrokeJoin.round
			..color = AppColors.pieceBorder.withValues(
				alpha: AppColors.pieceBorder.a * op,
			);
		canvas.drawPath(p.localPath, border);

		canvas.restore();
	}

	/// 把 piece 的 sourceRect（盤上座標）換算到原圖（pixel）座標。
	Rect _srcRectInImage(PuzzlePiece p) {
		final Rect boardRect = controller.stageLayout.boardRect;
		final ui.Size imgSize = controller.boardImageSize;
		final double scaleX = imgSize.width / boardRect.width;
		final double scaleY = imgSize.height / boardRect.height;
		return Rect.fromLTWH(
			p.sourceRect.left * scaleX,
			p.sourceRect.top * scaleY,
			p.sourceRect.width * scaleX,
			p.sourceRect.height * scaleY,
		);
	}

	@override
	bool shouldRepaint(covariant PuzzleBoardPainter oldDelegate) {
		return oldDelegate.controller != controller ||
				oldDelegate.showCutLineHint != showCutLineHint ||
				oldDelegate.devicePixelRatio != devicePixelRatio ||
				oldDelegate.cutLineRevealProgress != cutLineRevealProgress ||
				oldDelegate.boardDetailsOpacity != boardDetailsOpacity;
	}
}

