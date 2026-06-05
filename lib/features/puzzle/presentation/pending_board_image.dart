import "dart:async";
import "dart:math";
import "dart:ui" as ui;

import "package:flutter/material.dart";

import "../../../core/constants/app_colors.dart";
import "../domain/services/cell_planner.dart";
import "loaded_image.dart";
import "puzzle_controller.dart";

/// 過渡期顯示：圖載完但 controller 還沒準備好時，用 [PuzzleStageLayout] 算出
/// 的 boardRect 把完整未切割大圖畫到正確位置；右半填散落區底色。
///
/// 上方疊「刀光快速劃過」spinner：每 [_slashIntervalMs] 毫秒生一刀，每刀是
/// 一段短漸層線在 [_slashDurationMs] 毫秒內以等速沿其角度方向掠過 board，
/// 視覺上像「快速切割」。中心點對 boardRect 中心加 jitter（範圍 ±50% 短邊）。
class PendingBoardImage extends StatefulWidget {
	const PendingBoardImage({
		super.key,
		required this.image,
		required this.cutMode,
		required this.pieceCount,
	});

	final LoadedImage image;

	/// 切割模式：[CutMode.grid] 時刀光角度只取垂直 / 水平；[CutMode.voronoi]
	/// 時任意角度 0~π。
	final CutMode cutMode;

	/// 該關片數。低於 [_PendingBoardImageState._pendingAnimationsMinPieces] 時
	/// 切割很快、不顯示刀光與中央 spinner（純大圖即可），避免短暫閃爍動畫。
	final int pieceCount;

	@override
	State<PendingBoardImage> createState() => _PendingBoardImageState();
}

class _PendingBoardImageState extends State<PendingBoardImage>
		with SingleTickerProviderStateMixin {
	/// 每隔多久觸發一刀。
	static const int _slashIntervalMs = 700;
	/// 單刀掠過時長。
	static const int _slashDurationMs = 300;
	/// 漸層線本身長度相對 boardRect 短邊的比例。
	static const double _slashLengthRatio = 0.4;
	/// 刀光中心點對 boardRect 中心的最大 jitter（相對短邊比例）。
	static const double _centerJitterRatio = 0.25;
	/// 片數 < 此值就不顯示刀光與中央 spinner（切割很快、動畫只會閃一下）。
	static const int _pendingAnimationsMinPieces = 50;

	late final AnimationController _controller;
	final Random _random = Random();
	final List<_Slash> _slashes = <_Slash>[];
	Timer? _spawnTimer;
	int _nextId = 0;

	bool get _animationsEnabled =>
			widget.pieceCount >= _pendingAnimationsMinPieces;

	@override
	void initState() {
		super.initState();
		// 連續 ticker：讓 painter 每幀 rebuild、推進所有 active slash 的進度。
		_controller = AnimationController(
			vsync: this,
			duration: const Duration(milliseconds: 1000),
		);
		// 低片數時不啟動動畫（純大圖、無 spinner、無刀光）。
		if (_animationsEnabled) {
			_controller.repeat();
			_spawnTimer = Timer.periodic(
				const Duration(milliseconds: _slashIntervalMs),
				(_) => _spawn(),
			);
			// 首刀立即出（不等 _slashIntervalMs）
			_spawn();
		}
	}

	void _spawn() {
		if (!mounted) return;
		// grid 模式：刀光只能垂直或水平。
		final double angle;
		if (widget.cutMode == CutMode.grid) {
			angle = _random.nextBool() ? 0.0 : pi / 2;
		} else {
			angle = _random.nextDouble() * pi;
		}
		setState(() {
			_slashes.add(_Slash(
				id: _nextId++,
				angleRad: angle,
				jitterFracX: _random.nextDouble() * 2 - 1,
				jitterFracY: _random.nextDouble() * 2 - 1,
				startedAt: DateTime.now(),
			));
			// 清掉已超過時長的
			final DateTime now = DateTime.now();
			_slashes.removeWhere((_Slash s) =>
					now.difference(s.startedAt).inMilliseconds > _slashDurationMs);
		});
	}

	@override
	void dispose() {
		_spawnTimer?.cancel();
		_controller.dispose();
		super.dispose();
	}

	@override
	Widget build(BuildContext context) {
		return LayoutBuilder(
			builder: (BuildContext context, BoxConstraints constraints) {
				final Size totalSize =
						Size(constraints.maxWidth, constraints.maxHeight);
				final PuzzleStageLayout stage =
						PuzzleStageLayout.forSize(totalSize);
				return Stack(
					children: <Widget>[
						// 圖 + 散落區底色 + （若啟用）刀光
						Positioned.fill(
							child: AnimatedBuilder(
								animation: _controller,
								builder: (BuildContext context, _) {
									return CustomPaint(
										size: totalSize,
										painter: _PendingBoardImagePainter(
											image: widget.image.image,
											imageSize: widget.image.size,
											boardRect: stage.boardRect,
											scatterRect: stage.scatterRect,
											slashes: _animationsEnabled ? _slashes : const <_Slash>[],
											now: DateTime.now(),
											slashDurationMs: _slashDurationMs,
											slashLengthRatio: _slashLengthRatio,
											centerJitterRatio: _centerJitterRatio,
										),
									);
								},
							),
						),
						// 大圖中央 spinner：只在啟用動畫時出現（高片數 = 切割慢、才需要提示）。
						if (_animationsEnabled)
							Positioned.fromRect(
								rect: stage.boardRect,
								child: const Center(
									child: SizedBox(
										width: 48,
										height: 48,
										child: CircularProgressIndicator(
											strokeWidth: 4,
											valueColor: AlwaysStoppedAnimation<Color>(
												Colors.white,
											),
										),
									),
								),
							),
					],
				);
			},
		);
	}
}

