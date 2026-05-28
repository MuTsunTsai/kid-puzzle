import "dart:math";
import "dart:ui";

import "../../puzzle_dimens.dart";
import "../models/puzzle_edge.dart";
import "../models/puzzle_layout.dart";
import "../models/puzzle_piece.dart";
import "cell_planner.dart";
import "edge_shape.dart";

/// 拼圖切割演算法。
///
/// 把 [CellLayout]（一組任意多邊形 cell）轉換為 [PuzzleLayout]：
/// 包含所有 [PuzzlePiece] 的 sourceRect、polygonAabb、邊資料與封閉 localPath。
///
/// 對「方格 grid」與「Voronoi」兩種模式通用：只要 cell 是有序頂點的 polygon。
class PuzzleCutter {
	PuzzleCutter._();

	/// 浮點數判等容差（pixel）。
	static const double _epsilon = 0.5;

	/// 「耳朵凸出距離過小就強制 flat」的基準門檻（pixel，對應 n = [_protrusionRefN]
	/// 片時的門檻）。實際門檻會依片數動態縮放（見 [_minVisibleProtrusionFor]）：
	/// 片數多 → 每片小 → 耳朵自然短 → 門檻也跟著降低，避免大朋友模式高片數時
	/// 大部分耳朵被吃掉變成全 flat。
	static const double _minVisibleProtrusionBase = 40.0;

	/// 動態門檻的「參考片數」：低於此數時門檻不再放大、固定為 base。
	static const int _protrusionRefN = 6;

	/// 給定片數計算「耳朵過短」門檻。
	///
	/// 採 `base × sqrt(refN / n)`：每片邊長大致與 `sqrt(1/n)` 成比例，
	/// 因此自然 tabSize 也是。例如 n = [_protrusionRefN] → base、
	/// n = 24 → base × 0.5、n = 300 → base × 0.14。
	/// 參考盤面短邊（pixel）。`_minVisibleProtrusionBase` 是「在這個盤面尺寸下」
	/// 的門檻；實際盤面短邊較大 / 較小時、門檻會等比例縮放，讓視覺上的相對大小
	/// 保持一致（手機小窗下不會把更多耳朵吃掉）。
	static const double _protrusionRefShortestSide = 600.0;

	static double _minVisibleProtrusionFor(int pieceCount, Size boardSize) {
		final double scale = boardSize.shortestSide / _protrusionRefShortestSide;
		final double base = _minVisibleProtrusionBase * scale;
		if (pieceCount <= _protrusionRefN) return base;
		return base * sqrt(_protrusionRefN / pieceCount);
	}

	/// 執行切割。
	///
	/// - [boardSize]：拼圖盤總尺寸（含外圈 padding）。
	/// - [boardPadding]：外圈 padding 大小（左右上下相同，pixel）。
	/// - [cellLayout]：來自 [CellPlanner] 的 cell 規劃（cell 頂點為拼圖盤座標）。
	/// - [seed]：用於邊類型決策（tabOut / tabIn）的隨機種子。
	/// - [edgeShape]：拼圖耳形狀。預設為 [kDefaultEdgeShape]。
	static Future<PuzzleLayout> cut({
		required Size boardSize,
		required double boardPadding,
		required CellLayout cellLayout,
		required int seed,
		EdgeShape edgeShape = kDefaultEdgeShape,
	}) async {
		final Random random = Random(seed);

		// 1. 對每個 cell 計算 AABB
		final List<CellPolygon> cells = cellLayout.cells;
		final List<Rect> cellAabb =
				cells.map((CellPolygon c) => c.bounds).toList();

		// 2. 收集邊段：對每個 cell 的每條 polygon 邊，
		//    若有「其他 cell」也擁有反向相同邊 → 共享邊（內部）
		//    否則 → 外圈邊（flat）
		final List<_EdgeSegment> segments = _collectSegments(
			cells: cells,
			innerBounds: cellLayout.innerBounds,
			random: random,
			edgeShape: edgeShape,
			minProtrusion: _minVisibleProtrusionFor(cells.length, boardSize),
		);

		// 2.1 同對 polygon 之間只在「最長」的共用邊保留耳朵、其餘 forceFlat。
		//     這避免兩個鄰居 polygon 之間有多個小耳朵、視覺凌亂。
		_restrictTabsToLongestSharedEdge(cells: cells, segments: segments);

		// 2.2 共用邊鏈端點 C1 平滑：對「兩條 forceFlat segment 在共用點 v 處接合、
		//     且兩條段屬於同對 polygon」的 v、計算 patched cubic control point、
		//     使兩段在 v 處切線同向、視覺上接合成平滑曲線。
		//     僅處理 forceFlat 段（耳朵段不動）。儲存於 [_EdgeSegment.endpointTangent]
		//     attr、供 [_buildSegmentAbsoluteCommands] 使用。
		_smoothChainEndpointTangents(cells: cells, segments: segments);

		// 2.5 計算每個 cell 的鄰居集合（共享至少一條邊的其他 cell idx）。
		final List<Set<int>> neighbors = _computeNeighbors(cells);

		// 2.6 計算每個 cell 的「有耳朵鄰居」集合：共享邊既不是 flat 也不是 forceFlat。
		final List<Set<int>> tabNeighbors =
				_computeTabNeighbors(cells: cells, segments: segments);

		// 3. 為每個 cell 預先準備 segments 與 reversed list（供後續迴圈使用）
		final List<List<_EdgeSegment>> pieceSegmentsList =
				List<List<_EdgeSegment>>.generate(cells.length, (_) => <_EdgeSegment>[]);
		final List<List<bool>> pieceReversedList =
				List<List<bool>>.generate(cells.length, (_) => <bool>[]);
		for (int i = 0; i < cells.length; i++) {
			final CellPolygon cell = cells[i];
			for (int j = 0; j < cell.vertices.length; j++) {
				final Offset a = cell.vertices[j];
				final Offset b = cell.vertices[(j + 1) % cell.vertices.length];
				final _EdgeSegment seg = _findSegment(segments, a, b);
				pieceSegmentsList[i].add(seg);
				pieceReversedList[i].add(!_pointApproxEq(seg.a, a));
			}
		}

		// 3.5 自交修正：把每片切完的 localPath 取出來逐一檢查，若有自交，
		// 對該片所用的「tabSize 最大」兩個 segment 縮 70%；反覆直到全部無自交
		// 或所有 segment 都已被縮到失效。共享 segment 同時影響兩片，互補性
		// 在 segment 層級自動保留。
		await _resolveSelfIntersections(
			cells: cells,
			segments: segments,
			pieceSegmentsList: pieceSegmentsList,
			pieceReversedList: pieceReversedList,
			edgeShape: edgeShape,
		);

		// 4. 為每個 cell 組裝 piece
		final double tabSize = _computeTabSize(cellAabb, edgeShape);
		final List<PuzzlePiece> pieces = <PuzzlePiece>[];
		for (int i = 0; i < cells.length; i++) {
			final CellPolygon cell = cells[i];
			final Rect aabb = cellAabb[i];
			final List<_EdgeSegment> pieceSegments = pieceSegmentsList[i];
			final List<bool> pieceReversed = pieceReversedList[i];

			final Rect sourceRect = _computeSourceRect(
				aabb: aabb,
				segs: pieceSegments,
			);

			final Path localPath = _buildLocalPath(
				cell: cell,
				sourceRect: sourceRect,
				pieceSegments: pieceSegments,
				pieceReversed: pieceReversed,
				edgeShape: edgeShape,
			);

			final List<PuzzleEdge> edges = <PuzzleEdge>[
				for (int j = 0; j < pieceSegments.length; j++)
					PuzzleEdge(
						type: pieceReversed[j]
								? _reverseType(pieceSegments[j].type)
								: pieceSegments[j].type,
						seed: pieceSegments[j].seed,
					),
			];

			pieces.add(PuzzlePiece(
				id: i,
				gridCellId: cell.id,
				polygonAabb: aabb,
				sourceRect: sourceRect,
				edges: edges,
				neighborIds: neighbors[i],
				tabNeighborIds: tabNeighbors[i],
				localPath: localPath,
				currentPosition: sourceRect.topLeft,
				groupId: i,
			));
		}

		return PuzzleLayout(
			pieceCount: cellLayout.pieceCount,
			boardSize: boardSize,
			boardPadding: boardPadding,
			pieces: pieces,
			tabSize: tabSize,
		);
	}

