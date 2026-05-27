import "dart:math";
import "dart:ui";

// 暫時 import 上層 _diag 做卡死 debug；查完拔掉。
// ignore: avoid_relative_lib_imports
import "../../presentation/_diag.dart";
import "cell_planner.dart";
import "voronoi.dart";

/// 「不規則模式」拼圖切割。
///
/// **三階段流程**：
/// 1. 生 `pieceCount × seedMultiplier` 個 seed 跑 Voronoi（含 Lloyd 鬆弛）。
///    收集所有 cell polygon 的頂點 + 矩形四角，去重後做 Delaunay 三角化
///    → 覆蓋整個 innerBounds 的小三角形集合。
/// 2. 從 Voronoi seeds 中隨機挑 N 個當「anchor」、每個 anchor 認領「質心離
///    自己最近的尚未被認領的三角形」當種子；衝突時依「質心距離」競爭。
/// 3. region growing：反覆找「面積最小且有合法未分配鄰居」的群組、從它的
///    合法未分配鄰居中挑「合進來後最接近 target area」的那個加入。
///    「合法相鄰」要求共享邊對其中至少一個三角形的對角 ≥ 50°、避免沿短邊
///    接合產生尖角。合法相鄰圖卡住時退到物理相鄰圖補完。
///
/// 之後在輸出 polygon 前還會跑 [_simplifyVertices] 化簡共線 / 短鄰邊頂點。
class TriangleCellPlanner extends CellPlanner {
	const TriangleCellPlanner({
		this.lloydIterations = 10,
		this.seedMultiplier = 1.2,
	});

	/// 第一階段 Voronoi seed 的 Lloyd 鬆弛次數。
	final int lloydIterations;

	/// 第一階段 Voronoi seed 數 / pieceCount。越大、初始三角形越密、每個拼片
	/// 由更多三角形構成、形狀更曲折但 maxEdges 增加。
	///
	/// 經 sweep 量測（n=4~16、30 seed）：
	/// - 1.0：avg ratio 1.68、worst 3.98、maxE 8（凹比例幾乎為 0）
	/// - **1.2：avg 2.93、worst 6.16、maxE 12、凹比例 ~24%**（sweet spot）
	/// - 1.5：avg 3.32、maxE 14
	/// - 2.0+：劣化（worst 與 maxE 爆增）
	final double seedMultiplier;

	/// 浮點數判等容差（像素）。與 VoronoiCellPlanner / PuzzleCutter 一致。
	static const double _epsilon = 0.5;

	/// 「合法相鄰」門檻：兩三角形共享邊對其中**至少一個**三角形的對角 ≥ 此值
	/// 才視為合法。階段 3 region growing 用此判定「能否沿這條邊接合」、避免
	/// 沿短邊接合而產生尖角。
	///
	/// 任何三角形都至少有一角 ≥ 60°、設 50° 仍能保證每個三角形至少有一條
	/// 邊能被某群組「合法吸納」。
	static const double _legalMinOppositeAngleDeg = 50.0;

	/// 「腰」判定閾值：polygon 中「環狀 index 距離 ≥ [_waistIndexSepRatio] × N」
	/// 的兩頂點若空間距離 < [_minWaistRatio] × polygon AABB 短邊 → 視為太細。
	///
	/// 動機：cutter 把 polygon 邊轉成 baseline cubic 後，若 polygon 本身就有
	/// 「不相鄰兩點靠太近」，平滑化會在這個窄處外推、形成腰甚至自交。在 planner
	/// 階段就把這種 polygon 過濾掉。
	static const double _minWaistRatio = 0.18;
	static const double _waistIndexSepRatio = 0.3;

	@override
	CellLayout plan({
		required int pieceCount,
		required Rect innerBounds,
		required int seed,
	}) {
		// retry loop：planOnce 結果若有「腰太細」polygon，換 seed 重 plan。
		// 經驗上 5800 case sweep 中 ~5.5% 需要 retry、最差只到 3 次，20 次上限
		// 相當寬鬆；上限到了就回最後一次結果硬撐、避免極端輸入卡住。
		const int maxRetries = 20;
		int trySeed = seed;
		diag("triangle.plan: planOnce attempt=initial seed=$trySeed");
		CellLayout layout = _planOnce(
			pieceCount: pieceCount, innerBounds: innerBounds, seed: trySeed,
		);
		diag("triangle.plan: initial done cells=${layout.cells.length}, validating waist");
		for (int attempt = 0; attempt < maxRetries; attempt++) {
			if (_validateNoThinWaist(layout)) {
				diag("triangle.plan: waist PASS attempt=$attempt, return");
				break;
			}
			trySeed = trySeed * 1664525 + 1013904223;
			diag("triangle.plan: waist FAIL retry=$attempt newSeed=$trySeed");
			layout = _planOnce(
				pieceCount: pieceCount, innerBounds: innerBounds, seed: trySeed,
			);
			diag("triangle.plan: retry=$attempt planOnce done cells=${layout.cells.length}");
		}
		return layout;
	}

