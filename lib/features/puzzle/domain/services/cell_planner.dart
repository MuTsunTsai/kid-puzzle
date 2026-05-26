import "dart:math";
import "dart:ui";

import "grid_planner.dart";
import "voronoi.dart";

/// 一個 cell：以 polygon（順時針或逆時針頂點列）表示。
class CellPolygon {
	const CellPolygon({
		required this.id,
		required this.vertices,
	});

	/// 唯一識別碼（0 起算）。
	final int id;

	/// polygon 頂點，**在「拼圖內側區域」的 pixel 座標**（已經套上 padding 偏移）。
	final List<Offset> vertices;

	/// 此 polygon 的軸對齊外接矩形（AABB）。
	Rect get bounds {
		double minX = double.infinity, minY = double.infinity;
		double maxX = -double.infinity, maxY = -double.infinity;
		for (final Offset v in vertices) {
			if (v.dx < minX) minX = v.dx;
			if (v.dy < minY) minY = v.dy;
			if (v.dx > maxX) maxX = v.dx;
			if (v.dy > maxY) maxY = v.dy;
		}
		return Rect.fromLTRB(minX, minY, maxX, maxY);
	}
}

/// 切割布局：一組 polygon cells，由 [CellPlanner.plan] 產出。
class CellLayout {
	const CellLayout({
		required this.pieceCount,
		required this.cells,
		required this.innerBounds,
	});

	final int pieceCount;

	/// 全部 cells（順序穩定）。
	final List<CellPolygon> cells;

	/// 「內側」可切割區域（不含拼圖盤外圈 padding 環），cells 必在此內。
	final Rect innerBounds;
}

/// 切割模式（呈現給設定頁與保存設定用）。
enum CutMode {
	/// 方格網（內含 5/7/10 不規則重切）。
	grid,

	/// Voronoi 隨機切割。
	voronoi,
}

/// 抽象切割布局規劃器：grid / voronoi 都實作此介面。
abstract class CellPlanner {
	const CellPlanner();

	/// 在 [innerBounds] 內規劃 [pieceCount] 個 cell。
	CellLayout plan({
		required int pieceCount,
		required Rect innerBounds,
		required int seed,
	});
}

/// 方格網切割：把 [GridPlanner] 的 normalized cell 轉成 polygon。
///
/// 注意：5/7/10 不規則切割可能讓 cell 共享「部分」邊（A 的 top 邊與 B、C 兩個
/// cell 的 bottom 邊各共享一半）。這時 cutter 端點配對會失敗。為了解決，
/// 在輸出 polygon 前先「精修」：對每條邊掃所有其他 cell 頂點，若有頂點落在
/// 該邊上就插入該頂點到此邊。如此確保任何共享邊在兩側 polygon 中都有完全
/// 相同的端點。
class GridCellPlanner extends CellPlanner {
	const GridCellPlanner();

	static const double _epsilon = 1e-3;

	@override
	CellLayout plan({
		required int pieceCount,
		required Rect innerBounds,
		required int seed,
	}) {
		final GridLayoutSpec spec = GridPlanner.plan(pieceCount, seed);
		// 先把每個 cell 換算成矩形 4 頂點
		final List<List<Offset>> rawCells = <List<Offset>>[];
		for (final GridCellSpec g in spec.cells) {
			final double left = innerBounds.left + g.normalLeft * innerBounds.width;
			final double top = innerBounds.top + g.normalTop * innerBounds.height;
			final double right = left + g.normalWidth * innerBounds.width;
			final double bottom = top + g.normalHeight * innerBounds.height;
			rawCells.add(<Offset>[
				Offset(left, top),
				Offset(right, top),
				Offset(right, bottom),
				Offset(left, bottom),
			]);
		}

		// 收集所有「頂點」位置（去重）
		final List<Offset> allVertices = <Offset>[];
		for (final List<Offset> cell in rawCells) {
			for (final Offset v in cell) {
				if (!allVertices.any((Offset u) =>
						(u.dx - v.dx).abs() < _epsilon && (u.dy - v.dy).abs() < _epsilon)) {
					allVertices.add(v);
				}
			}
		}

		// 對每個 cell 的每條邊，掃所有其他頂點看是否落在邊上、若有則插入
		final List<CellPolygon> cells = <CellPolygon>[];
		for (int i = 0; i < rawCells.length; i++) {
			final List<Offset> refined = <Offset>[];
			final List<Offset> cell = rawCells[i];
			for (int j = 0; j < cell.length; j++) {
				final Offset a = cell[j];
				final Offset b = cell[(j + 1) % cell.length];
				refined.add(a);
				// 找出落在 (a, b) 線段內部（不含端點）的頂點
				final List<Offset> inserts = <Offset>[];
				for (final Offset v in allVertices) {
					if (_pointApproxEq(v, a) || _pointApproxEq(v, b)) continue;
					if (_pointOnSegment(v, a, b)) inserts.add(v);
				}
				// 依距離 a 由近到遠排序
				inserts.sort((Offset p, Offset q) =>
						(p - a).distanceSquared.compareTo((q - a).distanceSquared));
				refined.addAll(inserts);
			}
			cells.add(CellPolygon(id: spec.cells[i].id, vertices: refined));
		}

		return CellLayout(
			pieceCount: pieceCount,
			cells: cells,
			innerBounds: innerBounds,
		);
	}