	/// 檢查每片 piece 是否「可鎖定」。
	///
	/// 鎖定條件（見 [SnapDetector._groupTouchesLockedOrFrame]）：
	/// 1. 有任一條 [EdgeType.flat] 邊（= 相鄰邊框）→ 可鎖
	/// 2. 有任一個 tab neighbor（= 透過耳朵相連的鄰居）→ 可鎖（等鄰居先鎖）
	///
	/// 兩條都不滿足的 piece 在「無提示線」模式下永遠進不去鎖定流程，是 bug。
	///
	/// 呼叫端應在拿到 [PuzzleLayout] 後立刻檢查、若 false 就換 seed 重切。
	static bool validateLockability(PuzzleLayout layout) {
		for (final PuzzlePiece p in layout.pieces) {
			final bool hasFlat = p.edges.any((PuzzleEdge e) => e.type == EdgeType.flat);
			if (hasFlat) continue;
			if (p.tabNeighborIds.isNotEmpty) continue;
			// 這片沒有 flat 邊、也沒有 tab neighbor — 永遠進不去鎖定條件
			return false;
		}
		return true;
	}


	/// 對每個 cell 算出鄰居集合（共享至少一條 polygon 邊的其他 cell idx）。
	///
	/// 用「邊端點對 quantized key」分組：兩個 cell 的某條邊端點對 key 相同 → 相鄰。
	static List<Set<int>> _computeNeighbors(List<CellPolygon> cells) {
		// edgeKey -> list of cellIdx
		final Map<String, List<int>> edgeToCells = <String, List<int>>{};
		for (int i = 0; i < cells.length; i++) {
			final List<Offset> verts = cells[i].vertices;
			for (int j = 0; j < verts.length; j++) {
				final String key = _edgeKey(verts[j], verts[(j + 1) % verts.length]);
				edgeToCells.putIfAbsent(key, () => <int>[]).add(i);
			}
		}
		final List<Set<int>> neighbors =
				List<Set<int>>.generate(cells.length, (_) => <int>{});
		for (final List<int> group in edgeToCells.values) {
			if (group.length >= 2) {
				for (int i = 0; i < group.length; i++) {
					for (int j = 0; j < group.length; j++) {
						if (i != j) neighbors[group[i]].add(group[j]);
					}
				}
			}
		}
		return neighbors;
	}

	/// 同對 polygon 之間只在「最長」的共用邊保留耳朵、其餘共用邊強制 forceFlat。
	///
	/// 演算法：
	/// 1. 把每條 polygon 邊歸入 (cellA, cellB) pair（兩 cellIdx 排序、避免雙計）。
	/// 2. 對每個 pair、找出該 pair 共用的所有 segments + 各自長度。
	/// 3. 保留長度最大者、其他 forceFlat。長度相同時取索引最小的（穩定）。
	///
	/// **注意**：外圈邊（半邊只有一個 cell 擁有）不在此步驟處理；它們已在
	/// [_collectSegments] 設為 EdgeType.flat、不受影響。
	static void _restrictTabsToLongestSharedEdge({
		required List<CellPolygon> cells,
		required List<_EdgeSegment> segments,
	}) {
		// edgeKey → segment 索引（用半邊端點對 key、與 _collectSegments 同邏輯）
		final Map<String, int> edgeKeyToSegIdx = <String, int>{};
		for (int i = 0; i < segments.length; i++) {
			final _EdgeSegment s = segments[i];
			edgeKeyToSegIdx[_edgeKey(s.a, s.b)] = i;
		}

		// 對每個 polygon 邊、找出它的 (cellA, cellB) pair（cellA < cellB）。
		// 用 Map<pairKey, List<segIdx>> 收集每對之間的共享 segment 索引。
		// pairKey = "minCellIdx_maxCellIdx"
		final Map<String, List<int>> pairToSegIdxs = <String, List<int>>{};
		// 先建 edgeKey → 屬於哪些 cell（每條邊內部至多 2 個 cell）
		final Map<String, List<int>> edgeKeyToCells = <String, List<int>>{};
		for (int i = 0; i < cells.length; i++) {
			final List<Offset> verts = cells[i].vertices;
			for (int j = 0; j < verts.length; j++) {
				final String key = _edgeKey(verts[j], verts[(j + 1) % verts.length]);
				edgeKeyToCells.putIfAbsent(key, () => <int>[]).add(i);
			}
		}
		// 把「兩 cell 共享」的邊分到對應 pair
		for (final MapEntry<String, List<int>> e in edgeKeyToCells.entries) {
			final List<int> owners = e.value;
			if (owners.length < 2) continue; // 外圈邊、不處理
			final int a = owners[0] < owners[1] ? owners[0] : owners[1];
			final int b = owners[0] < owners[1] ? owners[1] : owners[0];
			final String pairKey = "${a}_$b";
			final int? segIdx = edgeKeyToSegIdx[e.key];
			if (segIdx == null) continue;
			pairToSegIdxs.putIfAbsent(pairKey, () => <int>[]).add(segIdx);
		}

		// 對每對：保留最長邊、其他 forceFlat
		for (final List<int> segIdxs in pairToSegIdxs.values) {
			if (segIdxs.length < 2) continue; // 只有一條共享邊、保留
			// 找最長：以 (segment.a − segment.b).distance 為長度
			int bestIdx = segIdxs[0];
			double bestLen = (segments[bestIdx].a - segments[bestIdx].b).distance;
			for (int k = 1; k < segIdxs.length; k++) {
				final int idx = segIdxs[k];
				final double len =
						(segments[idx].a - segments[idx].b).distance;
				if (len > bestLen) {
					bestLen = len;
					bestIdx = idx;
				}
			}
			// 其他都 forceFlat
			for (final int idx in segIdxs) {
				if (idx == bestIdx) continue;
				segments[idx].forceFlat = true;
				segments[idx].tabSize = 0;
			}
		}
	}

