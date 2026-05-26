import "dart:math";

import "package:flutter/foundation.dart";

/// 一個拼圖塊在網格中的描述。
///
/// 用 [normalLeft]、[normalTop]、[normalWidth]、[normalHeight] 描述其在
/// `[0, 1] × [0, 1]` 標準化座標中的範圍。原點在拼圖區域（不含外圈 padding）
/// 的左上角，(1, 1) 為右下角。後續 `puzzle_cutter` 會把它們乘上實際尺寸。
@immutable
class GridCellSpec {
	const GridCellSpec({
		required this.id,
		required this.normalLeft,
		required this.normalTop,
		required this.normalWidth,
		required this.normalHeight,
	});

	final int id;
	final double normalLeft;
	final double normalTop;
	final double normalWidth;
	final double normalHeight;

	double get normalRight => normalLeft + normalWidth;
	double get normalBottom => normalTop + normalHeight;

	@override
	String toString() {
		return "GridCellSpec(id=$id, l=$normalLeft, t=$normalTop, "
				"w=$normalWidth, h=$normalHeight)";
	}
}

/// 一整套拼圖網格規劃結果。
///
/// 結構：基礎 `baseCols × baseRows` 等分網格，再挑 [extraIndexes] 中的 row
/// （[extraAxis] = row 時）或 column（[extraAxis] = column 時）多切一刀
/// 變成 base+1 等份。`pieceCount = baseCols × baseRows + extraIndexes.length`。
///
/// 規則塊數（c×r == n）時 [extraIndexes] 為空。
@immutable
class GridLayoutSpec {
	const GridLayoutSpec({
		required this.pieceCount,
		required this.baseRows,
		required this.baseCols,
		required this.cells,
		required this.extraAxis,
		required this.extraIndexes,
	});

	final int pieceCount;
	final int baseRows;
	final int baseCols;
	final List<GridCellSpec> cells;

	/// 加切的軸。[extraIndexes] 為空時意義不大但仍標為 row（任意預設）。
	final GridAxis extraAxis;

	/// 被加切的 row / column 索引列表（依 [extraAxis] 解讀）。
	final List<int> extraIndexes;

	@override
	String toString() {
		return "GridLayoutSpec(count=$pieceCount, base=${baseCols}x$baseRows, "
				"extraAxis=$extraAxis, extraIndexes=$extraIndexes, "
				"cells=${cells.length})";
	}
}

/// 網格軸：row 或 column。
enum GridAxis {
	row,
	column,
}

/// 給定塊數產出網格規劃。
///
/// 支援 2~25 塊。演算法：
/// 1. 找出 `c × r ≤ n` 的所有 (c, r) 組合中、`c/r` 最接近 `4/3` 的一組當基礎網格。
/// 2. 不足量 `extra = n - c × r` 拿去加切：
///    - 若該基礎 c/r > 4/3（偏寬）→ 挑 [extra] 條 row（盡量分散）改成 c+1 等份。
///    - 若 c/r < 4/3（偏高）→ 挑 [extra] 條 column 改成 r+1 等份。
///    - c/r == 4/3 時兩種都可，挑 row（任意預設）。
class GridPlanner {
	GridPlanner._();

	static const int _minPieces = 2;
	static const int _maxPieces = 30;
	static const double _targetAspect = 4.0 / 3.0;

	/// 規劃網格。
	///
	/// [pieceCount] 必須在 2~25 之間，否則拋 [ArgumentError]。
	/// [seed] 用於不規則切法的隨機選擇（同 seed 必產出相同結果）。
	static GridLayoutSpec plan(int pieceCount, int seed) {
		if (pieceCount < _minPieces || pieceCount > _maxPieces) {
			throw ArgumentError.value(
				pieceCount,
				"pieceCount",
				"塊數必須介於 $_minPieces 到 $_maxPieces 之間",
			);
		}

		// 1. 找最接近 4:3 的 (c, r) 且 c × r ≤ n
		final (int cols, int rows) = _pickBaseGrid(pieceCount);
		final int extra = pieceCount - cols * rows;
		final double aspect = cols / rows;

		// 2. 決定加切的軸：
		//    - 偏寬（c/r > 4/3）→ 加切 column：某幾條 column 從 r 等份變 r+1 等份，
		//      那條 column 內塊變扁短，整體往「不那麼寬」平衡。
		//    - 偏高（c/r < 4/3）→ 加切 row：某幾條 row 從 c 等份變 c+1 等份。
		//    - c/r == 4/3 預設加切 column（任意）。
		final GridAxis extraAxis =
				aspect >= _targetAspect ? GridAxis.column : GridAxis.row;

		// 3. 從 [0, base) 範圍中挑 extra 個 index 加切；盡量平均分散。
		final int baseAlong = extraAxis == GridAxis.row ? rows : cols;
		final List<int> extraIndexes = _pickExtraIndexes(
			count: extra,
			outOf: baseAlong,
			seed: seed,
		);

		// 4. 建造 cells
		final List<GridCellSpec> cells = _buildCells(
			cols: cols,
			rows: rows,
			extraAxis: extraAxis,
			extraIndexes: extraIndexes,
		);

		return GridLayoutSpec(
			pieceCount: pieceCount,
			baseRows: rows,
			baseCols: cols,
			cells: cells,
			extraAxis: extraAxis,
			extraIndexes: extraIndexes,
		);
	}