	/// 檢查每個 cell polygon 沒有「不相鄰兩點靠太近」。
	bool _validateNoThinWaist(CellLayout layout) {
		for (final CellPolygon cell in layout.cells) {
			final List<Offset> v = cell.vertices;
			final int n = v.length;
			if (n < 4) continue; // 三角形不可能有腰
			final double shortSide = cell.bounds.shortestSide;
			if (shortSide <= 0) continue;
			final double threshold = shortSide * _minWaistRatio;
			final double thresholdSq = threshold * threshold;
			final int minIdxSep = (n * _waistIndexSepRatio).ceil().clamp(2, n - 2);
			for (int i = 0; i < n; i++) {
				for (int j = i + minIdxSep; j < n; j++) {
					// 環狀距離也要 >= minIdxSep（避免 i=0、j=n-1 的相鄰對被誤抓）
					final int back = n - j + i;
					if (back < minIdxSep) continue;
					final double dx = v[i].dx - v[j].dx;
					final double dy = v[i].dy - v[j].dy;
					if (dx * dx + dy * dy < thresholdSq) return false;
				}
			}
		}
		return true;
	}

	CellLayout _planOnce({
		required int pieceCount,
		required Rect innerBounds,
		required int seed,
	}) {
		final Random random = Random(seed);
		if (pieceCount < 2) {
			return CellLayout(
				pieceCount: pieceCount,
				cells: <CellPolygon>[],
				innerBounds: innerBounds,
			);
		}

		// === 階段 1：Voronoi → 收集頂點 → Delaunay ===
		diag("_planOnce: phase1 generatePoissonLikePoints");
		final int voronoiSeeds = (pieceCount * seedMultiplier).ceil();
		final List<Offset> seeds = VoronoiBuilder.generatePoissonLikePoints(
			bounds: innerBounds,
			count: voronoiSeeds,
			random: random,
			lloydIterations: lloydIterations,
		);
		diag("_planOnce: phase1 computeVoronoi");
		final List<VoronoiCell> vCells = VoronoiBuilder.computeVoronoi(
			points: seeds,
			bounds: innerBounds,
		);
		diag("_planOnce: phase1 voronoi done seeds=${seeds.length}");
		// 收集所有 cell polygon 的頂點 + 矩形四角，去重
		final List<Offset> vertices = <Offset>[];
		void addVertex(Offset p) {
			for (final Offset v in vertices) {
				if ((v.dx - p.dx).abs() < _epsilon && (v.dy - p.dy).abs() < _epsilon) {
					return;
				}
			}
			vertices.add(p);
		}

		for (final VoronoiCell c in vCells) {
			for (final Offset v in c.polygon) {
				addVertex(v);
			}
		}
		// 強制加入矩形四角，確保 convex hull = innerBounds
		addVertex(Offset(innerBounds.left, innerBounds.top));
		addVertex(Offset(innerBounds.right, innerBounds.top));
		addVertex(Offset(innerBounds.right, innerBounds.bottom));
		addVertex(Offset(innerBounds.left, innerBounds.bottom));

		diag("_planOnce: phase1 delaunay (vertices=${vertices.length})");
		final List<_Triangle> triangles = _delaunay(vertices);
		diag("_planOnce: phase1 delaunay done triangles=${triangles.length}");
		if (triangles.length < pieceCount) {
			diag("_planOnce: triangles<pieceCount fallback to VoronoiCellPlanner");
			// 三角形數不足 N → 無法分 N 群。退到 Voronoi planner 當 fallback。
			return const VoronoiCellPlanner(oversampleRatio: 1.0).plan(
				pieceCount: pieceCount,
				innerBounds: innerBounds,
				seed: seed,
			);
		}

		// 三角形 polygon list（直接存 3 個 Offset）+ 質心
		final List<List<Offset>> triPolys = <List<Offset>>[
			for (final _Triangle t in triangles)
				<Offset>[vertices[t.a], vertices[t.b], vertices[t.c]],
		];
		final List<Offset> triCentroids = <Offset>[
			for (final List<Offset> tp in triPolys)
				Offset(
					(tp[0].dx + tp[1].dx + tp[2].dx) / 3,
					(tp[0].dy + tp[1].dy + tp[2].dy) / 3,
				),
		];

		// 三角形鄰居：sharedKey → 兩個三角形 idx（如果有兩個）
		final Map<String, List<int>> edgeToTris = <String, List<int>>{};
		for (int i = 0; i < triPolys.length; i++) {
			final List<Offset> tp = triPolys[i];
			for (int j = 0; j < 3; j++) {
				final String key = _edgeKey(tp[j], tp[(j + 1) % 3]);
				edgeToTris.putIfAbsent(key, () => <int>[]).add(i);
			}
		}
		final List<Set<int>> triNeighbors =
				List<Set<int>>.generate(triPolys.length, (_) => <int>{});
		for (final List<int> group in edgeToTris.values) {
			if (group.length < 2) continue;
			for (int i = 0; i < group.length; i++) {
				for (int j = 0; j < group.length; j++) {
					if (i != j) triNeighbors[group[i]].add(group[j]);
				}
			}
		}

		// 合法相鄰：在 [triNeighbors] 之上、額外要求「共享邊對至少一個三角形的
		// 對角 ≥ _legalMinOppositeAngleDeg」。用於成長階段的「加入規則」、避免
		// 沿短邊接合產生尖角。物理連通性檢查仍用 [triNeighbors]（更寬鬆）。
		final List<Set<int>> triLegalNeighbors = _buildLegalNeighbors(
			triPolys: triPolys,
			triNeighbors: triNeighbors,
			minOppositeAngleDeg: _legalMinOppositeAngleDeg,
		);

		// === 階段 2：N 個 anchor → 選 N 個種子三角形 ===
		// 從第一階段 voronoi seeds 中隨機挑 pieceCount 個當 anchor。
		// 經實驗、用 voronoi seed 當 anchor（與三角形分布對齊）比另外生獨立
		// anchor 顯著穩定（worst ratio 從 ~180 降到 ~6）。
		final List<Offset> shuffledSeeds = List<Offset>.of(seeds)..shuffle(random);
		final List<Offset> anchors = shuffledSeeds.take(pieceCount).toList();
		// 每個 anchor 對「所有三角形」按質心距離排序的索引
		// （懶癢計算：用 helper 一次性算出每個 anchor 的「下一個最近」迭代器）
		final List<List<int>> sortedTrisForAnchor = <List<int>>[
			for (final Offset a in anchors)
				_sortTrianglesByDistance(a, triCentroids),
		];
		// 認領機制：每個 anchor 依序試「下一個最近的三角形」，若已被認領就繼續
		final Set<int> claimed = <int>{};
		// triToGroup: triangle idx → group idx（0..N-1）；未分配 = -1
		final List<int> triToGroup = List<int>.filled(triPolys.length, -1);
		// 每 anchor 用一個指標追蹤下一個要試的「排序列表」位置
		final List<int> anchorCursor = List<int>.filled(pieceCount, 0);
		// 種子分配迴圈：每個 anchor 拿到一個三角形
		for (int g = 0; g < pieceCount; g++) {
			final List<int> sorted = sortedTrisForAnchor[g];
			while (anchorCursor[g] < sorted.length) {
				final int triIdx = sorted[anchorCursor[g]++];
				if (claimed.contains(triIdx)) continue;
				claimed.add(triIdx);
				triToGroup[triIdx] = g;
				break;
			}
			// 如果 cursor 走完仍沒選到（極端 case）就跳過、最終群組數會 < N
		}

		// === 階段 3：強化版 region growing（2c：群組 lookahead）===
		// 每輪反覆：
		// 1. 對每個群組 G、找它的「合法未分配鄰居」集合（用 [triLegalNeighbors]、
		//    過濾掉已分配的）。
		// 2. 收集「有合法未分配鄰居的群組」為 candidates；如果空、退到物理相鄰
		//    圖補完（fallback、確保所有三角形最終都被分配）。
		// 3. 從 candidates 挑面積最小者 G。
		// 4. G 從自己的合法未分配鄰居中、挑「合進來後 G 面積最接近 target」
		//    的那個吃下來。
		//
		// **與「三角形視角」（之前版本）的差異**：
		// - 之前：找未分配三角形 T、看哪個群組能吃它。
		// - 現在：找群組 G、看 G 該吃哪個未分配三角形。
		// 「群組視角」可以做 lookahead：G 知道自己當前面積、可挑能讓自己最
		// 接近 target 的鄰居（不一定是 G 鄰居中最小的、要看相對 target 的位
		// 置）、自然拉平群組面積。
		final List<Set<int>> groupTriangles =
				List<Set<int>>.generate(pieceCount, (_) => <int>{});
		final List<double> groupArea = List<double>.filled(pieceCount, 0);
		for (int t = 0; t < triPolys.length; t++) {
			final int g = triToGroup[t];
			if (g < 0) continue;
			groupTriangles[g].add(t);
			groupArea[g] += _triangleAbsArea(triPolys[t]);
		}

		final List<double> triArea = <double>[
			for (final List<Offset> tp in triPolys) _triangleAbsArea(tp),
		];
		// target = 假設所有三角形最終被分到 N 個群、平均面積
		final double totalArea = triArea.fold(0.0, (a, b) => a + b);
		final double targetArea = totalArea / pieceCount;

		bool growStep(List<Set<int>> neighborGraph) {
			// 1. 為每個群組找它的合法未分配鄰居、挑「面積最小且有合法鄰居」的
			int? targetGroup;
			double minArea = double.infinity;
			for (int g = 0; g < pieceCount; g++) {
				if (groupTriangles[g].isEmpty) continue;
				bool hasCandidate = false;
				for (final int t in groupTriangles[g]) {
					for (final int n in neighborGraph[t]) {
						if (triToGroup[n] < 0) {
							hasCandidate = true;
							break;
						}
					}
					if (hasCandidate) break;
				}
				if (!hasCandidate) continue;
				if (groupArea[g] < minArea) {
					minArea = groupArea[g];
					targetGroup = g;
				}
			}
			if (targetGroup == null) return false;

			// 2. targetGroup 從合法未分配鄰居中、挑「合進來後最接近 target」者
			int? bestTri;
			double bestDeviation = double.infinity;
			for (final int t in groupTriangles[targetGroup]) {
				for (final int n in neighborGraph[t]) {
					if (triToGroup[n] >= 0) continue;
					final double newArea = groupArea[targetGroup] + triArea[n];
					final double deviation = (newArea - targetArea).abs();
					if (deviation < bestDeviation) {
						bestDeviation = deviation;
						bestTri = n;
					}
				}
			}
			if (bestTri == null) return false;
			triToGroup[bestTri] = targetGroup;
			groupTriangles[targetGroup].add(bestTri);
			groupArea[targetGroup] += triArea[bestTri];
			return true;
		}

		// 主成長迴圈：先用合法相鄰圖、卡住就退到物理相鄰圖補完。
		diag("_planOnce: phase3 region growing (triangles=${triPolys.length})");
		int growIter = 0;
		while (true) {
			growIter++;
			if (growIter > triPolys.length + 10) {
				diag("_planOnce: phase3 RUNAWAY iter=$growIter, force-break");
				break;
			}
			if (growStep(triLegalNeighbors)) continue;
			if (growStep(triNeighbors)) continue;
			break;
		}
		diag("_planOnce: phase3 region growing done iter=$growIter");

		// === 輸出：把每群組的三角形 union 成一個 polygon ===
		// 用「邊計數」法：群組內所有三角形的邊，**出現 2 次的是內部邊（消去）、
		// 出現 1 次的是外圈邊（保留）**。然後把外圈邊串成有序 polygon。
		final List<List<Offset>> polys = <List<Offset>>[];
		final List<int> polyIds = <int>[];
		for (int g = 0; g < pieceCount; g++) {
			if (groupTriangles[g].isEmpty) continue;
			final List<Offset>? poly = _unionTriangles(
				groupTriangles[g],
				triPolys,
			);
			if (poly == null || poly.length < 3) continue;
			polys.add(poly);
			polyIds.add(g);
		}

		// === 後處理：簡化共線 / 短鄰邊頂點 ===
		// - 內部 degree=2 頂點：共線（內角 180°±30°）或鄰邊很短（< 平均邊長
		//   × 0.20）→ 從**兩個** owner polygon 同步移除此頂點、讓接合邊乾淨。
		// - 邊界 degree=1 頂點：共線（180°）才刪、角落 90° 保留。
		// - 邊界 degree=2 頂點：永不刪（會讓 polygon 離開矩形邊界）。
		diag("_planOnce: phase4 simplifyVertices polys=${polys.length}");
		// 防禦：simplifyVertices 在 web 上偶發卡死（n=5 voronoi 某些 seed），
		// 加超時保險絲 + try/catch 兜底。失敗就用未簡化的 polygons 繼續、
		// 視覺上頂點稍多但功能正確（共線頂點 cutter 仍能處理）。
		try {
			_simplifyVerticesGuarded(polys, innerBounds);
		} catch (e, st) {
			diag("_simplifyVertices THREW $e — using unsimplified polygons");
			// ignore: avoid_print
			print("[puzzle-diag] simplifyVertices stack: $st");
		}
		diag("_planOnce: phase4 done");

		final List<CellPolygon> cells = <CellPolygon>[
			for (int i = 0; i < polys.length; i++)
				if (polys[i].length >= 3)
					CellPolygon(id: polyIds[i], vertices: polys[i]),
		];
		return CellLayout(
			pieceCount: cells.length,
			cells: cells,
			innerBounds: innerBounds,
		);
	}

