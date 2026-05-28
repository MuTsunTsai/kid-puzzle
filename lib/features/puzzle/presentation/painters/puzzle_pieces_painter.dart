import "dart:math" as math;
import "dart:ui" as ui;

import "package:flutter/foundation.dart" show setEquals;
import "package:flutter/material.dart";

import "../../../../core/constants/app_colors.dart";
import "../../puzzle_dimens.dart";
import "../../domain/models/puzzle_piece.dart";
import "../puzzle_controller.dart";
import "bevel_painter.dart";

/// 散落區 painter：畫散落區背景、未鎖定的拼圖塊。
///
/// 已鎖定 piece 由 [PuzzleBoardPainter] 負責，不在此重畫。
/// 拖曳中 piece 透過 [draggingGroupIds] 標示、繪製在最上層。支援多指拖曳
/// （同時 0 到 2 個群組）。
///
/// 動畫整合：
/// - [introProgress]：進關卡飛散動畫，0 → 1。0 時拼片在 `introStartPosition`
///   （拼圖盤正確位置），1 時抵達 `currentPosition`（散落位）。
/// - [lockFeedbackProgress]：剛鎖定的 pieces 套用 elastic scale 1 → 1.05 → 1。
class PuzzlePiecesPainter extends CustomPainter {
	PuzzlePiecesPainter({
		required this.controller,
		required this.devicePixelRatio,
		Set<int>? draggingGroupIds,
		this.lockFeedbackProgress = 0.0,
		this.introProgress = 1.0,
		this.pieceBevelOpacity = 1.0,
	})  : draggingGroupIds = draggingGroupIds ?? const <int>{},
				super(repaint: controller.repaintTick);

	final PuzzleController controller;

	/// 螢幕的 device pixel ratio；用來決定 piece bitmap 快取的解析度。
	final double devicePixelRatio;

	/// 正在被拖曳的群組 ID 集合（空 = 沒有拖曳；多指時可同時 1~2 個）。
	final Set<int> draggingGroupIds;

	/// 鎖定回饋動畫進度（0..1）；0 表示沒在播。
	final double lockFeedbackProgress;

	/// 進關卡飛散動畫進度（0..1）；1 表示完成。
	final double introProgress;

	/// 拼塊光澤 + 邊框 bitmap 的透明度（0..1）；用於進場淡入。
	final double pieceBevelOpacity;

	@override
	void paint(Canvas canvas, Size size) {
		// 1. 散落區背景
		final Rect scatter = controller.stageLayout.scatterRect;
		final Paint bg = Paint()..color = AppColors.pieceArea;
		canvas.drawRect(scatter, bg);

		// 2. 把未鎖定 piece 分成兩組：拖曳中與其他，其他先畫、拖曳中後畫
		final List<PuzzlePiece> normal = <PuzzlePiece>[];
		final List<PuzzlePiece> dragging = <PuzzlePiece>[];
		for (final PuzzlePiece p in controller.layout.pieces) {
			if (p.locked) continue;
			if (draggingGroupIds.contains(p.groupId)) {
				dragging.add(p);
			} else {
				normal.add(p);
			}
		}

		// 同組內按 zIndex 升序、再 id 升序保穩定
		normal.sort((a, b) {
			final int byZ = a.zIndex.compareTo(b.zIndex);
			return byZ != 0 ? byZ : a.id.compareTo(b.id);
		});
		dragging.sort((a, b) => a.id.compareTo(b.id));

		for (final PuzzlePiece p in normal) {
			_drawPiece(canvas, p);
		}
		for (final PuzzlePiece p in dragging) {
			_drawPiece(canvas, p);
		}
	}

