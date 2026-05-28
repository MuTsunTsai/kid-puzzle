// TriangleCellPlanner 輸出的「最大/最小拼片面積比」品質測試。
//
// 同一場切割中、最大拼片面積 / 最小拼片面積 越接近 1 越理想（拼片大小均勻、
// 玩家不會覺得有「特別小」或「特別大」的塊）；越大代表 cell 大小差異越懸殊。
//
// planner 內部用 `_validateAreaRatio` + retry 機制把 ratio > 5.5 的 layout
// 濾掉，所以正常運作下這支測試應該看到所有 case ratio ≤ 5.5；非如此代表
// retry 機制壞了或某些 case 連 20 次 retry 都救不回來、值得進一步檢查。
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

/// 多邊形絕對面積（shoelace）。
double _polygonArea(List<Offset> poly) {
	final int n = poly.length;
	if (n < 3) return 0;
	double s = 0;
	for (int i = 0; i < n; i++) {
		final Offset a = poly[i];
		final Offset b = poly[(i + 1) % n];
		s += a.dx * b.dy - b.dx * a.dy;
	}
	return s.abs() / 2;
}

({double mean, double stdev}) _meanStdev(List<double> xs) {
	if (xs.isEmpty) return (mean: 0, stdev: 0);
	double sum = 0;
	for (final double x in xs) {
		sum += x;
	}
	final double mean = sum / xs.length;
	double sq = 0;
	for (final double x in xs) {
		final double d = x - mean;
		sq += d * d;
	}
	final double stdev = sqrt(sq / xs.length);
	return (mean: mean, stdev: stdev);
}

void main() {
	test("TriangleCellPlanner：max/min cell 面積比統計", () async {
		const int seedCount = 100;
		const TriangleCellPlanner planner = TriangleCellPlanner();

		// 每組 (n, seed) 算一個 max/min 比值；分別記錄每個 n 的樣本
		final Map<int, List<double>> ratiosByN = <int, List<double>>{};
		final List<double> allRatios = <double>[];
		// 記錄最差 5 個 case
		final List<({int n, int seed, double ratio})> worst =
				<({int n, int seed, double ratio})>[];

		for (int n = 2; n <= 30; n++) {
			final List<double> samples = <double>[];
			for (int seed = 0; seed < seedCount; seed++) {
				final CellLayout layout = await planner.plan(
					pieceCount: n,
					innerBounds: _kInnerBounds,
					seed: seed,
				);
				double minA = double.infinity;
				double maxA = -double.infinity;
				for (final CellPolygon cell in layout.cells) {
					final double a = _polygonArea(cell.vertices);
					if (a <= 0) continue;
					if (a < minA) minA = a;
					if (a > maxA) maxA = a;
				}
				if (minA <= 0 || !minA.isFinite || !maxA.isFinite) continue;
				final double ratio = maxA / minA;
				samples.add(ratio);
				allRatios.add(ratio);
				worst.add((n: n, seed: seed, ratio: ratio));
			}
			ratiosByN[n] = samples;
		}

		worst.sort((a, b) => b.ratio.compareTo(a.ratio));
		final List<({int n, int seed, double ratio})> top5 = worst.take(5).toList();

		final ({double mean, double stdev}) overall = _meanStdev(allRatios);

		// ignore: avoid_print
		print("=== Triangle planner max/min 面積比統計 "
				"(seed=0..${seedCount - 1}, n=2..30) ===");
		// ignore: avoid_print
		print("overall: samples=${allRatios.length} "
				"mean=${overall.mean.toStringAsFixed(2)} "
				"stdev=${overall.stdev.toStringAsFixed(2)}");
		// ignore: avoid_print
		print("by-pieceCount (mean ± stdev, min..max):");
		for (int n = 2; n <= 30; n++) {
			final List<double>? xs = ratiosByN[n];
			if (xs == null || xs.isEmpty) continue;
			final ({double mean, double stdev}) s = _meanStdev(xs);
			double mn = xs.first;
			double mx = xs.first;
			for (final double x in xs) {
				if (x < mn) mn = x;
				if (x > mx) mx = x;
			}
			// ignore: avoid_print
			print("  n=$n: ${s.mean.toStringAsFixed(2)} ± "
					"${s.stdev.toStringAsFixed(2)}  "
					"(${mn.toStringAsFixed(2)}..${mx.toStringAsFixed(2)})");
		}
		// 累積分布：ratio ≤ T 的樣本占比
		// ignore: avoid_print
		print("cumulative coverage:");
		for (int t = 2; t <= 15; t++) {
			int below = 0;
			for (final double r in allRatios) {
				if (r <= t) below++;
			}
			final double pct = 100.0 * below / allRatios.length;
			// ignore: avoid_print
			print("  ratio ≤ $t: ${pct.toStringAsFixed(2)}%");
		}

		// 累積分布：ratio ≤ T 的樣本占比（從 5 開始、0.5 間隔）
		// ignore: avoid_print
		print("cumulative coverage:");
		for (double t = 5.0; t <= 10.0; t += 0.5) {
			int below = 0;
			for (final double r in allRatios) {
				if (r <= t) below++;
			}
			final double pct = 100.0 * below / allRatios.length;
			final double retryPct = 100.0 - pct;
			// ignore: avoid_print
			print("  ratio ≤ ${t.toStringAsFixed(1)}: "
					"${pct.toStringAsFixed(2)}% "
					"(retry ${retryPct.toStringAsFixed(2)}%)");
		}

		// ignore: avoid_print
		print("worst 5 cases:");
		for (final c in top5) {
			// ignore: avoid_print
			print("  n=${c.n} seed=${c.seed} ratio=${c.ratio.toStringAsFixed(2)}");
		}

		// planner 的 retry 機制應該把 ratio > _maxAreaRatio (7.5) 的 layout 濾掉。
		expect(allRatios.length, greaterThan(0));
		final double maxRatio = allRatios.reduce((a, b) => a > b ? a : b);
		expect(maxRatio, lessThanOrEqualTo(7.5),
				reason: "planner 應透過 retry 把 max/min 面積比壓在 7.5 以下；"
						"看到更高的值表示 retry 機制可能失效");
	}, timeout: const Timeout(Duration(minutes: 5)));
}