	static bool _pointApproxEq(Offset p, Offset q) =>
			(p.dx - q.dx).abs() < _epsilon && (p.dy - q.dy).abs() < _epsilon;

	/// 判斷 v 是否落在線段 (a, b) 內部（含浮點容差）。
	static bool _pointOnSegment(Offset v, Offset a, Offset b) {
		// 共線：cross == 0
		final double cross =
				(b.dx - a.dx) * (v.dy - a.dy) - (b.dy - a.dy) * (v.dx - a.dx);
		if (cross.abs() > _epsilon * 10) return false;
		// 介於 a、b 之間：dot 介於 0 與 |ab|²
		final double dot = (v.dx - a.dx) * (b.dx - a.dx) + (v.dy - a.dy) * (b.dy - a.dy);
		final double lenSq = (b.dx - a.dx) * (b.dx - a.dx) + (b.dy - a.dy) * (b.dy - a.dy);
		return dot > _epsilon && dot < lenSq - _epsilon;
	}
}

/// Voronoi 切割：用 [VoronoiBuilder] 在 inner bounds 內生成 cells。
///
/// **凹多邊形機制**：先生成 [oversampleRatio] × pieceCount 個凸 Voronoi cell，
/// 再隨機合併相鄰 cell 對直到剩下 pieceCount 個。合併把兩個共享單一邊的凸
/// cell 沿該邊聯集成一個凹（通常）多邊形 — 自然產生 L 形 / T 形 / 箭頭形等
/// 不規則形狀。Cutter 對共享邊的偵測與耳朵協商不變：合併後的邊變新「外圈
/// 等同」由 segment 系統自然處理。
class VoronoiCellPlanner extends CellPlanner {
	const VoronoiCellPlanner({
		this.lloydIterations = 10,
		this.oversampleRatio = 1.5,
	});

	/// Lloyd 鬆弛迭代次數（越多分佈越均勻、但計算量加倍）。
	///
	/// 經量測：3 次時最大/最小面積比平均 2.33、最差 5.34；10 次時降到平均
	/// 1.53、最差 2.93。對 N ≤ 30 的拼圖場景關卡載入額外時間可忽略。
	final int lloydIterations;

	/// 一開始生多少 cell（最終會合併到 pieceCount）。例如 1.5 表示 N=8 → 生
	/// 12 個 cell、合 4 對。比例越大、凹多邊形越多 / 越誇張。
	final double oversampleRatio;

	/// 浮點數判等容差（像素）。與 [PuzzleCutter] 用的容差量級一致。
	static const double _epsilon = 0.5;

