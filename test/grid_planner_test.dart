import "package:flutter_test/flutter_test.dart";
import "package:kid_puzzle/features/puzzle/domain/services/grid_planner.dart";

void main() {
	group("GridPlanner", () {
		test("2~30 塊各跑 30 次 seed，塊數正確且每塊範圍合理", () {
			for (int pieceCount = 2; pieceCount <= 30; pieceCount++) {
				for (int seed = 0; seed < 30; seed++) {
					final GridLayoutSpec spec = GridPlanner.plan(pieceCount, seed);

					expect(
						spec.cells.length,
						pieceCount,
						reason: "塊數=$pieceCount, seed=$seed 結果應為 $pieceCount 塊",
					);

					for (final GridCellSpec cell in spec.cells) {
						expect(cell.normalLeft, greaterThanOrEqualTo(-1e-9));
						expect(cell.normalTop, greaterThanOrEqualTo(-1e-9));
						expect(cell.normalRight, lessThanOrEqualTo(1 + 1e-9));
						expect(cell.normalBottom, lessThanOrEqualTo(1 + 1e-9));
						expect(cell.normalWidth, greaterThan(0));
						expect(cell.normalHeight, greaterThan(0));
					}

					double total = 0;
					for (final GridCellSpec cell in spec.cells) {
						total += cell.normalWidth * cell.normalHeight;
					}
					expect(total, closeTo(1.0, 1e-6),
							reason: "塊數=$pieceCount, seed=$seed 面積總和應為 1");
				}
			}
		});

		test("無兩塊重疊（2~30 各跑 10 次 seed）", () {
			for (int pieceCount = 2; pieceCount <= 30; pieceCount++) {
				for (int seed = 0; seed < 10; seed++) {
					final GridLayoutSpec spec = GridPlanner.plan(pieceCount, seed);
					for (int i = 0; i < spec.cells.length; i++) {
						for (int j = i + 1; j < spec.cells.length; j++) {
							final GridCellSpec a = spec.cells[i];
							final GridCellSpec b = spec.cells[j];
							final double overlapW =
									(a.normalRight < b.normalRight ? a.normalRight : b.normalRight) -
									(a.normalLeft > b.normalLeft ? a.normalLeft : b.normalLeft);
							final double overlapH =
									(a.normalBottom < b.normalBottom ? a.normalBottom : b.normalBottom) -
									(a.normalTop > b.normalTop ? a.normalTop : b.normalTop);
							if (overlapW > 1e-6 && overlapH > 1e-6) {
								fail("塊數=$pieceCount, seed=$seed: cell $i 與 $j 有重疊區域 "
										"($overlapW x $overlapH)");
							}
						}
					}
				}
			}
		});

		test("塊數超出 2~300 拋 ArgumentError", () {
			expect(() => GridPlanner.plan(1, 0), throwsArgumentError);
			expect(() => GridPlanner.plan(301, 0), throwsArgumentError);
			expect(() => GridPlanner.plan(0, 0), throwsArgumentError);
		});

		test("同 seed 同塊數產出相同結果", () {
			for (int pieceCount = 2; pieceCount <= 30; pieceCount++) {
				final GridLayoutSpec a = GridPlanner.plan(pieceCount, 42);
				final GridLayoutSpec b = GridPlanner.plan(pieceCount, 42);
				expect(a.cells.length, b.cells.length);
				for (int i = 0; i < a.cells.length; i++) {
					expect(a.cells[i].normalLeft, b.cells[i].normalLeft);
					expect(a.cells[i].normalTop, b.cells[i].normalTop);
					expect(a.cells[i].normalWidth, b.cells[i].normalWidth);
					expect(a.cells[i].normalHeight, b.cells[i].normalHeight);
				}
			}
		});

		test("基礎網格 c × r ≤ n 且最接近 4:3（不再以規則網格優先）", () {
			// 新算法只看 aspect 最接近 4:3、無 weight；
			// 約束：extra ≤ 加切軸的基礎數，避免某幾條被多切一刀的負擔過大。
			expect(_baseOf(4), (2, 2));
			expect(_baseOf(6), (3, 2));
			// n=8：3×2 (aspect=1.5) 比 4×2 (aspect=2) 接近 4/3
			expect(_baseOf(8), (3, 2));
			expect(_baseOf(12), (4, 3)); // 完美 aspect=4/3
			expect(_baseOf(20), (5, 4));

			expect(_baseOf(5), (2, 2));
			expect(_baseOf(7), (3, 2));
			expect(_baseOf(10), (3, 3));
		});

		test("加切軸：偏寬切 column、偏高切 row", () {
			// 5 塊：base 2×2，2/2=1.0 < 4/3 → 偏高 → 切 row
			final GridLayoutSpec spec5 = GridPlanner.plan(5, 0);
			expect(spec5.baseCols, 2);
			expect(spec5.baseRows, 2);
			expect(spec5.extraIndexes.length, 1);
			expect(spec5.extraAxis, GridAxis.row);

			// 7 塊：base 3×2，3/2=1.5 > 4/3 → 偏寬 → 切 column
			final GridLayoutSpec spec7 = GridPlanner.plan(7, 0);
			expect(spec7.baseCols, 3);
			expect(spec7.baseRows, 2);
			expect(spec7.extraIndexes.length, 1);
			expect(spec7.extraAxis, GridAxis.column);
		});

		test("某些 n 會挑剛好整除 c×r=n 的網格、extraIndexes 為空", () {
			// 注意：新算法純看 aspect，不對「規則整除」加分。
			// 這些 n 之所以剛好規則，是因為剛好有個 c×r=n 的組合最接近 4:3：
			// - 4 → 2×2 aspect 1
			// - 6 → 3×2 aspect 1.5
			// - 12 → 4×3 aspect=4/3（完美）
			// - 20 → 5×4 aspect=1.25
			//
			// n=8、9、16 雖然有剛好整除組合，但 aspect 不是最近的：
			// - n=8 挑 3×2+2，視覺 = 4×2 切其中一條變 3
			// - n=9 挑 3×2+3，但「3×2 整個 column 都被切成 3」其實等於 3×3+0
			// 這些等價情形不影響視覺，所以不放進這個測試。
			for (final int n in <int>[4, 6, 12, 20]) {
				final GridLayoutSpec spec = GridPlanner.plan(n, 0);
				expect(spec.extraIndexes, isEmpty,
						reason: "n=$n 應為規則網格、無 extra");
			}
		});

		test("2 塊小 case：能切出 2 塊", () {
			// 注意：base grid 可能是 2×1 或 1×1+extra，視覺結果相同（兩個並列長方形）。
			final GridLayoutSpec spec2 = GridPlanner.plan(2, 0);
			expect(spec2.cells.length, 2);
		});
	});
}

(int, int) _baseOf(int n) {
	final GridLayoutSpec spec = GridPlanner.plan(n, 0);
	return (spec.baseCols, spec.baseRows);
}
