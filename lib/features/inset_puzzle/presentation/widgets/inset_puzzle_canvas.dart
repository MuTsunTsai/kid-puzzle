import "dart:ui" as ui;

import "package:flutter/gestures.dart" show PointerDeviceKind;
import "package:flutter/material.dart";

import "../../../../core/sprites/sprite_manifest.dart";
import "../../domain/inset_piece.dart";
import "../inset_puzzle_controller.dart";
import "inset_board_painter.dart";

/// 嵌入拼圖畫布：底板（烤 bitmap）+ sprite 拼片 + pointer 事件。
///
/// 進場流程：
/// 1. mount 後等 [imageShownAt] 滿 200ms（與多片拼圖一致）
/// 2. 啟動 scatter 動畫：拼片從正確 slot 位置飛到 currentPosition
class InsetPuzzleCanvas extends StatefulWidget {
	const InsetPuzzleCanvas({
		super.key,
		required this.controller,
		required this.boardCache,
		this.imageShownAt,
	});

	final InsetPuzzleController controller;
	final InsetBoardCache boardCache;
	final DateTime? imageShownAt;

	@override
	State<InsetPuzzleCanvas> createState() => _InsetPuzzleCanvasState();
}

class _InsetPuzzleCanvasState extends State<InsetPuzzleCanvas>
		with SingleTickerProviderStateMixin {
	final Set<int> _activePointers = <int>{};

	/// 進場 scatter 動畫：拼片從正確位置飛到散落位置，1000ms。
	late final AnimationController _intro;

	@override
	void initState() {
		super.initState();
		_intro = AnimationController(
			vsync: this,
			duration: const Duration(milliseconds: 1000),
		);
		WidgetsBinding.instance.addPostFrameCallback((_) {
			if (mounted) _scheduleIntro();
		});
	}

	void _scheduleIntro() {
		// 先把 value 重置為 0，hold 期間（200ms 內）就會畫盤上正確位置而非
		// 散落位。否則上一關結束時 _intro.value=1.0、didUpdateWidget 換關卡
		// 後在 forward(from:0) 真正執行前的 200ms hold 內仍會被當成「動畫已
		// 完成」→ painter 直接畫 currentPosition（散落位）→ 玩家看到拼片在
		// 右邊一瞬間，hold 結束才從盤上飛回散落位。
		_intro.value = 0;
		const Duration hold = Duration(milliseconds: 200);
		final DateTime? shown = widget.imageShownAt;
		final Duration wait;
		if (shown == null) {
			wait = Duration.zero;
		} else {
			final Duration elapsed = DateTime.now().difference(shown);
			wait = elapsed >= hold ? Duration.zero : hold - elapsed;
		}
		if (wait == Duration.zero) {
			_intro.forward(from: 0);
		} else {
			Future<void>.delayed(wait, () {
				if (mounted) _intro.forward(from: 0);
			});
		}
	}

	@override
	void didUpdateWidget(covariant InsetPuzzleCanvas oldWidget) {
		super.didUpdateWidget(oldWidget);
		if (oldWidget.controller != widget.controller) {
			_scheduleIntro();
		}
	}

	@override
	void dispose() {
		_intro.dispose();
		super.dispose();
	}

	void _onPointerDown(PointerDownEvent e) {
		final bool isTouch = e.kind == PointerDeviceKind.touch;
		final bool ok = widget.controller
				.beginDrag(e.pointer, e.localPosition, fuzzy: isTouch);
		if (ok) _activePointers.add(e.pointer);
	}

	void _onPointerMove(PointerMoveEvent e) {
		if (!_activePointers.contains(e.pointer)) return;
		widget.controller.dragBy(e.pointer, e.localPosition, e.delta);
	}

	void _onPointerUp(PointerUpEvent e) {
		if (_activePointers.remove(e.pointer)) {
			widget.controller.endDrag(e.pointer);
		}
	}

	void _onPointerCancel(PointerCancelEvent e) => _onPointerUp(
				PointerUpEvent(pointer: e.pointer, position: e.position),
			);

	@override
	Widget build(BuildContext context) {
		return SizedBox.expand(
			child: Stack(
				children: <Widget>[
					Positioned.fill(
						child: CustomPaint(
							painter: InsetBoardPainter(
								controller: widget.controller,
								cache: widget.boardCache,
							),
						),
					),
					Positioned.fill(
						child: AnimatedBuilder(
							animation: Listenable.merge(<Listenable>[
								widget.controller.repaintTick,
								_intro,
							]),
							builder: (BuildContext context, _) {
								final double t = Curves.easeOutCubic
										.transform(_intro.value.clamp(0.0, 1.0));
								return CustomPaint(
									painter: _PiecesPainter(
										controller: widget.controller,
										introProgress: t,
									),
								);
							},
						),
					),
					Positioned.fill(
						child: Listener(
							behavior: HitTestBehavior.opaque,
							onPointerDown: _onPointerDown,
							onPointerMove: _onPointerMove,
							onPointerUp: _onPointerUp,
							onPointerCancel: _onPointerCancel,
						),
					),
				],
			),
		);
	}
}

/// 拼片繪製。鎖定的片直接畫在 slotRect；未鎖定的依 introProgress 從 slot
/// 中心 lerp 到 currentPosition。
class _PiecesPainter extends CustomPainter {
	_PiecesPainter({required this.controller, required this.introProgress});

	final InsetPuzzleController controller;
	final double introProgress;

	@override
	void paint(Canvas canvas, Size size) {
		final List<InsetPiece> ordered = List<InsetPiece>.from(controller.pieces)
			..sort((InsetPiece a, InsetPiece b) => a.zIndex.compareTo(b.zIndex));
		final Paint imgPaint = Paint()..filterQuality = FilterQuality.medium;
		for (final InsetPiece p in ordered) {
			final SpriteCategory cat = controller.category;
			final SpriteSheet sheet = cat.sheet;
			final ({int sheet, int row, int col})? g = cat.gridOf(p.item);
			if (g == null) continue;
			final ui.Image? img =
					controller.registry.atlas.cachedImage(sheet.file);
			if (img == null) continue;
			final double tile = sheet.tile.toDouble();
			final ui.Rect src = ui.Rect.fromLTWH(
				g.col * tile,
				g.row * tile,
				tile,
				tile,
			);
			final ui.Rect dst;
			if (p.locked) {
				dst = p.slotRect;
			} else {
				// scatter 進場：introProgress 0 = 在 slot 上、1 = 在 currentPosition
				final ui.Offset start = p.slotRect.topLeft;
				final ui.Offset end = p.currentPosition;
				final ui.Offset pos = ui.Offset.lerp(start, end, introProgress)!;
				dst = pos & p.displaySize;
			}
			canvas.drawImageRect(img, src, dst, imgPaint);
		}
	}

	@override
	bool shouldRepaint(covariant _PiecesPainter oldDelegate) => true;
}