	/// 對「同對 polygon 共用邊鏈中、兩條 forceFlat 段於共用點接合」的點 v、
	/// 在兩條段各自的端點切線（[_EdgeSegment.tangentAtA] / [tangentAtB]）寫入
	/// 共同的平滑方向、使兩段在 v 處 C1 連續、視覺看起來像一條平滑曲線。
	///
	/// 規則：
	/// - 兩條 segment 必須屬於同一對 polygon（A、B 共用）。
	/// - 兩條 segment 都是 forceFlat（baseline-only、無耳朵）。
	/// - 共用點 v 是兩段的共同端點。
	///
	/// 共同方向：兩條段「指向 v 外側」單位向量的平均；長度 = `min(兩段長度) / 3`。
	static void _smoothChainEndpointTangents({
		required List<CellPolygon> cells,
		required List<_EdgeSegment> segments,
	}) {
		// 建立 segment → 所屬 cell pair（兩 cell idx、外圈邊則只有一個）。
		final Map<String, List<int>> edgeKeyToCells = <String, List<int>>{};
		for (int i = 0; i < cells.length; i++) {
			final List<Offset> verts = cells[i].vertices;
			for (int j = 0; j < verts.length; j++) {
				final String key = _edgeKey(verts[j], verts[(j + 1) % verts.length]);
				edgeKeyToCells.putIfAbsent(key, () => <int>[]).add(i);
			}
		}
		// segment 索引 → 該段擁有者 cell 集合
		final Map<int, Set<int>> segToCells = <int, Set<int>>{};
		for (int i = 0; i < segments.length; i++) {
			final String key = _edgeKey(segments[i].a, segments[i].b);
			segToCells[i] = (edgeKeyToCells[key] ?? <int>[]).toSet();
		}

		// 頂點 key → 屬於該頂點的 segment 索引集合
		String vkey(Offset o) =>
				"${o.dx.toStringAsFixed(2)},${o.dy.toStringAsFixed(2)}";
		final Map<String, List<int>> vertexToSegs = <String, List<int>>{};
		for (int i = 0; i < segments.length; i++) {
			vertexToSegs.putIfAbsent(vkey(segments[i].a), () => <int>[]).add(i);
			vertexToSegs.putIfAbsent(vkey(segments[i].b), () => <int>[]).add(i);
		}

		// 對每個頂點處理：若該頂點接兩條同對 polygon 共用 segment、且至少一條
		// 是無耳朵（forceFlat/flat），就 smooth。兩條都有耳朵時不 smooth（避免
		// 動到耳朵段的視覺特徵）；但只要有一條無耳朵、就為「兩條」都寫入切線
		// —— 耳朵段的進耳前/出耳後 baseline 也會跟著平滑接合鄰居。
		for (final MapEntry<String, List<int>> entry in vertexToSegs.entries) {
			final List<int> segIdxs = entry.value;
			if (segIdxs.length != 2) continue; // 只處理「該頂點剛好接兩條 segment」的
			final int idxA = segIdxs[0];
			final int idxB = segIdxs[1];
			final _EdgeSegment segA = segments[idxA];
			final _EdgeSegment segB = segments[idxB];
			final bool aIsFlat =
					segA.forceFlat || segA.type == EdgeType.flat;
			final bool bIsFlat =
					segB.forceFlat || segB.type == EdgeType.flat;
			// 至少一條無耳朵才 smooth（兩條都有耳朵 = 兩塊長耳之間的接點、不動）
			if (!aIsFlat && !bIsFlat) continue;
			// 必須是「內部共用邊」（屬於兩個 cell）且兩段屬於同對 cells
			final Set<int> cellsA = segToCells[idxA] ?? <int>{};
			final Set<int> cellsB = segToCells[idxB] ?? <int>{};
			if (cellsA.length != 2 || cellsB.length != 2) continue;
			if (!_setsEqual(cellsA, cellsB)) continue;

			// 計算共用點位置（用 segA 的端點之一、與 vkey 對應）
			final Offset vPos =
					(vkey(segA.a) == entry.key) ? segA.a : segA.b;

			// 兩段「指向 v 外側」單位向量
			final Offset outA = _farEndpointDir(segA, vPos);
			final Offset outB = _farEndpointDir(segB, vPos);
			// 平均：因為兩個 outDir 都指向各自的「另一端」、平均後是「鏈在 v
			// 的平均切線方向（指向 segA 的另一端方向）」。
			// 為了讓「segA 在 v 處切線 = +avg、segB 在 v 處切線 = -avg」、我們
			// 用「outA - outB」的方向（兩切線反向）。
			final Offset avgDir = _normalize(outA - outB);
			// 切線長度：min(兩段長) / 3
			final double lenA = (segA.b - segA.a).distance;
			final double lenB = (segB.b - segB.a).distance;
			final double tangentLen = (lenA < lenB ? lenA : lenB) / 3.0;

			// 對 segA 在 v 點的切線：應該指向 segA 的「另一端」、即 outA 方向。
			// 但我們要把 outA 替換為與 avgDir 同向（外推方向）。
			// outA 朝 segA 另一端、outB 朝 segB 另一端、兩者反向（沿 avgDir）。
			// segA 在 v 處切線 = + avgDir（朝 segA 的另一端）或 - avgDir（朝 segB）
			// 用 dot product 決定方向：若 outA · avgDir > 0、則 segA 在 v 用 +avgDir。
			final double sgnA = outA.dx * avgDir.dx + outA.dy * avgDir.dy >= 0 ? 1 : -1;
			final double sgnB = outB.dx * avgDir.dx + outB.dy * avgDir.dy >= 0 ? 1 : -1;
			final Offset tangentForA = Offset(avgDir.dx * sgnA, avgDir.dy * sgnA);
			final Offset tangentForB = Offset(avgDir.dx * sgnB, avgDir.dy * sgnB);

			// 寫入 segA / segB 對應端點（a 或 b）
			if (vkey(segA.a) == entry.key) {
				segA.tangentAtA = tangentForA;
				segA.tangentLenAtA = tangentLen;
			} else {
				segA.tangentAtB = tangentForA;
				segA.tangentLenAtB = tangentLen;
			}
			if (vkey(segB.a) == entry.key) {
				segB.tangentAtA = tangentForB;
				segB.tangentLenAtA = tangentLen;
			} else {
				segB.tangentAtB = tangentForB;
				segB.tangentLenAtB = tangentLen;
			}
		}
	}

	/// 從 segment 的指定端點 [v] 看「另一端」的單位方向向量。
	static Offset _farEndpointDir(_EdgeSegment seg, Offset v) {
		final Offset far = (seg.a == v) ? seg.b : seg.a;
		return _normalize(far - v);
	}

