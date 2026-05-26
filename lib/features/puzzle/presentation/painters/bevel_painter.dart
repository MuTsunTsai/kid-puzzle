import "dart:math";
import "dart:ui" as ui;

import "package:flutter/material.dart";

/// 立體 bevel 效果繪製工具。
///
/// 沿 path 採樣多個點，依該點的「外法線方向」與「虛擬光源方向」的夾角，
/// 對該位置塗上對應的高光 / 陰影顏色，模擬被某個方向光源照射的立體感。
///
/// 提供兩種風格（名稱與直覺相反，以實際視覺效果為準）：
/// - [drawInnerBevel]：凹槽風格（左上暗、右下亮）
/// - [drawInnerGroove]：凸起塊風格（左上亮、右下暗）
///
/// 法線是「指向 path 外側」的單位向量；外側由 path 的 winding 決定，
/// 對封閉的順時針 path（Flutter 預設 + 我們的 puzzle_cutter 輸出皆是），
/// 切線旋轉 -90° = 法線朝外。
class BevelPainter {
	BevelPainter._();

	/// 預設 bevel 線寬。
	static const double defaultStrokeWidth = 6.0;

	/// 預設高光顏色透明度（亮度方向取到極大值時）。
	static const double defaultHighlightAlpha = 0.1;

	/// 預設陰影顏色透明度（亮度方向取到極小值時）。
	static const double defaultShadowAlpha = 0.05;

	/// 採樣間距（pixel）；越小越平滑、越大越快。
	static const double sampleStep = 3.0;

	/// 凹槽風格：模擬「邊框內凹」效果。內側看：左上暗、右下亮。
	///
	/// 呼叫前 canvas 必須先 clipPath 到 [path]，因為 stroke 會稍微出界。
	static void drawInnerBevel(
		Canvas canvas,
		Path path, {
		double strokeWidth = defaultStrokeWidth,
		double highlightAlpha = defaultHighlightAlpha,
		double shadowAlpha = defaultShadowAlpha,
	}) {
		_drawShadedAlongPath(
			canvas: canvas,
			path: path,
			lightDirection: const Offset(1, 1),
			strokeWidth: strokeWidth,
			highlightAlpha: highlightAlpha,
			shadowAlpha: shadowAlpha,
		);
	}

	/// 凸起塊風格：模擬「拼片浮起」效果。內側看：左上亮、右下暗。
	///
	/// 呼叫前 canvas 必須先 clipPath 到 [path]。
	static void drawInnerGroove(
		Canvas canvas,
		Path path, {
		double strokeWidth = defaultStrokeWidth,
		double highlightAlpha = defaultHighlightAlpha,
		double shadowAlpha = defaultShadowAlpha,
	}) {
		_drawShadedAlongPath(
			canvas: canvas,
			path: path,
			lightDirection: const Offset(-1, -1),
			strokeWidth: strokeWidth,
			highlightAlpha: highlightAlpha,
			shadowAlpha: shadowAlpha,
		);
	}

	/// 沿 [path] 採樣、依「外法線與 [lightDirection] 的點積」決定每段顏色。
	///
	/// 點積 = cos(夾角)：
	/// - +1（法線與光源同向）→ 該段「面對光」→ 高光（白色 + highlightAlpha）
	/// - -1（法線與光源反向）→ 該段「背對光」→ 陰影（黑色 + shadowAlpha）
	/// - 0（垂直）→ 中性無色（透明）
	///
	/// 採樣以 [sampleStep] 為間距。每段用 [Canvas.drawLine] 畫、線寬重疊保證
	/// 銜接處沒有縫隙。
	static void _drawShadedAlongPath({
		required Canvas canvas,
		required Path path,
		required Offset lightDirection,
		required double strokeWidth,
		required double highlightAlpha,
		required double shadowAlpha,
	}) {
		final Offset lightDir = _normalize(lightDirection);
		final Paint paint = Paint()
			..style = PaintingStyle.stroke
			..strokeWidth = strokeWidth
			..strokeCap = StrokeCap.round
			..strokeJoin = StrokeJoin.round;

		for (final ui.PathMetric metric in path.computeMetrics()) {
			final double total = metric.length;
			if (total < 1e-3) continue;

			// 依採樣間距走 path，每段取 (起點切線、終點切線) 平均作為該段法線基準
			double t = 0;
			final ui.Tangent? firstTangent = metric.getTangentForOffset(0);
			if (firstTangent == null) continue;
			ui.Tangent prevTangent = firstTangent;

			while (t < total) {
				final double nextT = (t + sampleStep).clamp(0.0, total);
				final ui.Tangent? nextTangentNullable = metric.getTangentForOffset(nextT);
				if (nextTangentNullable == null) break;
				final ui.Tangent nextTangent = nextTangentNullable;

				// 該段中點法線：用兩端切線的平均
				final Offset midTangent = _normalize(
					Offset(
						(prevTangent.vector.dx + nextTangent.vector.dx) / 2,
						(prevTangent.vector.dy + nextTangent.vector.dy) / 2,
					),
				);
				// 對順時針 path，切線旋轉 -90° 得到外法線
				// (vx, vy) → 旋轉 -90° → (vy, -vx)
				final Offset outwardNormal = Offset(midTangent.dy, -midTangent.dx);

				// 點積：法線越朝向光源越亮
				final double dot = (outwardNormal.dx * lightDir.dx +
						outwardNormal.dy * lightDir.dy).clamp(-1.0, 1.0);

				// 依 dot 決定顏色
				final Color? segColor = _colorForDot(
					dot,
					highlightAlpha: highlightAlpha,
					shadowAlpha: shadowAlpha,
				);

				if (segColor != null) {
					paint.color = segColor;
					canvas.drawLine(prevTangent.position, nextTangent.position, paint);
				}

				prevTangent = nextTangent;
				if (nextT >= total) break;
				t = nextT;
			}
		}
	}