	@override
	CellLayout plan({
		required int pieceCount,
		required Rect innerBounds,
		required int seed,
	}) {
		final Random random = Random(seed);
		// 過取樣：先生 ceil(pieceCount * oversampleRatio) 個 cell。
		// 若 oversampleRatio = 1.0 或 pieceCount <= 1，等同直接切（不合併）。
		final int rawCount = (pieceCount * oversampleRatio).ceil();
		final int initialCount = rawCount > pieceCount ? rawCount : pieceCount;

		final List<Offset> points = VoronoiBuilder.generatePoissonLikePoints(
			bounds: innerBounds,
			count: initialCount,
			random: random,
			lloydIterations: lloydIterations,
		);
		final List<VoronoiCell> vCells = VoronoiBuilder.computeVoronoi(
			points: points,
			bounds: innerBounds,
		);
		// 初始 polygons（從 Voronoi 取出）。後續合併會直接修改這個 list。
		List<List<Offset>> polys =
				vCells.map((VoronoiCell c) => List<Offset>.of(c.polygon)).toList();

		// 合併策略：以「拼片大小盡量接近 targetArea」為導向。
		// - targetArea = 內側總面積 / 目標塊數。
		// - 每輪挑「合法相鄰對」中、合併後面積最接近 targetArea 者（加 random 擾動）。
		// - 每個原始 cell 最多被合併 1 次（即合到目標塊數的 cell 由 1 或 2 個原始
		//   cell 組成、不會出現「3 個合一」的大塊）。
		//
		// 「最多合 1 次」是均勻度的關鍵：限制最終 cell 只有兩種尺寸（1 cell 或
		// 2 cell），target 訂在「平均」附近時、兩種都能接近 target、最大/最小
		// 面積比可控。
		final double innerArea = innerBounds.width * innerBounds.height;
		final double targetArea = innerArea / pieceCount;
		// 已被合併過的 cell 索引集合（不可再合）。索引隨 polys.removeAt 變動、
		// 每次合併後重建。
		Set<int> merged = <int>{};
		final Set<String> banned = <String>{};
		while (polys.length > pieceCount) {
			final ({int a, int b})? pair = _pickMergePair(
				polys,
				random,
				targetArea: targetArea,
				alreadyMerged: merged,
				banned: banned,
			);
			if (pair == null) break;
			final List<Offset>? mergedPoly =
					_mergePolygons(polys[pair.a], polys[pair.b]);
			if (mergedPoly == null) {
				banned.add("${pair.a}_${pair.b}");
				continue;
			}
			// 合併：用 mergedPoly 取代 a、移除 b。
			// 索引重建：a 變成「已合」，b 後面的索引各 -1。
			polys[pair.a] = mergedPoly;
			polys.removeAt(pair.b);
			final Set<int> newMerged = <int>{pair.a};
			for (final int idx in merged) {
				if (idx == pair.a) continue;
				if (idx == pair.b) continue; // b 不存在了
				newMerged.add(idx > pair.b ? idx - 1 : idx);
			}
			merged = newMerged;
			banned.clear();
		}

		final List<CellPolygon> cells = <CellPolygon>[
			for (int i = 0; i < polys.length; i++)
				CellPolygon(id: i, vertices: polys[i]),
		];
		return CellLayout(
			pieceCount: cells.length,
			cells: cells,
			innerBounds: innerBounds,
		);
	}

	/// 從 [polys] 中挑一對「合法可合併」的 cell pair。
	///
	/// **挑選規則**：
	/// - 排除 [alreadyMerged] 內的 cell（每 cell 最多合 1 次）。
	/// - 排除 [banned] 內的 pair（先前合併失敗的退化對）。
	/// - 要求有共享邊（長 > 0）。
	/// - 權重：偏好「合併後面積接近 [targetArea]」的對，目的是讓最終所有拼片
	///   大小盡量一致。權重公式： `1 / (1 + |mergedArea - targetArea| / targetArea)
	///   × (0.5 + random)`，越接近 target 越高、配 random 增加多樣性。
	///
	/// 沒任何合法對回 null。
	static ({int a, int b})? _pickMergePair(
		List<List<Offset>> polys,
		Random random, {
		required double targetArea,
		required Set<int> alreadyMerged,
		Set<String> banned = const <String>{},
	}) {
		final List<({int a, int b, double weight})> candidates =
				<({int a, int b, double weight})>[];
		// 預先算各 cell 面積、避免內層迴圈重算
		final List<double> areas = <double>[
			for (final List<Offset> p in polys) _polygonAbsArea(p),
		];
		for (int i = 0; i < polys.length; i++) {
			if (alreadyMerged.contains(i)) continue;
			for (int j = i + 1; j < polys.length; j++) {
				if (alreadyMerged.contains(j)) continue;
				if (banned.contains("${i}_$j")) continue;
				final double sharedLen = _sharedEdgeLength(polys[i], polys[j]);
				if (sharedLen <= 0) continue;
				final double mergedArea = areas[i] + areas[j];
				// 偏差比例：0 = 完美貼近 target、越大越偏離
				final double dev = (mergedArea - targetArea).abs() / targetArea;
				// 用 1/(1+dev) 把偏差轉成「越近 target 權重越高」、配 random 多樣化
				final double weight = (0.5 + random.nextDouble()) / (1.0 + dev);
				candidates.add((a: i, b: j, weight: weight));
			}
		}
		if (candidates.isEmpty) return null;
		// 加權累積分佈抽
		double total = 0;
		for (final ({int a, int b, double weight}) c in candidates) {
			total += c.weight;
		}
		final double pick = random.nextDouble() * total;
		double acc = 0;
		for (final ({int a, int b, double weight}) c in candidates) {
			acc += c.weight;
			if (pick <= acc) return (a: c.a, b: c.b);
		}
		return (a: candidates.last.a, b: candidates.last.b);
	}