	/// 單位向量（零向量 → 回 (1, 0)）。
	static Offset _normalize(Offset o) {
		final double len = sqrt(o.dx * o.dx + o.dy * o.dy);
		if (len < 1e-9) return const Offset(1, 0);
		return Offset(o.dx / len, o.dy / len);
	}

	static bool _setsEqual(Set<int> a, Set<int> b) {
		if (a.length != b.length) return false;
		for (final int x in a) {
			if (!b.contains(x)) return false;
		}
		return true;
	}

	/// 計算每個 cell 的「有耳朵鄰居」子集合：共享邊類型既不是 flat、segment
	/// 也沒有被標記 forceFlat 的鄰居。snap_detector 只允許這類鄰居融合。
	static List<Set<int>> _computeTabNeighbors({
		required List<CellPolygon> cells,
		required List<_EdgeSegment> segments,
	}) {
		// edgeKey -> 該邊上的 cellIdx list（與 _computeNeighbors 同樣 key 規則）
		final Map<String, List<int>> edgeToCells = <String, List<int>>{};
		for (int i = 0; i < cells.length; i++) {
			final List<Offset> verts = cells[i].vertices;
			for (int j = 0; j < verts.length; j++) {
				final String key = _edgeKey(verts[j], verts[(j + 1) % verts.length]);
				edgeToCells.putIfAbsent(key, () => <int>[]).add(i);
			}
		}
		// edgeKey -> segment（用 segment 端點對算 key）
		final Map<String, _EdgeSegment> edgeToSeg = <String, _EdgeSegment>{
			for (final _EdgeSegment s in segments) _edgeKey(s.a, s.b): s,
		};

		final List<Set<int>> tabNeighbors =
				List<Set<int>>.generate(cells.length, (_) => <int>{});
		for (final MapEntry<String, List<int>> entry in edgeToCells.entries) {
			final List<int> group = entry.value;
			if (group.length < 2) continue;
			final _EdgeSegment? seg = edgeToSeg[entry.key];
			if (seg == null) continue;
			final bool hasTab = seg.type != EdgeType.flat && !seg.forceFlat;
			if (!hasTab) continue;
			for (int i = 0; i < group.length; i++) {
				for (int j = 0; j < group.length; j++) {
					if (i != j) tabNeighbors[group[i]].add(group[j]);
				}
			}
		}
		return tabNeighbors;
	}

	/// 反覆檢查每片 localPath 是否有「自交或過近」；若有，找出實際衝突的兩個
	/// segment、把這兩條中較大者縮 [shrinkFactor]（70%）。直到全部無衝突
	/// 或所有 segment 都已縮到 ~0。
	///
	/// 共享 segment 的縮減會同時影響另一片，互補性自動保留。
	/// 排程旗標：把同步呼叫者短路成 sync，給 [cut] 的 async 版用 false。
	static Future<void> _resolveSelfIntersections({
		required List<CellPolygon> cells,
		required List<_EdgeSegment> segments,
		required List<List<_EdgeSegment>> pieceSegmentsList,
		required List<List<bool>> pieceReversedList,
		required EdgeShape edgeShape,
	}) async {
		const double shrinkFactor = 0.9;
		const int maxIterations = 200;
		// 每處理 [yieldEveryCells] 個 cell 就 yield 一次；高片數時即使單個
		// iter 也可能跑掉一個 frame budget，要在內層中斷。
		const int yieldEveryCells = 30;

		for (int iter = 0; iter < maxIterations; iter++) {
			bool anyFixed = false;
			for (int i = 0; i < cells.length; i++) {
				if (i > 0 && i % yieldEveryCells == 0) {
					await Future<void>.delayed(Duration.zero);
				}
				final List<_EdgeSegment> pieceSegments = pieceSegmentsList[i];
				final (int, int)? conflict = _findPieceConflict(
					cell: cells[i],
					pieceSegments: pieceSegments,
					pieceReversed: pieceReversedList[i],
					edgeShape: edgeShape,
				);
				if (conflict == null) continue;
				anyFixed = true;
				// 衝突的兩條 segment 一起縮（平均分擔），避免反覆只壓榨單一條
				// 變得極小而另一條完好的視覺不平衡。
				final List<_EdgeSegment> candidates = <_EdgeSegment>[
					pieceSegments[conflict.$1],
					pieceSegments[conflict.$2],
				];
				bool anyShrunk = false;
				for (final _EdgeSegment s in candidates) {
					if (s.forceFlat ||
							s.type == EdgeType.flat ||
							s.tabSize <= 0.01) {
						continue;
					}
					s.tabSize *= shrinkFactor;
					s.widthShrinkRatio *= shrinkFactor;
					if (s.tabSize < 0.5 || s.widthShrinkRatio < 0.05) {
						s.tabSize = 0;
						s.widthShrinkRatio = 0;
						s.forceFlat = true;
					}
					anyShrunk = true;
				}
				if (!anyShrunk) {
					continue;
				}
			}
			if (!anyFixed) return;
			// 一輪結束後 yield，讓 UI 趁機畫 1 個 frame。
			await Future<void>.delayed(Duration.zero);
		}
	}