	void _drawPiece(Canvas canvas, PuzzlePiece p) {
		// 解析最終要套到 piece 的 Offset（飛散動畫 + currentPosition）
		final Offset drawPos = _animatedPosition(p);

		// 鎖定回饋：對「最近鎖定」群組成員套 elastic scale 1 → 1.05 → 1
		final double scale = controller.lastLockedPieces.contains(p.id)
				? _lockFeedbackScale(lockFeedbackProgress)
				: 1.0;

		// 群組旋轉：以群組 pivot 為軸旋轉。rotationEnabled = false 時所有
		// groupCurrentRotation() 都是 0、不會繪製。
		// 飛散動畫期間用 introProgress 把角度從 0 lerp 到目前角度，讓 piece
		// 看起來「邊飛邊轉」而非「轉好了再飛」。
		double rotDeg = controller.rotationEnabled
				? controller.groupCurrentRotation(p.groupId)
				: 0.0;
		if (introProgress < 1.0) {
			rotDeg = rotDeg * introProgress;
		}

		canvas.save();
		if (rotDeg != 0.0) {
			// 飛散動畫期間 piece 視覺位置在 [drawPos] 而非 currentPosition；如果
			// 直接用 controller.groupPivot（以最終位置為基準），piece 會「繞著終點
			// 旋轉」、視覺上像從四面八方飛入。
			// scatter 時每片自成一群，pivot 就是該 piece 的 polygonAabb 中心。
			// 由於 polygonAabb 與 sourceRect 都是「拼圖盤座標」、piece local 原點
			// 對應 sourceRect.topLeft，這裡用 drawPos 為基準算當下視覺中心。
			final Offset pivot;
			if (introProgress < 1.0) {
				final Offset offsetFromTopLeft = ui.Offset(
					p.polygonAabb.center.dx - p.sourceRect.left,
					p.polygonAabb.center.dy - p.sourceRect.top,
				);
				pivot = drawPos + offsetFromTopLeft;
			} else {
				pivot = controller.groupPivot(p.groupId);
			}
			canvas.translate(pivot.dx, pivot.dy);
			canvas.rotate(rotDeg * math.pi / 180.0);
			canvas.translate(-pivot.dx, -pivot.dy);
		}
		if (scale != 1.0) {
			// 以 piece 中心做 scale
			final Offset center =
					drawPos + Offset(p.sourceRect.width / 2, p.sourceRect.height / 2);
			canvas.translate(center.dx, center.dy);
			canvas.scale(scale);
			canvas.translate(-center.dx, -center.dy);
		}

		canvas.translate(drawPos.dx, drawPos.dy);

		// 「圖案 + 光影」快取 bitmap：第一次繪製時用原圖區塊 + clip + bevel 合成
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
		if (pieceBevelOpacity < 1.0) {
			cachePaint.colorFilter = ColorFilter.mode(
				Color.fromRGBO(255, 255, 255, pieceBevelOpacity.clamp(0.0, 1.0)),
				BlendMode.modulate,
			);
		}
		// cache 是「邏輯尺寸 × dpr」的 bitmap，用 drawImageRect 還原邏輯尺寸：
		// 1 物理像素 ↔ 1 邏輯像素 × dpr，畫面上 1:1，沒有放大模糊。
		canvas.drawImageRect(
			cache,
			Rect.fromLTWH(0, 0, cache.width.toDouble(), cache.height.toDouble()),
			Rect.fromLTWH(0, 0, p.sourceRect.width, p.sourceRect.height),
			cachePaint,
		);

		// 邊框：用向量畫，兩片相鄰時 stroke 完美重疊在共享邊上、無縫。
		// 進場期間 pieceBevelOpacity < 1 時整條邊框也跟著淡入，否則會在
		// 「圖片底圖」上提早露出切割線，破壞「先全圖再浮現切割」的觀感。
		final double borderOp = pieceBevelOpacity.clamp(0.0, 1.0);
		if (borderOp > 0) {
			final Color borderColor = AppColors.pieceBorder;
			final Paint border = Paint()
				..style = PaintingStyle.stroke
				..strokeWidth = PuzzleDimens.pieceBorderWidth *
						(controller.bigKidMode ? 0.5 : 1.0)
				..strokeJoin = StrokeJoin.round
				..color = borderColor.withValues(alpha: borderColor.a * borderOp);
			canvas.drawPath(p.localPath, border);
		}

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

	/// 套用飛散動畫的繪製位置。
	Offset _animatedPosition(PuzzlePiece p) {
		final Offset? start = p.introStartPosition;
		if (start == null || introProgress >= 1.0) return p.currentPosition;
		return Offset.lerp(start, p.currentPosition, introProgress)!;
	}

	/// 把 0..1 progress 轉成 1.0 → 1.05 → 1.0（elastic-like）。
	static double _lockFeedbackScale(double progress) {
		if (progress <= 0 || progress >= 1) return 1.0;
		// 用 sin(pi * t) 形成簡潔的「上升再下降」、振幅 0.05
		return 1.0 + math.sin(progress * math.pi) * 0.05;
	}

	@override
	bool shouldRepaint(covariant PuzzlePiecesPainter oldDelegate) {
		return oldDelegate.controller != controller ||
				oldDelegate.devicePixelRatio != devicePixelRatio ||
				!setEquals(oldDelegate.draggingGroupIds, draggingGroupIds) ||
				oldDelegate.lockFeedbackProgress != lockFeedbackProgress ||
				oldDelegate.introProgress != introProgress ||
				oldDelegate.pieceBevelOpacity != pieceBevelOpacity;
	}
}