	/// 共線 / 短鄰邊頂點簡化的「直邊判定」閾值：|180° − 內角| ≤ 此值就視為共線。
	static const double _collinearAngleTolDeg = 30.0;

	/// 鄰邊長度 / 全 polygon 平均邊長 < 此比例 就視為「太短」。
	static const double _shortEdgeRatio = 0.20;

	/// 簡化頂點：
	/// - 內部 degree=2 頂點：共線或短邊 → 刪。
	/// - 邊界 degree=1 頂點：共線（180°）→ 刪、角落 90° 保留。
	/// - 邊界 degree=2 頂點：永不刪（會讓 polygon 離開矩形邊界）。
	/// - degree ≥ 3：不刪。
	///
	/// 反覆迭代直到沒有可刪頂點。
	static void _simplifyVerticesGuarded(
		List<List<Offset>> polys,
		Rect innerBounds,
	) {
		// Wall-clock 超時保險絲：simplifyVertices 在 web 上偶發 hang（具體 root
		// cause 還在追，見 trace）。卡超過 250ms 就放棄、用部分簡化的結果繼續、
		// 避免阻塞整個 isolate。
		final Stopwatch guard = Stopwatch()..start();
		const int maxWallMs = 250;
		bool onBoundary(Offset v) {
			const double t = _boundaryDetectThreshold;
			return (v.dx - innerBounds.left).abs() < t ||
					(v.dx - innerBounds.right).abs() < t ||
					(v.dy - innerBounds.top).abs() < t ||
					(v.dy - innerBounds.bottom).abs() < t;
		}
		// 先算全局平均邊長（基於初始 polygons、不每輪更新——可接受近似）
		double sumLen = 0;
		int edgeCount = 0;
		for (final List<Offset> p in polys) {
			for (int i = 0; i < p.length; i++) {
				sumLen += (p[(i + 1) % p.length] - p[i]).distance;
				edgeCount++;
			}
		}
		if (edgeCount == 0) return;
		final double avgEdgeLen = sumLen / edgeCount;
		final double shortEdgeThreshold = avgEdgeLen * _shortEdgeRatio;

		String vkey(Offset o) =>
				"${(o.dx * 10).round()},${(o.dy * 10).round()}";

		for (int iter = 0; iter < 100; iter++) {
			if (guard.elapsedMilliseconds > maxWallMs) {
				diag("_simplifyVertices: WALL TIMEOUT iter=$iter "
						"elapsed=${guard.elapsedMilliseconds}ms, bailing out");
				return;
			}
			if (iter % 10 == 0) {
				diag("_simplifyVertices: iter=$iter polys.lens=${polys.map((p) => p.length).toList()}");
			}
			// 收集每個頂點 → 它屬於哪些 polygon
			final Map<String, List<int>> vertexToPolys = <String, List<int>>{};
			for (int p = 0; p < polys.length; p++) {
				// 用 set 避免同 polygon 多次列入（理論上不會發生）
				final Set<String> seen = <String>{};
				for (final Offset v in polys[p]) {
					final String k = vkey(v);
					if (seen.add(k)) {
						vertexToPolys.putIfAbsent(k, () => <int>[]).add(p);
					}
				}
			}

			bool removedAny = false;
			// 找一個可刪頂點：遍歷每個 polygon 的每個頂點、判斷是否符合
			// （之所以從 polygon 端遍歷而不直接遍歷 vertexToPolys、是因為
			//  要拿前後鄰居算內角，這在 polygon 內較直接）。
			outer:
			for (int p = 0; p < polys.length; p++) {
				final List<Offset> poly = polys[p];
				if (poly.length <= 3) continue; // polygon 已是三角形、不能再縮
				for (int i = 0; i < poly.length; i++) {
					final Offset v = poly[i];
					final String k = vkey(v);
					final List<int> ownerPolys = vertexToPolys[k] ?? <int>[];
					final int degree = ownerPolys.length;
					if (degree > 2) continue; // 不處理 3+ way 接合
					// 算 v 在當前 polygon 內的內角 + 兩鄰邊長度
					final Offset prev = poly[(i - 1 + poly.length) % poly.length];
					final Offset next = poly[(i + 1) % poly.length];
					final double angle = _vertexAngleDeg(v, prev, next);
					final double edgePrevLen = (v - prev).distance;
					final double edgeNextLen = (next - v).distance;
					final bool nearStraight =
							(180.0 - angle).abs() <= _collinearAngleTolDeg;
					final bool hasShortEdge = degree == 2 &&
							(edgePrevLen < shortEdgeThreshold ||
									edgeNextLen < shortEdgeThreshold);
					bool shouldRemove;
					if (degree == 1) {
						// 邊界角落：90° 保留、180° 才刪
						shouldRemove = nearStraight;
					} else {
						// degree == 2：要區分是否在矩形邊界上。
						// 在邊界上的 degree=2 頂點 = 兩 polygon 沿矩形邊相接的點、
						// 刪掉會讓 polygon 離開矩形邊界、絕對不刪。
						// 只有純內部的 degree=2 頂點才依共線/短邊規則刪。
						if (onBoundary(v)) {
							shouldRemove = false;
						} else {
							shouldRemove = nearStraight || hasShortEdge;
						}
					}
					if (!shouldRemove) continue;
					// 檢查所有 owner polygon 都還有 > 3 頂點（刪後仍合法）
					bool safe = true;
					for (final int op in ownerPolys) {
						if (polys[op].length <= 3) {
							safe = false;
							break;
						}
					}
					if (!safe) continue;
					// 從所有 owner polygon 移除這個頂點（用 vkey 比對、容差安全）
					for (final int op in ownerPolys) {
						polys[op].removeWhere((Offset u) => vkey(u) == k);
					}
					removedAny = true;
					break outer; // 重新跑一輪（vertexToPolys 已過時）
				}
			}
			if (!removedAny) return;
		}
		diag("_simplifyVertices: HIT MAX ITER (100), bailing out");
	}