	/// 把一片的 localPath flatten 成多邊形頂點序列，找出第一個「過近或相交」
	/// 的跨 segment 對；回傳那兩條 segment 在 [pieceSegments] 中的索引。
	/// 無衝突回 null。
	///
	/// **判定標準**：跨「不同 segment」的採樣段最短距離 < `clearance`
	/// （= 該片所有 segment 中最小 tabSize × 0.15）。
	///
	/// 採樣點都標上 segment index；只在「兩採樣段完全屬於不同 segment」之間
	/// 比較，徹底排除同一條 segment 內的天然小距離。
	static (int, int)? _findPieceConflict({
		required CellPolygon cell,
		required List<_EdgeSegment> pieceSegments,
		required List<bool> pieceReversed,
		required EdgeShape edgeShape,
	}) {
		// 把每條 segment 採樣成多邊形點 + 對應的 segment index + isTab 標記。
		// isTab=true 表示「該採樣點落在耳朵兩段 cubic 上」，反之為 baseline。
		final List<Offset> poly = <Offset>[];
		final List<int> segIdx = <int>[];
		final List<bool> isTab = <bool>[];
		poly.add(cell.vertices.first);
		segIdx.add(0);
		isTab.add(false); // polygon 起點本身不在耳朵裡
		for (int j = 0; j < pieceSegments.length; j++) {
			final _EdgeSegment seg = pieceSegments[j];
			final bool reversed = pieceReversed[j];
			final List<EdgeCommand> abs = _buildSegmentAbsoluteCommands(
				seg: seg,
				edgeShape: edgeShape,
			);
			final List<bool> sampledIsTab = <bool>[];
			final List<Offset> sampled = _flattenAbsCommands(
				absCommands: abs,
				start: seg.a,
				reversed: reversed,
				outIsTab: sampledIsTab,
			);
			for (int k = 0; k < sampled.length; k++) {
				poly.add(sampled[k]);
				segIdx.add(j);
				isTab.add(sampledIsTab[k]);
			}
		}
		if (poly.length > 2 &&
				_pointApproxEq(poly.first, poly.last)) {
			poly.removeLast();
			segIdx.removeLast();
			isTab.removeLast();
		}

		final int n = poly.length;
		if (n < 4) return null;

		for (int i = 0; i < n; i++) {
			final int si = segIdx[i];
			final int sj0 = segIdx[(i + 1) % n];
			final bool tabA1 = isTab[i];
			final bool tabA2 = isTab[(i + 1) % n];
			final Offset p1 = poly[i];
			final Offset p2 = poly[(i + 1) % n];
			for (int j = i + 1; j < n; j++) {
				final int jm = j % n;
				final int sk = segIdx[jm];
				final int sl = segIdx[(jm + 1) % n];
				if (si == sk && si == sl) continue;
				if (sj0 == sk && sj0 == sl) continue;
				final bool tabB1 = isTab[jm];
				final bool tabB2 = isTab[(jm + 1) % n];
				final bool sideAHasTab = tabA1 || tabA2;
				final bool sideBHasTab = tabB1 || tabB2;
				if (!sideAHasTab && !sideBHasTab) continue;
				// clearance 用「該對中有耳朵那條的 tabSize」當尺度。耳朵小 →
				// clearance 小、不會吞掉本來就該有的鄰近距離；耳朵大 → clearance
				// 大、抓得到視覺融合。同對兩條都有耳朵時取大者。
				double pairTabSize = 0;
				if (sideAHasTab) {
					final _EdgeSegment s = pieceSegments[si];
					if (!s.forceFlat &&
							s.type != EdgeType.flat &&
							s.tabSize > pairTabSize) {
						pairTabSize = s.tabSize;
					}
				}
				if (sideBHasTab) {
					final _EdgeSegment s = pieceSegments[sk];
					if (!s.forceFlat &&
							s.type != EdgeType.flat &&
							s.tabSize > pairTabSize) {
						pairTabSize = s.tabSize;
					}
				}
				if (pairTabSize <= 0) continue;
				final double clearance = pairTabSize * 1.2;
				final Offset p3 = poly[jm];
				final Offset p4 = poly[(jm + 1) % n];
				if (_segmentsTooClose(p1, p2, p3, p4, clearance)) {
					return (si, sk);
				}
			}
		}
		return null;
	}

	/// 把絕對座標的 EdgeCommand 序列展開成多邊形採樣點（不含起點，含每段終點，
	/// cubicTo 採樣 [_cubicSamples] 段）。每個採樣點同步在 [outIsTab] 寫入它
	/// 來自的指令的 [EdgeCommand.isTab]，供 _findPieceConflict 區分耳朵 / baseline。
	///
	/// 若 [reversed]，按反向順序輸出（拆解 cubic 反向：終點變起點、控制點互換）。
	static List<Offset> _flattenAbsCommands({
		required List<EdgeCommand> absCommands,
		required Offset start,
		required bool reversed,
		List<bool>? outIsTab,
	}) {
		const int cubicSamples = 8;
		final List<Offset> result = <Offset>[];

		if (!reversed) {
			Offset cursor = start;
			for (final EdgeCommand cmd in absCommands) {
				if (cmd is LineToCmd) {
					final Offset end = Offset(cmd.x, cmd.y);
					result.add(end);
					outIsTab?.add(cmd.isTab);
					cursor = end;
				} else if (cmd is CubicToCmd) {
					final Offset c1 = Offset(cmd.c1x, cmd.c1y);
					final Offset c2 = Offset(cmd.c2x, cmd.c2y);
					final Offset end = Offset(cmd.x, cmd.y);
					for (int s = 1; s <= cubicSamples; s++) {
						final double t = s / cubicSamples;
						result.add(_cubicAt(cursor, c1, c2, end, t));
						outIsTab?.add(cmd.isTab);
					}
					cursor = end;
				}
			}
		} else {
			// 反向：先求每段在「正向」下的起點 list
			final List<Offset> starts = <Offset>[start];
			Offset cursor = start;
			for (final EdgeCommand cmd in absCommands) {
				if (cmd is LineToCmd) {
					cursor = Offset(cmd.x, cmd.y);
				} else if (cmd is CubicToCmd) {
					cursor = Offset(cmd.x, cmd.y);
				}
				starts.add(cursor);
			}
			// 從最後一段倒著走：每段「新終點」= 該段在正向時的起點
			for (int k = absCommands.length - 1; k >= 0; k--) {
				final EdgeCommand cmd = absCommands[k];
				final Offset origStart = starts[k];
				final Offset origEnd = starts[k + 1];
				if (cmd is LineToCmd) {
					result.add(origStart);
					outIsTab?.add(cmd.isTab);
				} else if (cmd is CubicToCmd) {
					// 反向 cubic：起 = origEnd、控制點互換、終 = origStart
					final Offset c2 = Offset(cmd.c1x, cmd.c1y);
					final Offset c1 = Offset(cmd.c2x, cmd.c2y);
					for (int s = 1; s <= cubicSamples; s++) {
						final double t = s / cubicSamples;
						result.add(_cubicAt(origEnd, c1, c2, origStart, t));
						outIsTab?.add(cmd.isTab);
					}
				}
			}
		}
		return result;
	}

	/// 三次貝茲在 t∈[0,1] 處的位置。
	static Offset _cubicAt(Offset p0, Offset p1, Offset p2, Offset p3, double t) {
		final double u = 1 - t;
		final double w0 = u * u * u;
		final double w1 = 3 * u * u * t;
		final double w2 = 3 * u * t * t;
		final double w3 = t * t * t;
		return Offset(
			w0 * p0.dx + w1 * p1.dx + w2 * p2.dx + w3 * p3.dx,
			w0 * p0.dy + w1 * p1.dy + w2 * p2.dy + w3 * p3.dy,
		);
	}

	/// 兩條線段 (p1,p2) 與 (p3,p4) 的最短距離是否 < [clearance]。
	///
	/// 真正相交 → 距離 = 0 → 必然回 true。沒交但已經很近也回 true。
	/// 線段最短距離 = 四個「端點到對面線段」距離的最小值（若不相交）。
	static bool _segmentsTooClose(
		Offset p1,
		Offset p2,
		Offset p3,
		Offset p4,
		double clearance,
	) {
		// 先快速檢查是否相交（距離 = 0）
		final double rx = p2.dx - p1.dx;
		final double ry = p2.dy - p1.dy;
		final double sx = p4.dx - p3.dx;
		final double sy = p4.dy - p3.dy;
		final double denom = rx * sy - ry * sx;
		if (denom.abs() > 1e-9) {
			final double dx = p3.dx - p1.dx;
			final double dy = p3.dy - p1.dy;
			final double t = (dx * sy - dy * sx) / denom;
			final double u = (dx * ry - dy * rx) / denom;
			if (t > 0 && t < 1 && u > 0 && u < 1) return true;
		}
		// 不相交：取四個端點到對面線段距離的最小值
		final double d1 = _pointToSegmentDistance(p1, p3, p4);
		if (d1 < clearance) return true;
		final double d2 = _pointToSegmentDistance(p2, p3, p4);
		if (d2 < clearance) return true;
		final double d3 = _pointToSegmentDistance(p3, p1, p2);
		if (d3 < clearance) return true;
		final double d4 = _pointToSegmentDistance(p4, p1, p2);
		if (d4 < clearance) return true;
		return false;
	}

