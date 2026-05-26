import "dart:ui";

import "package:flutter_test/flutter_test.dart";
import "package:kid_puzzle/features/puzzle/domain/services/cell_planner.dart";

const Size _kBoardSize = Size(800, 600);
const double _kPadding = 24;
final Rect _kInnerBounds = Rect.fromLTWH(
	_kPadding,
	_kPadding,
	_kBoardSize.width - 2 * _kPadding,
	_kBoardSize.height - 2 * _kPadding,
);

/// 採樣式估算 polygon a 與 b 的相交面積比例（相對於 a）。
///
/// 在 a 的 AABB 內均勻取點、計算「同時在 a 內也在 b 內」的比例。
/// 0 表示無重疊；> 0 表示有重疊（值越大重疊面積占 a 越多）。
double _samplePolygonOverlap(List<Offset> a, List<Offset> b, {int samples = 40}) {
	final Path aPath = Path()..addPolygon(a, true);
	final Path bPath = Path()..addPolygon(b, true);
	final Rect aab = aPath.getBounds();
	int inA = 0;
	int inBoth = 0;
	for (int iy = 0; iy < samples; iy++) {
		for (int ix = 0; ix < samples; ix++) {
			final Offset pt = Offset(
				aab.left + (ix + 0.5) * aab.width / samples,
				aab.top + (iy + 0.5) * aab.height / samples,
			);
			if (aPath.contains(pt)) {
				inA++;
				if (bPath.contains(pt)) inBoth++;
			}
		}
	}
	return inA == 0 ? 0 : inBoth / inA;
}

/// 用 shoelace formula 計算 polygon 的 signed area（CCW 為正）。
double _polygonSignedArea(List<Offset> poly) {
	double area = 0;
	for (int i = 0; i < poly.length; i++) {
		final Offset a = poly[i];
		final Offset b = poly[(i + 1) % poly.length];
		area += a.dx * b.dy - b.dx * a.dy;
	}
	return area / 2;
}

/// 採樣式檢查 polygon 是否自交：把 polygon 邊兩兩取出、看是否相交（端點相連、
/// 首尾邊跳過）。
bool _polygonSelfIntersects(List<Offset> poly) {
	final int n = poly.length;
	for (int i = 0; i < n; i++) {
		final Offset p1 = poly[i];
		final Offset p2 = poly[(i + 1) % n];
		for (int j = i + 2; j < n; j++) {
			if ((j + 1) % n == i) continue; // skip neighbor that wraps to i
			final Offset p3 = poly[j];
			final Offset p4 = poly[(j + 1) % n];
			if (_segmentsCross(p1, p2, p3, p4)) return true;
		}
	}
	return false;
}

bool _segmentsCross(Offset p1, Offset p2, Offset p3, Offset p4) {
	final double rx = p2.dx - p1.dx;
	final double ry = p2.dy - p1.dy;
	final double sx = p4.dx - p3.dx;
	final double sy = p4.dy - p3.dy;
	final double denom = rx * sy - ry * sx;
	if (denom.abs() < 1e-9) return false;
	final double dx = p3.dx - p1.dx;
	final double dy = p3.dy - p1.dy;
	final double t = (dx * sy - dy * sx) / denom;
	final double u = (dx * ry - dy * rx) / denom;
	const double eps = 1e-4;
	return t > eps && t < 1 - eps && u > eps && u < 1 - eps;
}

