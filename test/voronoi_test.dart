import "dart:math";
import "dart:ui";

import "package:flutter_test/flutter_test.dart";
import "package:kid_puzzle/features/puzzle/domain/services/voronoi.dart";

const Rect kBounds = Rect.fromLTWH(0, 0, 800, 600);

void main() {
	group("VoronoiBuilder", () {
		test("生成 6 點、計算 Voronoi 後得到 6 cells", () async {
			final Random random = Random(42);
			final List<Offset> points = await VoronoiBuilder.generatePoissonLikePoints(
				bounds: kBounds,
				count: 6,
				random: random,
				lloydIterations: 0,
			);
			expect(points.length, 6);

			final List<VoronoiCell> cells = await VoronoiBuilder.computeVoronoi(
				points: points,
				bounds: kBounds,
			);
			expect(cells.length, 6);
			for (final VoronoiCell c in cells) {
				expect(c.polygon.length, greaterThanOrEqualTo(3),
						reason: "cell 至少要有 3 頂點");
			}
		});

		test("Voronoi cells 面積總和 ≈ bounds 面積", () async {
			final Random random = Random(7);
			for (int n = 4; n <= 10; n++) {
				final List<Offset> points = await VoronoiBuilder.generatePoissonLikePoints(
					bounds: kBounds,
					count: n,
					random: random,
				);
				final List<VoronoiCell> cells = await VoronoiBuilder.computeVoronoi(
					points: points,
					bounds: kBounds,
				);
				double totalArea = 0;
				for (final VoronoiCell c in cells) {
					totalArea += _polygonArea(c.polygon);
				}
				final double expected = kBounds.width * kBounds.height;
				expect(totalArea, closeTo(expected, expected * 0.005),
						reason: "n=$n cells 總面積=$totalArea 期望=$expected");
			}
		});

		test("每個 cell 都在 bounds 內", () async {
			final Random random = Random(123);
			final List<Offset> points = await VoronoiBuilder.generatePoissonLikePoints(
				bounds: kBounds,
				count: 8,
				random: random,
			);
			final List<VoronoiCell> cells = await VoronoiBuilder.computeVoronoi(
				points: points,
				bounds: kBounds,
			);
			for (final VoronoiCell c in cells) {
				for (final Offset v in c.polygon) {
					expect(v.dx, greaterThanOrEqualTo(kBounds.left - 1e-3));
					expect(v.dx, lessThanOrEqualTo(kBounds.right + 1e-3));
					expect(v.dy, greaterThanOrEqualTo(kBounds.top - 1e-3));
					expect(v.dy, lessThanOrEqualTo(kBounds.bottom + 1e-3));
				}
			}
		});

		test("Lloyd 鬆弛後相鄰種子點距離方差降低（分佈更均勻）", () async {
			final Random random = Random(2026);
			final List<Offset> rawPoints = await VoronoiBuilder.generatePoissonLikePoints(
				bounds: kBounds,
				count: 10,
				random: random,
				lloydIterations: 0,
			);
			final List<Offset> smoothPoints = await VoronoiBuilder.generatePoissonLikePoints(
				bounds: kBounds,
				count: 10,
				random: Random(2026),
				lloydIterations: 3,
			);
			final double varRaw = _nearestNeighborVariance(rawPoints);
			final double varSmooth = _nearestNeighborVariance(smoothPoints);
			expect(varSmooth, lessThan(varRaw),
					reason: "Lloyd 鬆弛應降低最近鄰距離方差；raw=$varRaw smooth=$varSmooth");
		});
	});
}

double _polygonArea(List<Offset> poly) {
	double area = 0;
	for (int i = 0; i < poly.length; i++) {
		final Offset a = poly[i];
		final Offset b = poly[(i + 1) % poly.length];
		area += a.dx * b.dy - b.dx * a.dy;
	}
	return area.abs() / 2;
}

double _nearestNeighborVariance(List<Offset> pts) {
	final List<double> dists = <double>[];
	for (int i = 0; i < pts.length; i++) {
		double minD = double.infinity;
		for (int j = 0; j < pts.length; j++) {
			if (i == j) continue;
			final double d = (pts[i] - pts[j]).distance;
			if (d < minD) minD = d;
		}
		dists.add(minD);
	}
	final double mean = dists.reduce((a, b) => a + b) / dists.length;
	double v = 0;
	for (final double d in dists) {
		v += (d - mean) * (d - mean);
	}
	return v / dists.length;
}
