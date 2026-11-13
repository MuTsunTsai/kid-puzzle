import "dart:math";

import "package:vector_math/vector_math.dart";

/// 從注視點指向眼睛的單位向量：正前方（+Z）往上抬 [pitchDeg] 度。
Vector3 cameraDirOf(double pitchDeg) {
	final double a = pitchDeg * degrees2Radians;
	return Vector3(0, sin(a), cos(a));
}

/// 取景結果：注視點、眼睛到注視點的距離，與場景（地面 + 最高動物頭頂）沿視線的深度範圍。
class CameraFit {
	const CameraFit({required this.target, required this.distance, required this.near, required this.far});

	final Vector3 target;
	final double distance;
	final double near;
	final double far;

	Vector3 eye(double pitchDeg) => target + cameraDirOf(pitchDeg) * distance;
}

/// 透視攝影機取景：把半徑 [groundRadius] 的圓形地面（加上動物可能站到的最外圈
/// 上方 [maxHeight] 高的頭頂）盡量放大塞進畫面。
///
/// 注視點沿攝影機的「上」方向平移（垂直於視線，只讓畫面上下移動、不改變遠近），
/// 距離用二分搜尋找「最近、仍放得下」的；距離一樣時挑上下留白最平均的。
/// ⚠ 不能沿地面前後（z）移：俯角小時那幾乎就是沿視線前後移，等於改變遠近。
///
/// [topRadius]：頭頂那一圈的半徑（動物中心離地面邊緣有預留量，頭再往外伸一點）。
/// [margin]：畫面邊緣保留的比例（1 = 地面剛好貼齊畫面邊緣）。
CameraFit fitCamera({
	required double pitchDeg,
	required double fovDeg,
	required double aspect,
	required double groundRadius,
	required double topRadius,
	required double maxHeight,
	required Vector3 baseTarget,
	double margin = 0.96,
}) {
	final Vector3 dir = cameraDirOf(pitchDeg).normalized();
	final Vector3 forward = -dir;
	final Vector3 right = Vector3(0, 1, 0).cross(forward)..normalize();
	final Vector3 up = forward.cross(right)..normalize();
	final double tanY = tan(fovDeg * degrees2Radians / 2) * margin;
	final double tanX = tanY * aspect;
	final double r = groundRadius;
	final double rTop = min(r, topRadius);
	final List<Vector3> pts = <Vector3>[
		for (int i = 0; i < 48; i++) ...<Vector3>[
			Vector3(cos(2 * pi * i / 48) * r, 0, sin(2 * pi * i / 48) * r),
			Vector3(cos(2 * pi * i / 48) * rTop, maxHeight, sin(2 * pi * i / 48) * rTop),
		],
	];
	bool fits(Vector3 t, double d) {
		final Vector3 eye = t + dir * d;
		for (final Vector3 p in pts) {
			final Vector3 v = p - eye;
			final double z = v.dot(forward);
			if (z < 0.5) return false;
			if (v.dot(right).abs() > tanX * z || v.dot(up).abs() > tanY * z) return false;
		}
		return true;
	}

	// 上下不對稱程度：最上緣與最下緣（視線斜率）的和，0 = 上下留白一樣
	double imbalance(Vector3 eye) {
		double lo = double.infinity, hi = -double.infinity;
		for (final Vector3 p in pts) {
			final Vector3 v = p - eye;
			final double y = v.dot(up) / v.dot(forward);
			lo = min(lo, y);
			hi = max(hi, y);
		}
		return (hi + lo).abs();
	}

	Vector3 bestT = baseTarget.clone();
	double bestD = double.infinity;
	double bestTilt = double.infinity;
	// 距離的搜尋上限跟著視角走（視角越窄要退越遠）
	final double maxD = 4 * (r + maxHeight) / min(tanX, tanY);
	void consider(Vector3 t) {
		double lo = 1, hi = maxD;
		if (!fits(t, hi)) return;
		for (int k = 0; k < 30; k++) {
			final double mid = (lo + hi) / 2;
			if (fits(t, mid)) {
				hi = mid;
			} else {
				lo = mid;
			}
		}
		final double tilt = imbalance(t + dir * hi);
		if (hi < bestD - 1e-3 || (hi < bestD + 1e-3 && tilt < bestTilt)) {
			bestD = min(bestD, hi);
			bestT = t;
			bestTilt = tilt;
		}
	}

	for (int i = -40; i <= 40; i++) {
		consider(baseTarget + up * (r * i / 40));
	}
	// 在最佳點附近再細找一次
	final Vector3 coarse = bestT;
	for (int i = -20; i <= 20; i++) {
		consider(coarse + up * (r * i / 800));
	}
	if (!bestD.isFinite) bestD = maxD;

	// 場景沿視線的深度範圍
	final Vector3 eye = bestT + dir * bestD;
	double zMin = double.infinity, zMax = -double.infinity;
	for (int i = 0; i < 64; i++) {
		final double a = 2 * pi * i / 64;
		for (final double y in <double>[0, maxHeight]) {
			final double z = (Vector3(cos(a) * r, y, sin(a) * r) - eye).dot(forward);
			zMin = min(zMin, z);
			zMax = max(zMax, z);
		}
	}
	return CameraFit(target: bestT, distance: bestD, near: max(0.1, zMin - 1), far: zMax + 1);
}