	/// 把三角形 idx 按「質心距 anchor」排序，回索引 list。
	static List<int> _sortTrianglesByDistance(
		Offset anchor,
		List<Offset> centroids,
	) {
		final List<int> idx = List<int>.generate(centroids.length, (i) => i);
		idx.sort((int a, int b) {
			final Offset ca = centroids[a];
			final Offset cb = centroids[b];
			final double da = (ca.dx - anchor.dx) * (ca.dx - anchor.dx) +
					(ca.dy - anchor.dy) * (ca.dy - anchor.dy);
			final double db = (cb.dx - anchor.dx) * (cb.dx - anchor.dx) +
					(cb.dy - anchor.dy) * (cb.dy - anchor.dy);
			return da.compareTo(db);
		});
		return idx;
	}

	/// 距 [_boundaryDetectThreshold] 內的點視為「在矩形邊界上」（[_simplifyVertices]
	/// 用此判斷邊界頂點該保留不該刪）。
	static const double _boundaryDetectThreshold = 0.5;

	/// 建構「合法相鄰」圖：在 [triNeighbors]（物理相鄰）之上、額外要求「共享
	/// 邊對至少一個三角形的對角 ≥ [minOppositeAngleDeg]」。
	///
	/// 用途：成長階段限制「能加入哪些鄰居」、避免沿短邊接合產生尖角。
	/// 連通性檢查仍用 [triNeighbors]（更寬鬆）。
	static List<Set<int>> _buildLegalNeighbors({
		required List<List<Offset>> triPolys,
		required List<Set<int>> triNeighbors,
		required double minOppositeAngleDeg,
	}) {
		final List<Set<int>> legal =
				List<Set<int>>.generate(triPolys.length, (_) => <int>{});
		for (int t = 0; t < triPolys.length; t++) {
			final List<Offset> tp = triPolys[t];
			for (final int n in triNeighbors[t]) {
				if (n <= t) continue; // 避免重複處理同一對（後面對 legal[n] 對稱加）
				// 找 t 與 n 的共享邊端點
				final List<Offset> ntp = triPolys[n];
				Offset? sharedA;
				Offset? sharedB;
				for (int i = 0; i < 3; i++) {
					final Offset a = tp[i];
					final Offset b = tp[(i + 1) % 3];
					bool hasA = false;
					bool hasB = false;
					for (final Offset v in ntp) {
						if ((v.dx - a.dx).abs() < _epsilon &&
								(v.dy - a.dy).abs() < _epsilon) {
							hasA = true;
						}
						if ((v.dx - b.dx).abs() < _epsilon &&
								(v.dy - b.dy).abs() < _epsilon) {
							hasB = true;
						}
					}
					if (hasA && hasB) {
						sharedA = a;
						sharedB = b;
						break;
					}
				}
				if (sharedA == null || sharedB == null) continue;
				// 計算共享邊對 t 與 n 各自的對角
				final Offset oppT = _thirdVertex(tp, sharedA, sharedB);
				final Offset oppN = _thirdVertex(ntp, sharedA, sharedB);
				final double angT = _vertexAngleDeg(oppT, sharedA, sharedB);
				final double angN = _vertexAngleDeg(oppN, sharedA, sharedB);
				// 「至少一個三角形」的對角 ≥ 門檻
				if (angT >= minOppositeAngleDeg || angN >= minOppositeAngleDeg) {
					legal[t].add(n);
					legal[n].add(t);
				}
			}
		}
		return legal;
	}