	/// 點 [p] 到線段 [a]-[b] 的最短距離。
	static double _pointToSegmentDistance(Offset p, Offset a, Offset b) {
		final double abx = b.dx - a.dx;
		final double aby = b.dy - a.dy;
		final double len2 = abx * abx + aby * aby;
		if (len2 < 1e-12) {
			// 退化為點
			final double ddx = p.dx - a.dx;
			final double ddy = p.dy - a.dy;
			return sqrt(ddx * ddx + ddy * ddy);
		}
		final double apx = p.dx - a.dx;
		final double apy = p.dy - a.dy;
		double t = (apx * abx + apy * aby) / len2;
		if (t < 0) t = 0;
		if (t > 1) t = 1;
		final double fx = a.dx + t * abx - p.dx;
		final double fy = a.dy + t * aby - p.dy;
		return sqrt(fx * fx + fy * fy);
	}

	/// PuzzleLayout.tabSize 摘要：取所有 cell 中最短邊套用 edgeShape 自然 tabSize。
	static double _computeTabSize(List<Rect> aabb, EdgeShape edgeShape) {
		double minSide = double.infinity;
		for (final Rect r in aabb) {
			if (r.width < minSide) minSide = r.width;
			if (r.height < minSide) minSide = r.height;
		}
		return edgeShape.naturalTabSizeFor(minSide);
	}

	/// 對每對 cell 的相鄰 polygon 邊建 segment。
	///
	/// 演算法：
	/// 1. 對每個 cell 的每條 polygon 邊 (a, b)，產生一個「半邊」(cellIdx, a, b)
	/// 2. 依「端點對的排序」分組：同一條物理邊的兩個半邊會分在一起
	/// 3. 對每組：
	///    - 兩個半邊 → 內部邊（兩個 cell 共享），type 隨機 tabOut/tabIn
	///    - 一個半邊 → 外圈邊（單獨）。type=flat、bulge=0
	static List<_EdgeSegment> _collectSegments({
		required List<CellPolygon> cells,
		required Rect innerBounds,
		required Random random,
		required EdgeShape edgeShape,
		required double minProtrusion,
	}) {
		// 用「邊端點對的 quantized key」對半邊分組
		final Map<String, List<({int cellIdx, Offset a, Offset b})>> groups =
				<String, List<({int cellIdx, Offset a, Offset b})>>{};
		for (int i = 0; i < cells.length; i++) {
			final List<Offset> verts = cells[i].vertices;
			for (int j = 0; j < verts.length; j++) {
				final Offset a = verts[j];
				final Offset b = verts[(j + 1) % verts.length];
				final String key = _edgeKey(a, b);
				groups.putIfAbsent(key, () => <({int cellIdx, Offset a, Offset b})>[])
						.add((cellIdx: i, a: a, b: b));
			}
		}

		final List<_EdgeSegment> segments = <_EdgeSegment>[];
		for (final List<({int cellIdx, Offset a, Offset b})> group in groups.values) {
			if (group.length >= 2) {
				// 內部邊（兩半邊共享）：用第一個半邊的 (a, b) 作為正向，type 隨機
				final ({int cellIdx, Offset a, Offset b}) first = group.first;
				final EdgeType type =
						random.nextBool() ? EdgeType.tabOut : EdgeType.tabIn;
				// AABB 短邊 → tabIn 那片 cell 的 AABB shortestSide
				// type=tabOut 表示「first cell 從邊往外凸」→ 另一片是 tabIn
				// type=tabIn 表示 first cell 凹進去 → first 自己是 tabIn 側
				final int tabInCellIdx = type == EdgeType.tabIn
						? first.cellIdx
						: group[1].cellIdx;
				final double tabInShortSide = cells[tabInCellIdx].bounds.shortestSide;

				final double segLen = (first.b - first.a).distance;
				final double naturalTabSize = edgeShape.naturalTabSizeFor(segLen);
				final double maxProtrusion =
						tabInShortSide * PuzzleDimens.maxTabProtrusionRatio;
				final double tabSize =
						edgeShape.clampTabSize(naturalTabSize, maxProtrusion);

				// 太短的邊強制 flat（耳朵會小到視覺辨識不出來）：以「實際 tabSize
				// 換算的凸出距離」< minProtrusion 為準。tabSize 本身已被鄰片短邊
				// 上限夾過，再用換算後的凸出距離判斷視覺可見性才合理。門檻隨片數
				// 動態縮放（見 [_minVisibleProtrusionFor]），高片數時不會把所有
				// 自然較短的耳朵都吃掉。
				final double protrusion = edgeShape.protrusionFromTabSize(tabSize);
				final bool tooShort = protrusion < minProtrusion;

				// baseline bulge：[-segLen × max, +segLen × max] 隨機
				final double maxBulgeRatio = edgeShape is ClassicTabShape
						? edgeShape.baselineBulgeMaxRatio
						: 0.06;
				final double baselineBulge =
						(random.nextDouble() * 2 - 1) * segLen * maxBulgeRatio;

				segments.add(_EdgeSegment(
					a: first.a,
					b: first.b,
					type: type,
					tabSize: tabSize,
					baselineBulge: baselineBulge,
					forceFlat: tooShort,
					seed: random.nextInt(0x7FFFFFFF),
				));
			} else {
				// 外圈邊：單獨半邊（在 innerBounds 邊上）
				final ({int cellIdx, Offset a, Offset b}) only = group.first;
				segments.add(_EdgeSegment(
					a: only.a,
					b: only.b,
					type: EdgeType.flat,
					tabSize: 0,
					baselineBulge: 0,
					forceFlat: false,
					seed: 0,
				));
			}
		}
		return segments;
	}

	/// 把端點對量化成 key，正反向視為同一邊。
	static String _edgeKey(Offset a, Offset b) {
		final String ka = "${a.dx.toStringAsFixed(2)},${a.dy.toStringAsFixed(2)}";
		final String kb = "${b.dx.toStringAsFixed(2)},${b.dy.toStringAsFixed(2)}";
		return ka.compareTo(kb) < 0 ? "$ka|$kb" : "$kb|$ka";
	}

	static bool _pointApproxEq(Offset p, Offset q) =>
			(p.dx - q.dx).abs() < _epsilon && (p.dy - q.dy).abs() < _epsilon;