	/// 計算 [a]、[b] 兩個 polygon 間的「共享邊總長度」。
	/// 共享邊：a 的某條 polygon 邊 (a_i, a_{i+1}) 與 b 的某條反向邊
	/// (b_j, b_{j+1}) 端點重合（容差 [_epsilon]）。
	/// 共享多條邊（≥ 2）會把長度都加起來，後續 _mergePolygons 會拒絕這種對。
	static double _sharedEdgeLength(List<Offset> a, List<Offset> b) {
		double len = 0;
		for (int i = 0; i < a.length; i++) {
			final Offset a1 = a[i];
			final Offset a2 = a[(i + 1) % a.length];
			for (int j = 0; j < b.length; j++) {
				final Offset b1 = b[j];
				final Offset b2 = b[(j + 1) % b.length];
				// a 的方向 a1→a2 對應 b 的反向 b2→b1（兩 polygon 都 CCW、共享邊互逆）
				if (_pointApproxEq(a1, b2) && _pointApproxEq(a2, b1)) {
					len += (a2 - a1).distance;
				}
			}
		}
		return len;
	}

	/// 合併兩個共享**單一邊**的 polygon。
	///
	/// 演算法：找出 a 中的共享邊 (a_i, a_{i+1})（V1=a_i、V2=a_{i+1}），對應 b 中
	/// 的反向邊 (b_j, b_{j+1}) 其中 b_j == V2、b_{j+1} == V1。共享邊本身（V1↔V2）
	/// 從合併 polygon 上消失、但**兩個端點 V1 / V2 都必須保留**（它們可能還連到
	/// 第三、第四個未合的 cell；若被消掉、其他 cell 與合併 polygon 在該頂點就
	/// 不對齊、會重疊）。
	///
	/// 合併路徑：a[0..i]（含 V1）→ b[(j+2)..(j-1)]（繞 nb-2 個點、跳過 V1 V2）
	/// → a[i+1]（V2）→ a[i+2..]。
	///
	/// 共享多條邊（≥ 2）或找不到對應邊回 null（呼叫端應跳過此對）。
	static List<Offset>? _mergePolygons(List<Offset> a, List<Offset> b) {
		// 找出 a 中所有「在 b 中也存在的反向邊」的索引
		final List<int> sharedInA = <int>[];
		final List<int> sharedInB = <int>[];
		for (int i = 0; i < a.length; i++) {
			final Offset a1 = a[i];
			final Offset a2 = a[(i + 1) % a.length];
			for (int j = 0; j < b.length; j++) {
				final Offset b1 = b[j];
				final Offset b2 = b[(j + 1) % b.length];
				if (_pointApproxEq(a1, b2) && _pointApproxEq(a2, b1)) {
					sharedInA.add(i);
					sharedInB.add(j);
				}
			}
		}
		if (sharedInA.length != 1) return null; // 0 或 ≥2 共享邊：拒絕

		final int i = sharedInA.first;
		final int j = sharedInB.first;
		final int na = a.length;
		final int nb = b.length;
		final List<Offset> merged = <Offset>[];
		// a[0..i]（含 a[i] = V1，當合併 polygon 的凹角頂點保留）
		for (int k = 0; k <= i; k++) {
			merged.add(a[k]);
		}
		// b 從 b[(j+2) % nb] 開始繞 nb-2 個點到 b[(j-1+nb) % nb]
		// （跳過 b[j+1]=V1 與 b[j]=V2、其他 b 頂點全部納入）
		for (int s = 0; s < nb - 2; s++) {
			merged.add(b[(j + 2 + s) % nb]);
		}
		// a[i+1..end]（含 a[i+1] = V2，當合併 polygon 的凹角頂點保留）
		for (int k = i + 1; k < na; k++) {
			merged.add(a[k]);
		}
		if (merged.length < 3) return null;
		return merged;
	}

	static bool _pointApproxEq(Offset p, Offset q) =>
			(p.dx - q.dx).abs() < _epsilon && (p.dy - q.dy).abs() < _epsilon;

	/// Polygon 的絕對面積（shoelace formula）。
	/// 不關心方向（CCW 為正 / CW 為負）— 取絕對值。
	static double _polygonAbsArea(List<Offset> poly) {
		double sum = 0;
		for (int i = 0; i < poly.length; i++) {
			final Offset a = poly[i];
			final Offset b = poly[(i + 1) % poly.length];
			sum += a.dx * b.dy - b.dx * a.dy;
		}
		return sum.abs() / 2;
	}
}