	/// 把 dot ∈ [-1, 1] 對應到顏色：
	/// - dot >= 0：朝向光源 → 白色，alpha 由 0 線性增至 highlightAlpha
	/// - dot <  0：背對光源 → 黑色，alpha 由 0 線性增至 shadowAlpha
	/// 接近 0 時回傳 null 表示透明（不畫）。
	static Color? _colorForDot(
		double dot, {
		required double highlightAlpha,
		required double shadowAlpha,
	}) {
		// 邊界附近（|dot| < 一定值）視為中性，不畫，避免畫一堆透明線段
		const double deadZone = 0.05;
		if (dot.abs() < deadZone) return null;

		if (dot > 0) {
			// 用 sin 過渡比線性更柔（[0,1] 映射到 [0,1]，曲線 = sin(x * pi/2)）
			final double t = sin(dot * pi / 2);
			return Colors.white.withValues(alpha: t * highlightAlpha);
		} else {
			final double t = sin(-dot * pi / 2);
			return Colors.black.withValues(alpha: t * shadowAlpha);
		}
	}

	static Offset _normalize(Offset v) {
		final double len = v.distance;
		if (len < 1e-9) return Offset.zero;
		return Offset(v.dx / len, v.dy / len);
	}

	/// 把 piece 的「圖案 + 光影」預先合成為 [Image] 給 painter 快取重用。
	///
	/// 流程：
	/// 1. 用 [path] clip 出 piece 形狀
	/// 2. 用 [sourceImage] 對應的 [srcRectInImage] 把原圖區域畫進來（拼塊圖案）
	/// 3. 疊上立體光澤（bevel / groove）
	///
	/// **不畫邊框**：邊框 stroke 由呼叫端在繪製階段以向量畫，避免兩片相鄰的
	/// bitmap 在共享邊上各自的 antialias 羽化帶留下細縫。
	///
	/// 回傳的 image 與 [path] 的 bounding box 對齊：原點 (0, 0) = path bounds 左上角。
	/// 呼叫端用 `canvas.drawImage(img, drawPos, ...)` 即可。
	///
	/// 此函式用 [Picture.toImageSync] 同步生成 bitmap，不會阻塞 IO 但有
	/// rasterize CPU 成本；建議在 piece 第一次繪製時呼叫一次、快取。
	static ui.Image rasterizePieceWithBevel({
		required Path path,
		required Size pieceSize,
		required ui.Image sourceImage,
		required Rect srcRectInImage,
		required BevelStyle style,
		required double devicePixelRatio,
		double strokeWidth = defaultStrokeWidth,
		double highlightAlpha = defaultHighlightAlpha,
		double shadowAlpha = defaultShadowAlpha,
	}) {
		// 注意：bitmap 尺寸用呼叫端給的 [pieceSize]（= piece.sourceRect.width/height），
		// 不是 path.getBounds()。baseline 曲線可能讓 path bounds 略小於 sourceRect
		// （朝內凹的邊），用 bounds 會造成 bitmap 與 sourceRect 不對齊、框線與
		// 圖案錯位。
		final double dpr = devicePixelRatio;
		// bitmap 尺寸用「邏輯尺寸 × dpr」放大，畫到畫面時 painter 用 drawImageRect
		// 還原邏輯尺寸；GPU 把高解析度 bitmap 縮回 1:1 物理像素，鋸齒會明顯減少。
		final int wPx = (pieceSize.width * dpr).ceil();
		final int hPx = (pieceSize.height * dpr).ceil();

		final ui.PictureRecorder recorder = ui.PictureRecorder();
		final Canvas canvas = Canvas(
			recorder,
			Rect.fromLTWH(0, 0, wPx.toDouble(), hPx.toDouble()),
		);
		// 整體 scale dpr 之後，畫的時候仍用邏輯尺寸座標
		canvas.scale(dpr);
		canvas.clipPath(path);

		// 1. 拼塊圖案：把原圖對應區塊畫到 bitmap 上（dst 與 sourceRect 對齊）
		//    用 medium filter quality（bilinear + mipmap），避免 nearest 取樣的鋸齒。
		canvas.drawImageRect(
			sourceImage,
			srcRectInImage,
			Rect.fromLTWH(0, 0, pieceSize.width, pieceSize.height),
			Paint()..filterQuality = FilterQuality.medium,
		);

		// 2. 光澤
		switch (style) {
			case BevelStyle.bevel:
				drawInnerBevel(
					canvas,
					path,
					strokeWidth: strokeWidth,
					highlightAlpha: highlightAlpha,
					shadowAlpha: shadowAlpha,
				);
				break;
			case BevelStyle.groove:
				drawInnerGroove(
					canvas,
					path,
					strokeWidth: strokeWidth,
					highlightAlpha: highlightAlpha,
					shadowAlpha: shadowAlpha,
				);
				break;
		}

		final ui.Picture picture = recorder.endRecording();
		final ui.Image image = picture.toImageSync(wPx, hPx);
		picture.dispose();
		return image;
	}
}

/// bevel 風格選項，給 [BevelPainter.rasterize] 用。
enum BevelStyle {
	bevel,
	groove,
}