	/// 從三角形 [tp] 三個頂點中、找出不是 [a] 也不是 [b] 的「第三頂點」。
	static Offset _thirdVertex(List<Offset> tp, Offset a, Offset b) {
		for (final Offset v in tp) {
			final bool isA = (v.dx - a.dx).abs() < _epsilon &&
					(v.dy - a.dy).abs() < _epsilon;
			final bool isB = (v.dx - b.dx).abs() < _epsilon &&
					(v.dy - b.dy).abs() < _epsilon;
			if (!isA && !isB) return v;
		}
		return tp[0]; // fallback（退化）
	}

	/// 頂點 [vertex] 連到 [a]、[b] 的兩條向量之間的夾角（度）。
	/// 用來算「三角形某條邊的對角」：傳入第三頂點 + 邊的兩端點。
	static double _vertexAngleDeg(Offset vertex, Offset a, Offset b) {
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

	/// 三角形（3 個頂點）絕對面積。
	static double _triangleAbsArea(List<Offset> tp) {
		final double cross = (tp[1].dx - tp[0].dx) * (tp[2].dy - tp[0].dy) -
				(tp[1].dy - tp[0].dy) * (tp[2].dx - tp[0].dx);
		return cross.abs() / 2;
	}

	/// 把一組三角形（idx 集合）union 成單一封閉 polygon。
	///
	/// 演算法：
	/// 1. 收集所有三角形的邊（每邊存兩端點）。
	/// 2. 計數每邊出現次數：出現 2 次是內部共享邊（消去）、出現 1 次是外圈邊。
	/// 3. 把外圈邊串成有序 polygon（從某端點出發、找下一條共端點的邊、循環）。
	///
	/// 注意：邊「方向」要保持一致（順時針 / 逆時針），否則串不出 polygon。
	/// 三角形 polygon 在 _delaunay 內部是 CCW 還是 CW 與輸入點集分布有關、
	/// 不保證固定方向。所以這裡用「無向邊集」+ 找鄰接端點串接。
	static List<Offset>? _unionTriangles(
		Set<int> triIndices,
		List<List<Offset>> triPolys,
	) {
		// 用邊端點對 key 做計數
		final Map<String, int> edgeCount = <String, int>{};
		// key → 該邊的兩端點（保留原始 Offset、避免 quantize 後失去精度）
		final Map<String, ({Offset a, Offset b})> edgeEndpoints =
				<String, ({Offset a, Offset b})>{};
		for (final int t in triIndices) {
			final List<Offset> tp = triPolys[t];
			for (int j = 0; j < 3; j++) {
				final Offset p = tp[j];
				final Offset q = tp[(j + 1) % 3];
				final String key = _edgeKey(p, q);
				edgeCount[key] = (edgeCount[key] ?? 0) + 1;
				edgeEndpoints.putIfAbsent(key, () => (a: p, b: q));
			}
		}
		// 取外圈邊（出現 1 次）
		final List<({Offset a, Offset b})> boundary =
				<({Offset a, Offset b})>[];
		for (final MapEntry<String, int> e in edgeCount.entries) {
			if (e.value == 1) {
				boundary.add(edgeEndpoints[e.key]!);
			}
		}
		if (boundary.isEmpty) return null;
		// 把無向邊集串成有序 polygon
		// 方法：用「頂點 quantize key → 連到此頂點的邊」反查表
		final Map<String, List<int>> vertToEdges = <String, List<int>>{};
		String vkey(Offset o) =>
				"${(o.dx * 10).round()},${(o.dy * 10).round()}";
		for (int i = 0; i < boundary.length; i++) {
			vertToEdges.putIfAbsent(vkey(boundary[i].a), () => <int>[]).add(i);
			vertToEdges.putIfAbsent(vkey(boundary[i].b), () => <int>[]).add(i);
		}
		// 串接：從第 0 條邊的 a 開始
		final List<Offset> poly = <Offset>[];
		final Set<int> usedEdges = <int>{};
		Offset cursor = boundary[0].a;
		poly.add(cursor);
		while (usedEdges.length < boundary.length) {
			final List<int> candidateEdges = vertToEdges[vkey(cursor)] ?? <int>[];
			int? nextEdge;
			Offset? nextVert;
			for (final int eIdx in candidateEdges) {
				if (usedEdges.contains(eIdx)) continue;
				final ({Offset a, Offset b}) e = boundary[eIdx];
				if (vkey(e.a) == vkey(cursor)) {
					nextEdge = eIdx;
					nextVert = e.b;
					break;
				}
				if (vkey(e.b) == vkey(cursor)) {
					nextEdge = eIdx;
					nextVert = e.a;
					break;
				}
			}
			if (nextEdge == null || nextVert == null) {
				// 串接失敗（退化、有洞）— 回傳當前累積、呼叫端可拒絕
				return null;
			}
			usedEdges.add(nextEdge);
			// 如果 nextVert 已是 poly 起點、迴圈閉合
			if (vkey(nextVert) == vkey(poly.first)) {
				if (usedEdges.length == boundary.length) {
					return poly;
				}
				// 否則表示外圈有多個 disconnected component → 不該發生、拒絕
				return null;
			}
			poly.add(nextVert);
			cursor = nextVert;
		}
		return poly;
	}

	/// 邊端點對的 quantized key（與 puzzle_cutter / cell_planner 一致）。
	static String _edgeKey(Offset a, Offset b) {
		final String ka = "${(a.dx * 10).round()},${(a.dy * 10).round()}";
		final String kb = "${(b.dx * 10).round()},${(b.dy * 10).round()}";
		return ka.compareTo(kb) <= 0 ? "$ka|$kb" : "$kb|$ka";
	}

	// === Delaunay 三角化（複製自 VoronoiBuilder、簡化版本） ===

	/// 對 [points] 做 Delaunay 三角化、回傳三角形列表（以 points 索引描述）。
	static List<_Triangle> _delaunay(List<Offset> points) {
		final int n = points.length;
		if (n < 3) return <_Triangle>[];

		double minX = double.infinity, minY = double.infinity;
		double maxX = -double.infinity, maxY = -double.infinity;
		for (final Offset p in points) {
			if (p.dx < minX) minX = p.dx;
			if (p.dy < minY) minY = p.dy;
			if (p.dx > maxX) maxX = p.dx;
			if (p.dy > maxY) maxY = p.dy;
		}
		final double dx = maxX - minX;
		final double dy = maxY - minY;
		final double deltaMax = max(dx, dy) * 10;
		final double midX = (minX + maxX) / 2;
		final double midY = (minY + maxY) / 2;
		final Offset st1 = Offset(midX - 20 * deltaMax, midY - deltaMax);
		final Offset st2 = Offset(midX, midY + 20 * deltaMax);
		final Offset st3 = Offset(midX + 20 * deltaMax, midY - deltaMax);
		final List<Offset> pts = <Offset>[...points, st1, st2, st3];
		final int stA = n;
		final int stB = n + 1;
		final int stC = n + 2;

		final List<_Triangle> triangles = <_Triangle>[_Triangle(stA, stB, stC)];

		for (int i = 0; i < n; i++) {
			final Offset p = pts[i];
			final List<_Triangle> bad = <_Triangle>[];
			for (final _Triangle t in triangles) {
				if (_inCircumcircle(pts[t.a], pts[t.b], pts[t.c], p)) {
					bad.add(t);
				}
			}
			final List<_Edge> polygon = <_Edge>[];
			for (final _Triangle t in bad) {
				for (final _Edge e in <_Edge>[
					_Edge(t.a, t.b),
					_Edge(t.b, t.c),
					_Edge(t.c, t.a),
				]) {
					int sharedCount = 0;
					for (final _Triangle u in bad) {
						if (identical(u, t)) continue;
						if (_triangleHasEdge(u, e)) sharedCount++;
					}
					if (sharedCount == 0) polygon.add(e);
				}
			}
			triangles.removeWhere(bad.contains);
			for (final _Edge e in polygon) {
				triangles.add(_Triangle(e.a, e.b, i));
			}
		}

		triangles.removeWhere((_Triangle t) =>
				t.a >= n || t.b >= n || t.c >= n);
		return triangles;
	}

	static bool _inCircumcircle(Offset a, Offset b, Offset c, Offset p) {
		final double ax = a.dx - p.dx;
		final double ay = a.dy - p.dy;
		final double bx = b.dx - p.dx;
		final double by = b.dy - p.dy;
		final double cx = c.dx - p.dx;
		final double cy = c.dy - p.dy;
		final double det = (ax * ax + ay * ay) * (bx * cy - cx * by) -
				(bx * bx + by * by) * (ax * cy - cx * ay) +
				(cx * cx + cy * cy) * (ax * by - bx * ay);
		final double cross = (b.dx - a.dx) * (c.dy - a.dy) -
				(b.dy - a.dy) * (c.dx - a.dx);
		return cross > 0 ? det > 0 : det < 0;
	}

	static bool _triangleHasEdge(_Triangle t, _Edge e) {
		final Set<int> verts = <int>{t.a, t.b, t.c};
		return verts.contains(e.a) && verts.contains(e.b);
	}
}

class _Triangle {
	const _Triangle(this.a, this.b, this.c);
	final int a;
	final int b;
	final int c;
}

class _Edge {
	const _Edge(this.a, this.b);
	final int a;
	final int b;
}