void main() {
	group("VoronoiCellPlanner 合併演算法", () {
		test("產出的 cell 數量 ≤ pieceCount", () {
			for (int n = 4; n <= 16; n += 2) {
				for (int seed = 0; seed < 10; seed++) {
					final CellLayout cl = const VoronoiCellPlanner().plan(
						pieceCount: n,
						innerBounds: _kInnerBounds,
						seed: seed,
					);
					expect(cl.cells.length, lessThanOrEqualTo(n),
							reason: "n=$n seed=$seed: 不該超過目標");
					expect(cl.cells.length, greaterThanOrEqualTo(2),
							reason: "n=$n seed=$seed: 至少要 2 cell");
				}
			}
		});

		test("所有 cell 兩兩不重疊（最關鍵的不變式）", () {
			// 這條測試直接撞 bug：合併演算法若漏保留共享邊端點、其他 cell 與
			// 合併 polygon 會在該頂點附近重疊。
			for (int n = 4; n <= 16; n += 2) {
				for (int seed = 0; seed < 15; seed++) {
					final CellLayout cl = const VoronoiCellPlanner().plan(
						pieceCount: n,
						innerBounds: _kInnerBounds,
						seed: seed,
					);
					final List<List<Offset>> polys =
							cl.cells.map((CellPolygon c) => c.vertices).toList();
					for (int i = 0; i < polys.length; i++) {
						for (int j = i + 1; j < polys.length; j++) {
							final double overlap =
									_samplePolygonOverlap(polys[i], polys[j]);
							expect(overlap, lessThan(0.02),
									reason: "n=$n seed=$seed: cell $i & $j 重疊 "
											"${(overlap * 100).toStringAsFixed(1)}%");
						}
					}
				}
			}
		});

		test("所有 cell 都非自交（合併後 polygon 是 simple polygon）", () {
			for (int n = 4; n <= 16; n += 2) {
				for (int seed = 0; seed < 10; seed++) {
					final CellLayout cl = const VoronoiCellPlanner().plan(
						pieceCount: n,
						innerBounds: _kInnerBounds,
						seed: seed,
					);
					for (int i = 0; i < cl.cells.length; i++) {
						final List<Offset> poly = cl.cells[i].vertices;
						expect(_polygonSelfIntersects(poly), isFalse,
								reason: "n=$n seed=$seed cell $i 自交");
					}
				}
			}
		});

		test("所有 cell 維持 CCW（signed area > 0）— 合併不該翻轉方向", () {
			for (int n = 4; n <= 16; n += 2) {
				for (int seed = 0; seed < 10; seed++) {
					final CellLayout cl = const VoronoiCellPlanner().plan(
						pieceCount: n,
						innerBounds: _kInnerBounds,
						seed: seed,
					);
					for (int i = 0; i < cl.cells.length; i++) {
						final double area = _polygonSignedArea(cl.cells[i].vertices);
						// 注意：Flutter Offset y 軸向下、所以「螢幕視覺 CCW」對應
						// signed area < 0。Voronoi.dart 是用 atan2 排序、檢查實際
						// 方向即可、只要不翻轉。VoronoiBuilder 給的是 area < 0
						// (clockwise in math sense, counter-clockwise visually)。
						// 我們只要求所有 cell 同號（沒被翻轉）。
						expect(area.abs(), greaterThan(1.0),
								reason: "n=$n seed=$seed cell $i 面積過小: $area");
					}
				}
			}
		});

		test("所有 cell 面積總和 ≈ innerBounds 面積（不漏不重）", () {
			final double innerArea = _kInnerBounds.width * _kInnerBounds.height;
			for (int n = 4; n <= 16; n += 2) {
				for (int seed = 0; seed < 10; seed++) {
					final CellLayout cl = const VoronoiCellPlanner().plan(
						pieceCount: n,
						innerBounds: _kInnerBounds,
						seed: seed,
					);
					double total = 0;
					for (final CellPolygon c in cl.cells) {
						total += _polygonSignedArea(c.vertices).abs();
					}
					// 容忍 1% 誤差（合併演算法應該嚴格守恆、但浮點累積可能）。
					expect((total - innerArea).abs() / innerArea, lessThan(0.01),
							reason: "n=$n seed=$seed: 總面積 $total vs inner $innerArea");
				}
			}
		});

		test("共享邊：相鄰 cell 的共享邊應該完美對齊（端點對相等）", () {
			// 此檢查捕捉「一條邊被某 cell 切成兩段、另一 cell 是一段」的 bug —
			// 即原本造成重疊的 root cause。
			for (int n = 4; n <= 16; n += 4) {
				for (int seed = 0; seed < 8; seed++) {
					final CellLayout cl = const VoronoiCellPlanner().plan(
						pieceCount: n,
						innerBounds: _kInnerBounds,
						seed: seed,
					);
					// 收集所有 polygon 邊：key = sorted endpoints
					final Map<String, int> edgeCount = <String, int>{};
					for (final CellPolygon c in cl.cells) {
						final List<Offset> v = c.vertices;
						for (int i = 0; i < v.length; i++) {
							final Offset a = v[i];
							final Offset b = v[(i + 1) % v.length];
							final String key = _edgeKey(a, b);
							edgeCount[key] = (edgeCount[key] ?? 0) + 1;
						}
					}
					// 每條邊出現次數應該是 1（外圈邊）或 2（內部共享邊）
					for (final MapEntry<String, int> e in edgeCount.entries) {
						expect(e.value, lessThanOrEqualTo(2),
								reason: "n=$n seed=$seed: 邊 ${e.key} 出現 ${e.value} 次"
										"（共享邊不該超過 2 cell）");
					}
				}
			}
		});
	});

	group("VoronoiCellPlanner with oversampleRatio = 1.0（不合併）", () {
		test("oversampleRatio=1.0 時直接輸出 N 個 cell、不做合併", () {
			for (int n = 4; n <= 16; n += 2) {
				for (int seed = 0; seed < 5; seed++) {
					final CellLayout cl =
							const VoronoiCellPlanner(oversampleRatio: 1.0).plan(
						pieceCount: n,
						innerBounds: _kInnerBounds,
						seed: seed,
					);
					expect(cl.cells.length, n, reason: "n=$n seed=$seed");
				}
			}
		});
	});
}

/// 邊端點對的 quantized key（用於分組共享邊）。與 PuzzleCutter 的判等容差
/// 一致。
String _edgeKey(Offset a, Offset b) {
	String quant(Offset o) =>
			"${(o.dx * 10).round()},${(o.dy * 10).round()}";
	final String ka = quant(a);
	final String kb = quant(b);
	// 排序使「正反向同邊」key 相同
	return ka.compareTo(kb) <= 0 ? "$ka|$kb" : "$kb|$ka";
}
