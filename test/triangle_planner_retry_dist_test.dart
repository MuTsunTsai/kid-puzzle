// TriangleCellPlanner 內部 retry 次數分布。
//
// 一次 plan() 可能因為三個品質條件之一觸發 retry（腰太細 / 尖角 / 面積比）。
// 統計每次 plan 實際 retry 了幾次，給「retry 機制負擔有多大」一個基準。
import "dart:ui";

import "package:flutter_test/flutter_test.dart";
import "package:kid_puzzle/features/puzzle/domain/services/triangle_planner.dart";

const Size _kBoardSize = Size(800, 600);
const double _kPadding = 24;
final Rect _kInnerBounds = Rect.fromLTWH(
	_kPadding,
	_kPadding,
	_kBoardSize.width - 2 * _kPadding,
	_kBoardSize.height - 2 * _kPadding,
);

void main() {
	test("TriangleCellPlanner：retry 次數分布", () {
		const int seedCount = 200;
		const TriangleCellPlanner planner = TriangleCellPlanner();

		int total = 0;
		int needRetry = 0;
		int maxRetry = 0;
		final Map<int, int> dist = <int, int>{};
		final List<({int n, int seed, int retries})> heavy =
				<({int n, int seed, int retries})>[];

		for (int n = 2; n <= 30; n++) {
			for (int seed = 0; seed < seedCount; seed++) {
				planner.plan(
					pieceCount: n,
					innerBounds: _kInnerBounds,
					seed: seed,
				);
				final int r = TriangleCellPlanner.debugLastRetryCount;
				total++;
				if (r > 0) needRetry++;
				if (r > maxRetry) maxRetry = r;
				dist[r] = (dist[r] ?? 0) + 1;
				if (r >= 3) heavy.add((n: n, seed: seed, retries: r));
			}
		}

		final double retryPct = 100.0 * needRetry / total;

		// ignore: avoid_print
		print("=== Triangle planner retry 次數分布 "
				"(seed=0..${seedCount - 1}, n=2..30) ===");
		// ignore: avoid_print
		print("total plans=$total, "
				"need-retry=$needRetry (${retryPct.toStringAsFixed(2)}%), "
				"maxRetry=$maxRetry");
		// ignore: avoid_print
		print("distribution:");
		final List<int> keys = dist.keys.toList()..sort();
		for (final int k in keys) {
			final int c = dist[k]!;
			final double pct = 100.0 * c / total;
			// ignore: avoid_print
			print("  retries=$k: $c (${pct.toStringAsFixed(2)}%)");
		}
		if (heavy.isNotEmpty) {
			heavy.sort((a, b) => b.retries.compareTo(a.retries));
			// ignore: avoid_print
			print("heavy cases (≥3 retries, top 10):");
			for (final c in heavy.take(10)) {
				// ignore: avoid_print
				print("  n=${c.n} seed=${c.seed} retries=${c.retries}");
			}
		}

		expect(total, greaterThan(0));
		// 守門：實測 maxRetry=3，設 5 留 60% 安全邊際。
		// 超過代表品質條件難以滿足、planner 演算法可能退化、值得檢查。
		expect(maxRetry, lessThan(5),
				reason: "最壞 case retry 次數應 < 5；"
						"看到更高的值表示某些品質條件難以滿足、planner 演算法可能退化");
	});
}
