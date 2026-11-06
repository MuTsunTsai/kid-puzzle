import "dart:math";
import "dart:ui" as ui;

import "package:flutter/material.dart";

/// 單張記憶卡：背面（馬卡龍色 + 星星）/ 正面（白底 + sprite）。
///
/// 動畫：
/// - [faceUp] 變動 → 3D 翻牌（繞 Y 軸 180°、[flipDuration]）
/// - [removing] 變 true → 先彈大、再縮小旋轉淡出，同時灑出星星粒子
///   （[removeDuration]）；結束後呼叫 [onRemoved]、之後不再畫任何東西
///
/// 點擊用 Listener.onPointerDown 而非 GestureDetector.onTap：幼兒常多指同時
/// 按，TapGestureRecognizer 偵測到第二指就 cancel。
class MemoryCardView extends StatefulWidget {
	const MemoryCardView({
		super.key,
		required this.faceUp,
		required this.removing,
		required this.image,
		required this.srcRect,
		required this.backColor,
		required this.onTap,
		required this.onRemoved,
	});

	static const Duration flipDuration = Duration(milliseconds: 320);
	static const Duration removeDuration = Duration(milliseconds: 750);

	final bool faceUp;
	final bool removing;

	/// sprite 所在的 sheet 圖。
	final ui.Image image;

	/// sprite 在 sheet 上的像素矩形。
	final Rect srcRect;

	/// 卡背主色（同一關所有卡共用）。
	final Color backColor;

	final VoidCallback onTap;
	final VoidCallback onRemoved;

	@override
	State<MemoryCardView> createState() => _MemoryCardViewState();
}

class _MemoryCardViewState extends State<MemoryCardView>
		with TickerProviderStateMixin {
	late final AnimationController _flip = AnimationController(
		vsync: this,
		duration: MemoryCardView.flipDuration,
		value: widget.faceUp ? 1 : 0,
	);
	late final AnimationController _remove = AnimationController(
		vsync: this,
		duration: MemoryCardView.removeDuration,
	);
	late final Animation<double> _flipCurve = CurvedAnimation(
		parent: _flip,
		curve: Curves.easeInOut,
	);
	bool _removed = false;

	@override
	void initState() {
		super.initState();
		if (widget.removing) _startRemove();
	}

	@override
	void didUpdateWidget(covariant MemoryCardView oldWidget) {
		super.didUpdateWidget(oldWidget);
		if (widget.faceUp != oldWidget.faceUp) {
			if (widget.faceUp) {
				_flip.forward();
			} else {
				_flip.reverse();
			}
		}
		if (widget.removing && !oldWidget.removing) _startRemove();
	}

	void _startRemove() {
		_remove.forward().whenComplete(() {
			if (!mounted) return;
			setState(() => _removed = true);
			widget.onRemoved();
		});
	}

	@override
	void dispose() {
		_flip.dispose();
		_remove.dispose();
		super.dispose();
	}

	@override
	Widget build(BuildContext context) {
		if (_removed) return const SizedBox.expand();
		return Listener(
			behavior: HitTestBehavior.opaque,
			onPointerDown: (_) => widget.onTap(),
			child: RepaintBoundary(
				child: AnimatedBuilder(
					animation: Listenable.merge(<Listenable>[_flipCurve, _remove]),
					builder: (BuildContext context, Widget? _) {
						final double angle = _flipCurve.value * pi;
						final bool showFront = angle > pi / 2;
						final Widget face = showFront
								? Transform(
										alignment: Alignment.center,
										transform: Matrix4.rotationY(pi),
										child: _CardFront(
											image: widget.image,
											srcRect: widget.srcRect,
											borderColor: widget.backColor,
										),
									)
								: _CardBack(color: widget.backColor);
						Widget card = Transform(
							alignment: Alignment.center,
							transform: Matrix4.identity()
								..setEntry(3, 2, 0.0015)
								..multiply(Matrix4.rotationY(angle)),
							child: face,
						);
						final double t = _remove.value;
						if (t > 0) {
							card = Transform.rotate(
								angle: _removeRotation(t),
								child: Transform.scale(
									scale: _removeScale(t),
									child: Opacity(
										opacity: _removeOpacity(t),
										child: card,
									),
								),
							);
							return Stack(
								clipBehavior: Clip.none,
								fit: StackFit.expand,
								children: <Widget>[
									card,
									CustomPaint(
										painter: _SparklePainter(
											progress: t,
											seed: widget.srcRect.hashCode,
										),
									),
								],
							);
						}
						return card;
					},
				),
			),
		);
	}

	/// 前 25%：彈大到 1.15；之後縮到 0。
	static double _removeScale(double t) {
		if (t < 0.25) return 1 + 0.15 * Curves.easeOut.transform(t / 0.25);
		final double u = (t - 0.25) / 0.75;
		return 1.15 * (1 - Curves.easeInBack.transform(u).clamp(0.0, 1.0));
	}

	static double _removeRotation(double t) {
		if (t < 0.25) return 0;
		return Curves.easeIn.transform((t - 0.25) / 0.75) * pi * 0.5;
	}

	static double _removeOpacity(double t) {
		if (t < 0.6) return 1;
		return (1 - (t - 0.6) / 0.4).clamp(0.0, 1.0);
	}
}