	/// 根據端點找對應 segment。
	static _EdgeSegment _findSegment(
		List<_EdgeSegment> segments,
		Offset a,
		Offset b,
	) {
		for (final _EdgeSegment s in segments) {
			if ((_pointApproxEq(s.a, a) && _pointApproxEq(s.b, b)) ||
					(_pointApproxEq(s.a, b) && _pointApproxEq(s.b, a))) {
				return s;
			}
		}
		throw StateError("segment not found for edge ($a, $b)");
	}

	/// 計算 sourceRect：AABB 外擴 `shortestSide / 2`（簡單粗放策略）。
	///
	/// 如果所有邊都是 flat（外圈 piece），則該方向不外擴。
	static Rect _computeSourceRect({
		required Rect aabb,
		required List<_EdgeSegment> segs,
	}) {
		// 簡化：只要有任何「非 flat 或非零 bulge」段，整個 piece 就外擴
		// shortestSide/2（夠大、不會切到 path）。完全 flat 不外擴。
		bool hasCurvature = false;
		for (final _EdgeSegment s in segs) {
			if (s.type != EdgeType.flat || s.baselineBulge != 0) {
				hasCurvature = true;
				break;
			}
		}
		if (!hasCurvature) return aabb;
		final double expand = aabb.shortestSide / 2;
		return Rect.fromLTRB(
			aabb.left - expand,
			aabb.top - expand,
			aabb.right + expand,
			aabb.bottom + expand,
		);
	}

	/// 建構封閉 localPath：以 sourceRect.topLeft 為原點。
	static Path _buildLocalPath({
		required CellPolygon cell,
		required Rect sourceRect,
		required List<_EdgeSegment> pieceSegments,
		required List<bool> pieceReversed,
		required EdgeShape edgeShape,
	}) {
		final Path path = Path();
		final Offset offset = -Offset(sourceRect.left, sourceRect.top);

		// 從 polygon 第一個頂點開始（localPath 座標）
		final Offset start = cell.vertices.first + offset;
		path.moveTo(start.dx, start.dy);

		for (int j = 0; j < pieceSegments.length; j++) {
			final _EdgeSegment seg = pieceSegments[j];
			final bool reversed = pieceReversed[j];
			_appendSegment(
				path: path,
				seg: seg,
				reversed: reversed,
				offset: offset,
				edgeShape: edgeShape,
			);
		}

		path.close();
		return path;
	}

	/// 把單一 segment 加入 path。
	///
	/// segment 的「正向」= 從 a 走到 b。畫的時候：
	/// 1. 在絕對座標中產出該段的指令列（從 a 到 b）
	/// 2. 若 piece 對該段是反向（從 b 走到 a），反向播放指令列
	/// 3. 套用 offset 轉成 localPath 座標
	static void _appendSegment({
		required Path path,
		required _EdgeSegment seg,
		required bool reversed,
		required Offset offset,
		required EdgeShape edgeShape,
	}) {
		final List<EdgeCommand> absCommands = _buildSegmentAbsoluteCommands(
			seg: seg,
			edgeShape: edgeShape,
		);
		if (reversed) {
			_appendReversedCommands(path, absCommands, offset, seg);
		} else {
			_appendForwardCommands(path, absCommands, offset);
		}
	}

	/// 在拼圖盤絕對座標中產出段的指令列（從 seg.a 到 seg.b）。
	///
	/// segment 的局部座標系：
	/// - 沿邊方向（axisX）= (b - a) 單位向量
	/// - 法線方向（axisY，從邊指向「左側」、用於正向視角）= 把 axisX 旋轉 +90°
	///
	/// EdgeShape 內 y 為負代表 tabOut（向 EdgeShape -Y）。
	/// 我們希望「tabOut 朝段的『正向左側』凸出」=朝 axisY 正方向。
	/// 所以 EdgeShape -Y 對應 +axisY → y 映射 = -axisY。
	static List<EdgeCommand> _buildSegmentAbsoluteCommands({
		required _EdgeSegment seg,
		required EdgeShape edgeShape,
	}) {
		final double dx = seg.b.dx - seg.a.dx;
		final double dy = seg.b.dy - seg.a.dy;
		final double len = sqrt(dx * dx + dy * dy);
		if (len < 1e-9) return <EdgeCommand>[];
		final Offset axisX = Offset(dx / len, dy / len);
		// 旋轉 +90°（CCW）: (x, y) → (-y, x)
		final Offset axisY = Offset(-axisX.dy, axisX.dx);

		final List<EdgeCommand> rel = edgeShape.build(
			length: len,
			tabSize: seg.tabSize,
			type: seg.type,
			baselineBulge: seg.baselineBulge,
			forceFlat: seg.forceFlat,
			seed: seg.seed,
			widthShrinkRatio: seg.widthShrinkRatio,
		);

		// EdgeShape -Y → 朝段法線 +axisY；y 映射 = -axisY
		Offset toAbs(double x, double y) {
			return Offset(
				seg.a.dx + axisX.dx * x + (-axisY.dx) * y,
				seg.a.dy + axisX.dy * x + (-axisY.dy) * y,
			);
		}

		final List<EdgeCommand> abs = <EdgeCommand>[];
		for (final EdgeCommand cmd in rel) {
			if (cmd is LineToCmd) {
				final Offset p = toAbs(cmd.x, cmd.y);
				abs.add(LineToCmd(p.dx, p.dy, isTab: cmd.isTab));
			} else if (cmd is CubicToCmd) {
				final Offset c1 = toAbs(cmd.c1x, cmd.c1y);
				final Offset c2 = toAbs(cmd.c2x, cmd.c2y);
				final Offset p = toAbs(cmd.x, cmd.y);
				abs.add(CubicToCmd(c1.dx, c1.dy, c2.dx, c2.dy, p.dx, p.dy,
						isTab: cmd.isTab));
			}
		}

		// 端點 C1 平滑：
		// - 無耳朵段（abs 只有一個 cubic / line）：直接 replace 成一條
		//   端點切線受 tangent override 控制的 cubic。
		// - 有耳朵段（abs 有 4 個指令、第 1 與第 4 是進耳前 / 出耳後 baseline
		//   cubic）：只 patch cubic1 的第一控制點（起點切線）與 cubic4 的第
		//   二控制點（終點切線）；耳朵本體（cubic2、cubic3）不動。
		final bool isPureBaseline =
				seg.forceFlat || seg.type == EdgeType.flat;
		if ((seg.tangentAtA != null || seg.tangentAtB != null)) {
			if (isPureBaseline && abs.length == 1) {
				final double defaultLen = len / 3.0;
				Offset c1;
				if (seg.tangentAtA != null) {
					c1 = Offset(
						seg.a.dx + seg.tangentAtA!.dx * seg.tangentLenAtA,
						seg.a.dy + seg.tangentAtA!.dy * seg.tangentLenAtA,
					);
				} else {
					c1 = toAbs(
							defaultLen, _bulgeY(defaultLen, len, seg.baselineBulge));
				}
				Offset c2;
				if (seg.tangentAtB != null) {
					c2 = Offset(
						seg.b.dx + seg.tangentAtB!.dx * seg.tangentLenAtB,
						seg.b.dy + seg.tangentAtB!.dy * seg.tangentLenAtB,
					);
				} else {
					final double x = len - defaultLen;
					c2 = toAbs(x, _bulgeY(x, len, seg.baselineBulge));
				}
				abs.clear();
				abs.add(CubicToCmd(c1.dx, c1.dy, c2.dx, c2.dy, seg.b.dx, seg.b.dy));
			} else if (!isPureBaseline && abs.length == 4) {
				// 有耳朵段：cubic1 是進耳前 baseline、cubic4 是出耳後 baseline。
				// cubic1: (seg.a) → (..., y1)、其第一控制點影響「在 seg.a 的起點切線」。
				// cubic4: (..., y7) → (seg.b)、其第二控制點影響「在 seg.b 的終點切線」。
				if (seg.tangentAtA != null) {
					final CubicToCmd cubic1 = abs[0] as CubicToCmd;
					final Offset newC1 = Offset(
						seg.a.dx + seg.tangentAtA!.dx * seg.tangentLenAtA,
						seg.a.dy + seg.tangentAtA!.dy * seg.tangentLenAtA,
					);
					abs[0] = CubicToCmd(
						newC1.dx,
						newC1.dy,
						cubic1.c2x,
						cubic1.c2y,
						cubic1.x,
						cubic1.y,
						isTab: cubic1.isTab,
					);
				}
				if (seg.tangentAtB != null) {
					final CubicToCmd cubic4 = abs[3] as CubicToCmd;
					final Offset newC2 = Offset(
						seg.b.dx + seg.tangentAtB!.dx * seg.tangentLenAtB,
						seg.b.dy + seg.tangentAtB!.dy * seg.tangentLenAtB,
					);
					abs[3] = CubicToCmd(
						cubic4.c1x,
						cubic4.c1y,
						newC2.dx,
						newC2.dy,
						cubic4.x,
						cubic4.y,
						isTab: cubic4.isTab,
					);
				}
			}
		}
		return abs;
	}