/// 單一刀光描述：
/// - [angleRad]：行進方向（弧度、0~π）
/// - [jitterFracX / Y]：中心 jitter 在 [-1, 1]，乘上 centerJitterRatio × 短邊
/// - [startedAt]：起始時刻；painter 用 `now - startedAt` 算 0..1 進度
class _Slash {
	const _Slash({
		required this.id,
		required this.angleRad,
		required this.jitterFracX,
		required this.jitterFracY,
		required this.startedAt,
	});
	final int id;
	final double angleRad;
	final double jitterFracX;
	final double jitterFracY;
	final DateTime startedAt;
}

class _PendingBoardImagePainter extends CustomPainter {
	_PendingBoardImagePainter({
		required this.image,
		required this.imageSize,
		required this.boardRect,
		required this.scatterRect,
		required this.slashes,
		required this.now,
		required this.slashDurationMs,
		required this.slashLengthRatio,
		required this.centerJitterRatio,
	});

	final ui.Image image;
	final ui.Size imageSize;
	final ui.Rect boardRect;
	final ui.Rect scatterRect;
	final List<_Slash> slashes;
	final DateTime now;
	final int slashDurationMs;
	final double slashLengthRatio;
	final double centerJitterRatio;

	@override
	void paint(Canvas canvas, Size size) {
		// 1. 盤底色襯
		final Paint boardBg = Paint()..color = AppColors.boardBackground;
		canvas.drawRect(Offset.zero & size, boardBg);
		// 2. 散落區底色（與最終 PuzzlePiecesPainter 一致）
		final Paint scatterBg = Paint()..color = AppColors.pieceArea;
		canvas.drawRect(scatterRect, scatterBg);
		// 3. 整張圖鋪到 boardRect
		canvas.drawImageRect(
			image,
			Rect.fromLTWH(0, 0, imageSize.width, imageSize.height),
			boardRect,
			Paint()..filterQuality = FilterQuality.medium,
		);
		// 4. 刀光
		_paintSlashes(canvas);
	}

	void _paintSlashes(Canvas canvas) {
		if (slashes.isEmpty) return;
		final Offset boardCenter = boardRect.center;
		final double shortSide =
				boardRect.shortestSide;
		final double maxJitter = shortSide * centerJitterRatio;
		final double slashLength = shortSide * slashLengthRatio;
		// 刀光從 board 邊外進入、掠到對側邊外消失。行進總距離 = 對角線長 + 一點
		// buffer，確保完全切過 board；progress 0 起點在 board 外、progress 1
		// 終點在 board 外。
		final double travelDistance =
				sqrt(boardRect.width * boardRect.width +
						boardRect.height * boardRect.height) +
				slashLength;

		canvas.save();
		canvas.clipRect(boardRect);
		for (final _Slash s in slashes) {
			final double t =
					now.difference(s.startedAt).inMilliseconds / slashDurationMs;
			if (t < 0 || t > 1) continue;
			// 中心點：board 中心 + jitter
			final Offset center = boardCenter +
					Offset(s.jitterFracX * maxJitter, s.jitterFracY * maxJitter);
			// 方向向量（沿刀光行進方向）
			final double dirX = cos(s.angleRad);
			final double dirY = sin(s.angleRad);
			// 此時段內、刀光「中心」沿方向位移：從 -travelDistance/2 → +travelDistance/2
			final double offset = (t - 0.5) * travelDistance;
			final Offset segCenter =
					center + Offset(dirX * offset, dirY * offset);
			// 短漸層線兩端
			final Offset a = segCenter - Offset(dirX, dirY) * (slashLength / 2);
			final Offset b = segCenter + Offset(dirX, dirY) * (slashLength / 2);
			final Paint paint = Paint()
				..strokeWidth = 4
				..strokeCap = StrokeCap.round
				..shader = ui.Gradient.linear(
					a,
					b,
					<Color>[
						Colors.white.withValues(alpha: 0.0),
						Colors.white.withValues(alpha: 0.95),
						Colors.white.withValues(alpha: 0.0),
					],
					<double>[0.0, 0.5, 1.0],
				);
			canvas.drawLine(a, b, paint);
		}
		canvas.restore();
	}

	@override
	bool shouldRepaint(covariant _PendingBoardImagePainter oldDelegate) => true;
}