class _CardBack extends StatelessWidget {
	const _CardBack({required this.color});

	final Color color;

	@override
	Widget build(BuildContext context) {
		final HSLColor hsl = HSLColor.fromColor(color);
		final Color darker = hsl
				.withLightness((hsl.lightness - 0.18).clamp(0.0, 1.0))
				.withSaturation((hsl.saturation + 0.1).clamp(0.0, 1.0))
				.toColor();
		return LayoutBuilder(
			builder: (BuildContext context, BoxConstraints c) {
				final double s = c.biggest.shortestSide;
				return DecoratedBox(
					decoration: BoxDecoration(
						borderRadius: BorderRadius.circular(s * 0.14),
						gradient: LinearGradient(
							begin: Alignment.topLeft,
							end: Alignment.bottomRight,
							colors: <Color>[color, darker],
						),
						border: Border.all(color: Colors.white, width: s * 0.045),
						boxShadow: const <BoxShadow>[
							BoxShadow(
								color: Color(0x33000000),
								blurRadius: 6,
								offset: Offset(0, 3),
							),
						],
					),
					child: Center(
						child: Icon(
							Icons.star_rounded,
							size: s * 0.5,
							color: Colors.white.withValues(alpha: 0.85),
						),
					),
				);
			},
		);
	}
}

class _CardFront extends StatelessWidget {
	const _CardFront({
		required this.image,
		required this.srcRect,
		required this.borderColor,
	});

	final ui.Image image;
	final Rect srcRect;
	final Color borderColor;

	@override
	Widget build(BuildContext context) {
		return LayoutBuilder(
			builder: (BuildContext context, BoxConstraints c) {
				final double s = c.biggest.shortestSide;
				return DecoratedBox(
					decoration: BoxDecoration(
						color: Colors.white,
						borderRadius: BorderRadius.circular(s * 0.14),
						border: Border.all(color: borderColor, width: s * 0.045),
						boxShadow: const <BoxShadow>[
							BoxShadow(
								color: Color(0x33000000),
								blurRadius: 6,
								offset: Offset(0, 3),
							),
						],
					),
					child: Padding(
						padding: EdgeInsets.all(s * 0.1),
						child: CustomPaint(
							size: Size.infinite,
							painter: _SpritePainter(image: image, srcRect: srcRect),
						),
					),
				);
			},
		);
	}
}

class _SpritePainter extends CustomPainter {
	_SpritePainter({required this.image, required this.srcRect});

	final ui.Image image;
	final Rect srcRect;

	@override
	void paint(Canvas canvas, Size size) {
		final double side = size.shortestSide;
		final Rect dst = Rect.fromCenter(
			center: size.center(Offset.zero),
			width: side,
			height: side,
		);
		canvas.drawImageRect(
			image,
			srcRect,
			dst,
			Paint()..filterQuality = FilterQuality.medium,
		);
	}

	@override
	bool shouldRepaint(covariant _SpritePainter oldDelegate) =>
			oldDelegate.image != image || oldDelegate.srcRect != srcRect;
}

/// 配對成功時從卡片中心向外噴的星星粒子。
class _SparklePainter extends CustomPainter {
	_SparklePainter({required this.progress, required this.seed});

	final double progress;
	final int seed;

	static const int _count = 14;
	static const List<Color> _colors = <Color>[
		Color(0xFFFFD54F),
		Color(0xFFFFFFFF),
		Color(0xFFFF8A80),
		Color(0xFF80D8FF),
		Color(0xFFB9F6CA),
	];

	@override
	void paint(Canvas canvas, Size size) {
		final Random r = Random(seed);
		final Offset center = size.center(Offset.zero);
		final double s = size.shortestSide;
		final double e = Curves.easeOutCubic.transform(progress);
		final double fade = progress < 0.5 ? 1 : (1 - (progress - 0.5) / 0.5);
		for (int i = 0; i < _count; i++) {
			final double angle =
					i / _count * 2 * pi + (r.nextDouble() - 0.5) * 0.5;
			final double reach = s * (0.45 + r.nextDouble() * 0.55);
			final double radius = s * (0.05 + r.nextDouble() * 0.05) * (1 - e * 0.6);
			final Offset p = center + Offset(cos(angle), sin(angle)) * (reach * e);
			final Paint paint = Paint()
				..color = _colors[i % _colors.length]
						.withValues(alpha: fade.clamp(0.0, 1.0));
			canvas.drawPath(_star(p, radius, progress * pi + i), paint);
		}
	}

	/// 四角星。
	static Path _star(Offset c, double r, double rotation) {
		final Path path = Path();
		for (int k = 0; k < 8; k++) {
			final double a = rotation + k * pi / 4;
			final double rr = k.isEven ? r : r * 0.38;
			final Offset p = c + Offset(cos(a), sin(a)) * rr;
			if (k == 0) {
				path.moveTo(p.dx, p.dy);
			} else {
				path.lineTo(p.dx, p.dy);
			}
		}
		return path..close();
	}

	@override
	bool shouldRepaint(covariant _SparklePainter oldDelegate) =>
			oldDelegate.progress != progress;
}