	/// EdgeShape 的 baseline y（sin 弧）。複製 [ClassicTabShape._baselineY] 邏輯、
	/// 用於 patched cubic 在「沒 tangent override 的那端」回退到預設值時。
	static double _bulgeY(double x, double length, double bulge) {
		if (length <= 0) return 0;
		return bulge * sin(pi * x / length);
	}

	/// 沿段正向把絕對座標指令加進 path（套用 offset 轉成 localPath 座標）。
	static void _appendForwardCommands(
		Path path,
		List<EdgeCommand> absCommands,
		Offset offset,
	) {
		for (final EdgeCommand cmd in absCommands) {
			if (cmd is LineToCmd) {
				path.lineTo(cmd.x + offset.dx, cmd.y + offset.dy);
			} else if (cmd is CubicToCmd) {
				path.cubicTo(
					cmd.c1x + offset.dx, cmd.c1y + offset.dy,
					cmd.c2x + offset.dx, cmd.c2y + offset.dy,
					cmd.x + offset.dx, cmd.y + offset.dy,
				);
			}
		}
	}

	/// 沿段反向把絕對座標指令加進 path。
	///
	/// 反向播放：倒著走指令列，每個指令的新終點 = 該指令在正向時的起點。
	/// cubicTo 反向：控制點 c1 與 c2 互換、終點變成原起點。
	static void _appendReversedCommands(
		Path path,
		List<EdgeCommand> absCommands,
		Offset offset,
		_EdgeSegment seg,
	) {
		final Offset segStart = seg.a;
		final List<Offset> commandStarts = <Offset>[segStart];
		Offset cursor = segStart;
		for (final EdgeCommand cmd in absCommands) {
			if (cmd is LineToCmd) {
				cursor = Offset(cmd.x, cmd.y);
			} else if (cmd is CubicToCmd) {
				cursor = Offset(cmd.x, cmd.y);
			}
			commandStarts.add(cursor);
		}

		for (int i = absCommands.length - 1; i >= 0; i--) {
			final EdgeCommand cmd = absCommands[i];
			final Offset newEnd = commandStarts[i];
			if (cmd is LineToCmd) {
				path.lineTo(newEnd.dx + offset.dx, newEnd.dy + offset.dy);
			} else if (cmd is CubicToCmd) {
				path.cubicTo(
					cmd.c2x + offset.dx, cmd.c2y + offset.dy,
					cmd.c1x + offset.dx, cmd.c1y + offset.dy,
					newEnd.dx + offset.dx, newEnd.dy + offset.dy,
				);
			}
		}
	}

	static EdgeType _reverseType(EdgeType type) {
		switch (type) {
			case EdgeType.flat:
				return EdgeType.flat;
			case EdgeType.tabOut:
				return EdgeType.tabIn;
			case EdgeType.tabIn:
				return EdgeType.tabOut;
		}
	}
}

/// 一條邊段。
///
/// 「正向」= 從 [a] 走到 [b]。同一條物理邊由兩個 piece 共享時，segment 只儲存
/// 一次（用第一個 cell 看到的 (a, b) 順序）；另一個 piece 走這段時用「反向播放」。
///
/// [tabSize]、[widthShrinkRatio]、[forceFlat] 在切割完成後可能被「自交修正」
/// 流程動態縮減 / 關閉，所以非 final。
class _EdgeSegment {
	_EdgeSegment({
		required this.a,
		required this.b,
		required this.type,
		required this.tabSize,
		required this.baselineBulge,
		required this.forceFlat,
		required this.seed,
		// 構造時固定從預設 1.0 起步；後續由 resolver 直接寫入欄位調整。
		// ignore: unused_element_parameter
		this.widthShrinkRatio = 1.0,
	});

	final Offset a;
	final Offset b;
	final EdgeType type;
	double tabSize;
	final double baselineBulge;
	bool forceFlat;
	final int seed;
	double widthShrinkRatio;

	/// 端點 a / b 處的「C1 平滑切線方向」（單位向量）。
	///
	/// 若非 null：表示該端點與另一條同對 polygon 共用邊接合、需用此切線方向
	/// patch baseline cubic 的對應 control point、使兩段在端點處切線同向、
	/// 視覺上平滑接合。null = 不平滑、用 EdgeShape 預設 control point。
	///
	/// 方向約定：兩個 segment 在共用點各自的切線方向都「指向遠離共用點」。
	/// _buildSegmentAbsoluteCommands 從 a 走向 b 時、tangentAtA 用作起點切線、
	/// tangentAtB 用作終點切線（指向 b 外側）。
	Offset? tangentAtA;
	Offset? tangentAtB;

	/// 對應端點處的「smooth 切線長度」（影響 cubic control point 與端點的距離）。
	double tangentLenAtA = 0;
	double tangentLenAtB = 0;
}
