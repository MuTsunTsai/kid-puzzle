// TriangleCellPlanner 輸出品質測試。
//
// 「尖角」定義：cell polygon 上有任一頂點的內角 < 30°。
// 過於尖銳的角會讓拼片視覺上像針一樣突出、玩家難以辨識與抓取。
//
// planner 內部用 `_validateNoSharpAngle` + retry 機制把這類 cell 濾掉，
// 所以正常運作下這支測試應該得到 0 個尖角 cell；非 0 代表 retry 機制壞了
// 或某些 case 連 20 次 retry 都救不回來、值得進一步檢查。
import "dart:math";
import "dart:ui";

import "package:flutter_test/flutter_test.dart";
import "package:kid_puzzle/features/puzzle/domain/services/cell_planner.dart";
import "package:kid_puzzle/features/puzzle/domain/services/triangle_planner.dart";

const Size _kBoardSize = Size(800, 600);
const double _kPadding = 24;
final Rect _kInnerBounds = Rect.fromLTWH(
	_kPadding,
	_kPadding,
	_kBoardSize.width - 2 * _kPadding,
	_kBoardSize.height - 2 * _kPadding,
);

/// 內角（度數）。與 triangle_planner._vertexAngleDeg 同公式。
double _vertexAngleDeg(Offset vertex, Offset a, Offset b) {
	final Offset toA = a - vertex;
	final Offset toB = b - vertex;
	final double dot = toA.dx * toB.dx + toA.dy * toB.dy;
	final double magA = sqrt(toA.dx * toA.dx + toA.dy * toA.dy);
	final double magB = sqrt(toB.dx * toB.dx + toB.dy * toB.dy);
	if (magA < 1e-9 || magB < 1e-9) return 180.0;
	double c = dot / (magA * magB);
	if (c > 1) c = 1;
	if (c < -1) c = -1;
	return acos(c) * 180 / pi;
}

/// 回傳 polygon 上的最小內角（度）。
double _minInteriorAngleDeg(List<Offset> poly) {
	final int n = poly.length;
	if (n < 3) return 180.0;
	double minA = 180.0;
	for (int i = 0; i < n; i++) {
		final Offset prev = poly[(i - 1 + n) % n];
		final Offset v = poly[i];
		final Offset next = poly[(i + 1) % n];
		final double a = _vertexAngleDeg(v, prev, next);
		if (a < minA) minA = a;
	}
	return minA;
}

void main() {
	test("TriangleCellPlanner：尖角（< 30°）出現機率統計", () {
		const double sharpThresholdDeg = 30.0;
		// 涵蓋實際使用的塊數範圍與多 seed、樣本要夠大才有意義
		const int seedCount = 100;
		const TriangleCellPlanner planner = TriangleCellPlanner();

		int totalCells = 0;
		int sharpCells = 0;
		final Map<int, int> sharpByPieceCount = <int, int>{};
		final Map<int, int> totalByPieceCount = <int, int>{};
		// 記錄最尖的 5 個 case 方便日後 debug
		final List<({int n, int seed, double minAngle})> worst =
				<({int n, int seed, double minAngle})>[];

		for (int n = 2; n <= 30; n++) {
			for (int seed = 0; seed < seedCount; seed++) {
				final CellLayout layout = planner.plan(
					pieceCount: n,
					innerBounds: _kInnerBounds,
					seed: seed,
				);
				for (final CellPolygon cell in layout.cells) {
					totalCells++;
					totalByPieceCount[n] = (totalByPieceCount[n] ?? 0) + 1;
					final double minAngle = _minInteriorAngleDeg(cell.vertices);
					if (minAngle < sharpThresholdDeg) {
						sharpCells++;
						sharpByPieceCount[n] = (sharpByPieceCount[n] ?? 0) + 1;
						worst.add((n: n, seed: seed, minAngle: minAngle));
					}
				}
			}
		}

		worst.sort((a, b) => a.minAngle.compareTo(b.minAngle));
		final List<({int n, int seed, double minAngle})> top5 = worst.take(5).toList();

		final double overallRate = totalCells == 0
				? 0.0
				: 100.0 * sharpCells / totalCells;

		// ignore: avoid_print
		print("=== Triangle planner 尖角統計 (threshold < $sharpThresholdDeg°) ===");
		// ignore: avoid_print
		print("cells: total=$totalCells sharp=$sharpCells "
				"rate=${overallRate.toStringAsFixed(2)}%");
		// 列出每個塊數的尖角率
		// ignore: avoid_print
		print("by-pieceCount:");
		for (int n = 2; n <= 30; n++) {
			final int total = totalByPieceCount[n] ?? 0;
			final int sharp = sharpByPieceCount[n] ?? 0;
			if (total == 0) continue;
			final double rate = 100.0 * sharp / total;
			// ignore: avoid_print
			print("  n=$n: $sharp/$total (${rate.toStringAsFixed(2)}%)");
		}
		// ignore: avoid_print
		print("worst 5 cases:");
		for (final c in top5) {
			// ignore: avoid_print
			print("  n=${c.n} seed=${c.seed} minAngle=${c.minAngle.toStringAsFixed(2)}°");
		}

		// planner 的 retry 機制應該把所有尖角 cell 濾掉。
		expect(totalCells, greaterThan(0));
		expect(sharpCells, 0,
				reason: "planner 應透過 retry 完全濾掉尖角 cell；"
						"看到非 0 表示 retry 機制可能失效");
	});
}