	/// 找在 `c × r ≤ n` 中最佳的 (c, r)。
	///
	/// **動機**：拼圖盤是 4:3 比例；目標是讓 grid 模式下每片拼片**盡量接近
	/// 正方形**（避免長條形或瘦長的塊，視覺與操作體驗都比較舒服）。每片寬高
	/// 比 ≈ `(boardW/c) / (boardH/r) = (4/3) × (r/c)` 反過來 `c/r = 4/3` 時剛好
	/// 1:1 正方。因此 `c/r` 越接近 `4/3`，每片越接近正方形。
	///
	/// 評分用 `c/r` 與 4:3 的對稱偏差 `|a/t - 1| + |t/a - 1|`，越小越好。
	///
	/// **硬約束**：加切軸（aspect>=4/3 → column；否則 row）上最多每條多切一刀，
	/// 所以 `extra ≤ 該軸基礎數量`：
	/// - 切 column 時 `extra ≤ cols`
	/// - 切 row 時 `extra ≤ rows`
	/// 不滿足就跳過該 (c, r)，避免有些塊被切得太碎、形狀差距太大。
	///
	/// 並列時的次要排序：
	/// 1. `prod` 較大（剛好整除自然視為等同 prod 最大）
	/// 2. `cols` 較大（橫向長一點、更適合 4:3 拼圖盤）
	static (int, int) _pickBaseGrid(int n) {
		int bestCols = 1;
		int bestRows = 1;
		double bestAspectDiff = double.infinity;
		int bestProd = 0;
		for (int r = 1; r <= n; r++) {
			for (int c = 1; c <= n; c++) {
				final int prod = c * r;
				if (prod > n) break;
				final int extra = n - prod;
				final double aspect = c / r;
				// 硬約束：加切軸允許的最大 extra
				final int extraLimit = aspect >= _targetAspect ? c : r;
				if (extra > extraLimit) continue;
				final double aspectDiff =
						(aspect / _targetAspect - 1).abs() +
						(_targetAspect / aspect - 1).abs();
				final bool better;
				if (aspectDiff < bestAspectDiff - 1e-9) {
					better = true;
				} else if ((aspectDiff - bestAspectDiff).abs() < 1e-9) {
					// 並列：prod 較大優先、再來 cols 較大
					better = prod > bestProd ||
							(prod == bestProd && c > bestCols);
				} else {
					better = false;
				}
				if (better) {
					bestCols = c;
					bestRows = r;
					bestAspectDiff = aspectDiff;
					bestProd = prod;
				}
			}
		}
		return (bestCols, bestRows);
	}

	/// 從 `[0, outOf)` 範圍挑 [count] 個索引，盡量分散（等距）並用 [seed] 微擾起點。
	static List<int> _pickExtraIndexes({
		required int count,
		required int outOf,
		required int seed,
	}) {
		if (count <= 0 || outOf <= 0) return const <int>[];
		if (count >= outOf) {
			return List<int>.generate(outOf, (int i) => i);
		}
		// 等距分散：用 floor((i + offset) * outOf / count)
		// offset 由 seed 決定，避免每次都是 0、1、2...（看起來偏左）。
		final Random random = Random(seed);
		final double offset = random.nextDouble();
		final Set<int> picked = <int>{};
		int i = 0;
		while (picked.length < count && i < count * 4) {
			final int idx = (((i + offset) * outOf) / count).floor() % outOf;
			picked.add(idx);
			i++;
		}
		final List<int> result = picked.toList()..sort();
		return result;
	}

	/// 依 [cols] × [rows] 基礎網格 + [extraIndexes] 的加切，產生所有 cells。
	static List<GridCellSpec> _buildCells({
		required int cols,
		required int rows,
		required GridAxis extraAxis,
		required List<int> extraIndexes,
	}) {
		final Set<int> extras = extraIndexes.toSet();
		final List<GridCellSpec> cells = <GridCellSpec>[];
		int id = 0;
		final double baseW = 1.0 / cols;
		final double baseH = 1.0 / rows;

		if (extraAxis == GridAxis.row) {
			// 加切某些 row：那幾行從 cols 等份改成 cols+1 等份。
			for (int r = 0; r < rows; r++) {
				final int cThis = extras.contains(r) ? cols + 1 : cols;
				final double cellW = 1.0 / cThis;
				for (int c = 0; c < cThis; c++) {
					cells.add(GridCellSpec(
						id: id++,
						normalLeft: c * cellW,
						normalTop: r * baseH,
						normalWidth: cellW,
						normalHeight: baseH,
					));
				}
			}
		} else {
			// 加切某些 column：那幾列從 rows 等份改成 rows+1 等份。
			for (int c = 0; c < cols; c++) {
				final int rThis = extras.contains(c) ? rows + 1 : rows;
				final double cellH = 1.0 / rThis;
				for (int r = 0; r < rThis; r++) {
					cells.add(GridCellSpec(
						id: id++,
						normalLeft: c * baseW,
						normalTop: r * cellH,
						normalWidth: baseW,
						normalHeight: cellH,
					));
				}
			}
		}
		return cells;
	}
}
