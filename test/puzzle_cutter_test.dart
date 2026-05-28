import "dart:ui";

import "package:flutter_test/flutter_test.dart";
import "package:kid_puzzle/features/puzzle/domain/models/puzzle_edge.dart";
import "package:kid_puzzle/features/puzzle/domain/models/puzzle_layout.dart";
import "package:kid_puzzle/features/puzzle/domain/models/puzzle_piece.dart";
import "package:kid_puzzle/features/puzzle/domain/services/cell_planner.dart";
import "package:kid_puzzle/features/puzzle/domain/services/edge_shape.dart";
import "package:kid_puzzle/features/puzzle/domain/services/puzzle_cutter.dart";

const Size kBoardSize = Size(800, 600);
const double kPadding = 24;
final Rect kInnerBounds = Rect.fromLTWH(
	kPadding,
	kPadding,
	kBoardSize.width - 2 * kPadding,
	kBoardSize.height - 2 * kPadding,
);

/// 把 [Path] flatten 成多邊形採樣點，檢查邊兩兩相交。
///
/// 用 [Path.computeMetrics] 沿路徑均勻採樣（每 [samplePx] 一點）。
/// 相鄰邊跳過，首尾相連邊也跳過。
bool _pathHasSelfIntersection(Path path, {double samplePx = 4}) {
	final List<Offset> poly = <Offset>[];
	for (final PathMetric metric in path.computeMetrics()) {
		final int n = (metric.length / samplePx).ceil().clamp(8, 2000);
		for (int i = 0; i < n; i++) {
			final double d = metric.length * i / n;
			final Tangent? t = metric.getTangentForOffset(d);
			if (t != null) poly.add(t.position);
		}
	}
	final int n = poly.length;
	if (n < 4) return false;
	for (int i = 0; i < n; i++) {
		final Offset p1 = poly[i];
		final Offset p2 = poly[(i + 1) % n];
		for (int j = i + 2; j < n; j++) {
			if ((j + 1) % n == i) continue;
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

Future<PuzzleLayout> _cutWithGrid(int pieceCount, int seed,
		{EdgeShape edgeShape = kDefaultEdgeShape}) async {
	final CellLayout cellLayout = await const GridCellPlanner().plan(
		pieceCount: pieceCount,
		innerBounds: kInnerBounds,
		seed: seed,
	);
	return PuzzleCutter.cut(
		boardSize: kBoardSize,
		boardPadding: kPadding,
		cellLayout: cellLayout,
		seed: seed,
		edgeShape: edgeShape,
	);
}

void main() {
	group("PuzzleCutter", () {
		test("2~30 塊各 seed 5 次都能成功切割", () async {
			for (int pieceCount = 2; pieceCount <= 30; pieceCount++) {
				for (int seed = 0; seed < 5; seed++) {
					final PuzzleLayout layout = await _cutWithGrid(pieceCount, seed);
					expect(layout.pieces.length, pieceCount,
							reason: "塊數=$pieceCount, seed=$seed");
				}
			}
		});

		test("所有 polygonAabb 在拼圖盤 inner 區域內、無互相重疊", () async {
			for (int pieceCount = 2; pieceCount <= 30; pieceCount += 3) {
				for (int seed = 0; seed < 3; seed++) {
					final PuzzleLayout layout = await _cutWithGrid(pieceCount, seed);
					final double innerLeft = kPadding;
					final double innerTop = kPadding;
					final double innerRight = kBoardSize.width - kPadding;
					final double innerBottom = kBoardSize.height - kPadding;

					for (final PuzzlePiece p in layout.pieces) {
						expect(p.polygonAabb.left, greaterThanOrEqualTo(innerLeft - 1e-3));
						expect(p.polygonAabb.top, greaterThanOrEqualTo(innerTop - 1e-3));
						expect(p.polygonAabb.right, lessThanOrEqualTo(innerRight + 1e-3));
						expect(p.polygonAabb.bottom, lessThanOrEqualTo(innerBottom + 1e-3));
					}

					// 無重疊
					for (int i = 0; i < layout.pieces.length; i++) {
						for (int j = i + 1; j < layout.pieces.length; j++) {
							final Rect a = layout.pieces[i].polygonAabb;
							final Rect b = layout.pieces[j].polygonAabb;
							final Rect inter = a.intersect(b);
							if (inter.width > 1e-3 && inter.height > 1e-3) {
								fail("塊數=$pieceCount, seed=$seed: piece $i 與 $j AABB 重疊");
							}
						}
					}
				}
			}
		});

		test("localPath bounds 不超出 sourceRect（包含 baseline 曲線）", () async {
			for (int pieceCount = 2; pieceCount <= 30; pieceCount += 3) {
				for (int seed = 0; seed < 3; seed++) {
					final PuzzleLayout layout = await _cutWithGrid(pieceCount, seed);
					for (final PuzzlePiece p in layout.pieces) {
						final Rect bounds = p.localPath.getBounds();
						final String r = "n=$pieceCount seed=$seed piece ${p.id}";
						expect(bounds.left, greaterThanOrEqualTo(-1e-3), reason: r);
						expect(bounds.top, greaterThanOrEqualTo(-1e-3), reason: r);
						expect(bounds.right, lessThanOrEqualTo(p.sourceRect.width + 1e-3), reason: r);
						expect(bounds.bottom, lessThanOrEqualTo(p.sourceRect.height + 1e-3), reason: r);
					}
				}
			}
		});

		test("sourceRect 包含 polygonAabb（基本不變性）", () async {
			for (int pieceCount = 2; pieceCount <= 30; pieceCount += 3) {
				for (int seed = 0; seed < 3; seed++) {
					final PuzzleLayout layout = await _cutWithGrid(pieceCount, seed);
					for (final PuzzlePiece p in layout.pieces) {
						expect(p.sourceRect.left, lessThanOrEqualTo(p.polygonAabb.left + 1e-6));
						expect(p.sourceRect.top, lessThanOrEqualTo(p.polygonAabb.top + 1e-6));
						expect(p.sourceRect.right, greaterThanOrEqualTo(p.polygonAabb.right - 1e-6));
						expect(p.sourceRect.bottom, greaterThanOrEqualTo(p.polygonAabb.bottom - 1e-6));
					}
				}
			}
		});

		test("localPath 含其 polygonAabb 中心點", () async {
			final PuzzleLayout layout = await _cutWithGrid(9, 7);
			for (final PuzzlePiece p in layout.pieces) {
				// AABB 中心點轉成 localPath 座標（即 - sourceRect.topLeft）
				final Offset center = p.polygonAabb.center - p.sourceRect.topLeft;
				expect(p.localPath.contains(center), isTrue,
						reason: "piece ${p.id} localPath 應包含其中心點");
			}
		});

		test("自訂 EdgeShape 可改變耳尺寸，PuzzleLayout.tabSize 隨之變動", () async {
			final PuzzleLayout defaultLayout = await _cutWithGrid(6, 0);
			final PuzzleLayout fatLayout = await _cutWithGrid(6, 0,
					edgeShape: const ClassicTabShape(tabSizeRatio: 0.4));
			expect(fatLayout.tabSize, greaterThan(defaultLayout.tabSize));
		});

		test("誇張大耳朵也不會產生自交（自交修正流程介入）", () async {
			// 把 tabSizeRatio 拉到 0.6（正常 0.22），不修正必然自交。
			// AppDimens.maxTabProtrusionRatio 的上限會先壓一次，但對小片來說仍
			// 可能會穿幫；resolver 必須補上最後一道保險。
			const ClassicTabShape fat = ClassicTabShape(tabSizeRatio: 0.6);
			for (int pieceCount = 2; pieceCount <= 30; pieceCount += 3) {
				for (int seed = 0; seed < 3; seed++) {
					final PuzzleLayout layout = await _cutWithGrid(pieceCount, seed,
							edgeShape: fat);
					for (final PuzzlePiece p in layout.pieces) {
						expect(_pathHasSelfIntersection(p.localPath), isFalse,
								reason: "piece ${p.id} (pieceCount=$pieceCount, "
										"seed=$seed) localPath 不應自交");
					}
				}
			}
		});

		test("4 塊 2x2 每片至少有 2 條 flat 邊（兩條外圈）", () async {
			final PuzzleLayout layout = await _cutWithGrid(4, 0);
			for (final PuzzlePiece p in layout.pieces) {
				final int flatCount =
						p.edges.where((PuzzleEdge e) => e.type == EdgeType.flat).length;
				expect(flatCount, greaterThanOrEqualTo(2),
						reason: "4 塊 2x2 每片應該有 2 條外圈邊（兩條 flat）；piece ${p.id} 只有 $flatCount");
			}
		});

		test("Voronoi 多 seed 切割：塊數正確、localPath 不自交", () async {
			// Voronoi planner 會生 1.5N cell 再隨機合併到 N。
			// 用多 seed 驗證流程穩定；統計自交率、要求不超過 5%。
			const int trials = 8;
			int totalPieces = 0;
			int selfIntersectingPieces = 0;
			final List<String> failures = <String>[];
			for (int pieceCount = 4; pieceCount <= 16; pieceCount += 4) {
				for (int seed = 0; seed < trials; seed++) {
					final CellLayout cellLayout = await const VoronoiCellPlanner().plan(
						pieceCount: pieceCount,
						innerBounds: kInnerBounds,
						seed: seed,
					);
					final PuzzleLayout layout = await PuzzleCutter.cut(
						boardSize: kBoardSize,
						boardPadding: kPadding,
						cellLayout: cellLayout,
						seed: seed,
					);
					expect(layout.pieces.length, lessThanOrEqualTo(pieceCount),
							reason: "n=$pieceCount seed=$seed: piece 數超過目標");
					for (final PuzzlePiece p in layout.pieces) {
						totalPieces++;
						if (_pathHasSelfIntersection(p.localPath)) {
							selfIntersectingPieces++;
							failures.add("n=$pieceCount seed=$seed piece ${p.id}");
						}
					}
				}
			}
			final double rate = selfIntersectingPieces / totalPieces;
			expect(rate, lessThan(0.05),
					reason: "自交率太高: $selfIntersectingPieces/$totalPieces "
							"(${(rate * 100).toStringAsFixed(1)}%). cases: $failures");
		});

		test("validateLockability：每片至少有一條 flat 邊或一個 tab neighbor", () async {
			// Grid 切割：無不規則拓樸，理論上每片都應該 pass。
			for (int pieceCount = 2; pieceCount <= 30; pieceCount++) {
				for (int seed = 0; seed < 5; seed++) {
					final PuzzleLayout layout = await _cutWithGrid(pieceCount, seed);
					expect(
						PuzzleCutter.validateLockability(layout),
						isTrue,
						reason: "Grid n=$pieceCount seed=$seed 有片不可鎖定",
					);
				}
			}
		});

	});
}
