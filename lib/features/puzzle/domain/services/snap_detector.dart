import "dart:math";
import "dart:ui";

import "../../puzzle_dimens.dart";
import "../models/puzzle_edge.dart";
import "../models/puzzle_layout.dart";
import "../models/puzzle_piece.dart";

/// 吸附 / 鎖定判定。
///
/// 對「正在拖的群組」執行**一次**判定，依優先序：
/// 1. **群組融合（優先）**：對拖曳群組每片 piece，找出其他群組所有 piece 中
///    「應有相對位移」與「實際相對位移」最接近的一對；若距離 < tolerance
///    就把另一群整體平移使該對對齊、合併兩群（新 groupId 取較小者）。
///    若同時有多組滿足條件、只取距離最近的一組；不會在同一次呼叫中連環融合。
/// 2. **鎖定到正確位置**：只有在沒發生融合時才嘗試。取群組內任一片 piece
///    比較它的 currentPosition 與該 piece 在 stage 中的「正確位置」。
///    距離 < tolerance 就把整群整體平移到完全對齊、所有成員 locked = true。
///
/// 設計理由：snap 動作（融合 / 鎖定）等同於「本次拖曳已結束」，呼叫端應該把
/// session 清掉、等使用者放開手指再重新觸控；連環觸發會違反此語意。
/// 拼片融合優先於鎖定的理由是：玩家通常先把碎片拼一拼、再整體放回拼圖盤。
class SnapDetector {
	SnapDetector._();

	/// 對 [draggingGroupId] 群組執行吸附 / 鎖定判定。
	///
	/// [boardOrigin]：拼圖盤左上角在 stage 中的座標
	/// （PuzzlePiece.correctPositionLocal 是相對拼圖盤的，要加上它變 stage-global）。
	///
	/// [requireNeighborContact] = true 時（用於「不顯示提示線」模式），鎖定到正確
	/// 位置除了距離 < tolerance 之外，還需要群組中至少有一片 piece 滿足下列其一：
	/// - 與某個「已鎖定」的 piece 在 layout 上是相鄰的（neighborIds 命中）
	/// - 該 piece 自己有任一條 [EdgeType.flat] 邊（=「靠邊」、邊框就是它的鄰居）
	///
	/// 這樣可避免幼兒「碰運氣」把孤立的拼片直接拋到中間正確位置而過關。
	///
	/// 回傳 [SnapResult]，呼叫端可據此播音效 / 通知 UI。
	/// [groupRotationDeg] 旋轉模式下、每個群組的當前角度（度）。空 map 代表
	/// 旋轉模式關閉、所有群組角度視為 0、不影響判定邏輯。
	///
	/// 旋轉模式下：
	/// - 融合：要求兩群角度相等（差距 < 0.01 度）才允許。
	/// - 鎖定：要求拖曳群角度為 0（< 0.01 度）才允許。
	static SnapResult resolve({
		required PuzzleLayout layout,
		required int draggingGroupId,
		required Offset boardOrigin,
		bool requireNeighborContact = false,
		Map<int, int> groupRotationDeg = const <int, int>{},
	}) {
		bool merged = false;
		int finalGroupId = draggingGroupId;

		// Step 1: 嘗試融合 —— 取最接近的一組（_findBestMerge 內部已挑最近）；
		// 不做連環融合：一次拖曳只觸發一次 snap，符合「snap 即視為拖曳結束」語意。
		final _MergeCandidate? best = _findBestMerge(
			layout: layout,
			groupId: finalGroupId,
			groupRotationDeg: groupRotationDeg,
		);
		if (best != null &&
				_mergeAllowed(
					layout: layout,
					groupAId: finalGroupId,
					groupBId: best.otherGroupId,
					groupBTranslation: best.translation,
				)) {
			// 把 other 群組整體平移到對齊位置（B 群所有片的 currentPosition += delta）。
			_translateGroup(layout, best.otherGroupId, best.translation);

			// 旋轉模式下：融合前 A、B 各自繞自己的 pivot 旋轉、融合後變一個更大
			// 的群組、painter 改用「新 pivot（A∪B 的 polygonAabb 中心）」當軸。
			// 若不調整、A 群成員的視覺位置會跟著 pivot 改變而漂移。
			// 解法：先記下融合前每片的「視覺位置」（每片繞自己 group 的 pivot
			// 旋轉 R 度後的 sourceRect 左上點），融合後反推新 currentPosition：
			// 在新 pivot 下旋轉 R 度後等於原視覺位置。
			final double mergeRot =
					(groupRotationDeg[finalGroupId] ?? 0).toDouble();
			final bool needRebase = mergeRot != 0;
			final Map<int, Offset> visualBefore = <int, Offset>{};
			if (needRebase) {
				final Offset pivotA = _pivotForGroup(layout, finalGroupId);
				final Offset pivotB = _pivotForGroup(layout, best.otherGroupId);
				for (final PuzzlePiece p in layout.pieces) {
					if (p.groupId == finalGroupId) {
						visualBefore[p.id] = _rotateAround(p.currentPosition, pivotA, mergeRot);
					} else if (p.groupId == best.otherGroupId) {
						visualBefore[p.id] = _rotateAround(p.currentPosition, pivotB, mergeRot);
					}
				}
			}

			final int newId = best.mergedGroupId;
			for (final PuzzlePiece p in layout.pieces) {
				if (p.groupId == finalGroupId || p.groupId == best.otherGroupId) {
					p.groupId = newId;
				}
			}

			if (needRebase) {
				final Offset newPivot = _pivotForGroup(layout, newId);
				for (final PuzzlePiece p in layout.pieces) {
					if (p.groupId != newId) continue;
					final Offset? v = visualBefore[p.id];
					if (v == null) continue;
					p.currentPosition = _rotateAround(v, newPivot, -mergeRot);
				}
			}

			finalGroupId = newId;
			merged = true;
		}

		// 拼片 snap 優先於鎖定 snap：若本次已融合、直接結束、不嘗試鎖定。
		// 玩家通常先湊好碎片再整體放回拼圖盤，融合後立刻鎖定會讓 onSnap
		// 被連續觸發兩次、語意上也偏離「一次拖曳一次 snap」。
		if (merged) {
			return SnapResult(merged: true, locked: false, finalGroupId: finalGroupId);
		}

		// Step 2: 鎖定判定 —— 取群組第一片計算偏差，若 < tolerance 整群對齊鎖定
		final List<PuzzlePiece> groupMembers = layout.pieces
				.where((PuzzlePiece p) => p.groupId == finalGroupId)
				.toList();
		if (groupMembers.isEmpty) {
			return SnapResult(merged: merged, locked: false, finalGroupId: finalGroupId);
		}

		// 旋轉模式：鎖定要求拖曳群「目前角度」= 0（即「轉回正確角度」）。
		// 角度不為 0 時直接不做鎖定判定，只回傳融合結果。
		// 角度存 int + mod 360、所以可以精確比對 == 0。
		final int finalRot = groupRotationDeg[finalGroupId] ?? 0;
		if (finalRot != 0) {
			return SnapResult(merged: merged, locked: false, finalGroupId: finalGroupId);
		}

		final PuzzlePiece anchor = groupMembers.first;
		final Offset correctGlobal = anchor.correctPositionLocal + boardOrigin;
		final Offset diff = correctGlobal - anchor.currentPosition;
		if (diff.distance <= _pieceTolerance(anchor)) {
			if (requireNeighborContact &&
					!_groupTouchesLockedOrFrame(layout, groupMembers)) {
				// 雖然距離夠近，但群組沒碰到已鎖定 piece 或邊框 → 不鎖定
				return SnapResult(merged: merged, locked: false, finalGroupId: finalGroupId);
			}
			// 目標位置遮擋檢查：群組任一片被「不屬於此群組、未鎖定」的其他 piece
			// 蓋住超過 20% sourceRect 面積就拒絕鎖定，避免拼進去之後被外部塊蓋住。
			if (_targetIsBlocked(layout, groupMembers, finalGroupId, diff)) {
				return SnapResult(merged: merged, locked: false, finalGroupId: finalGroupId);
			}
			for (final PuzzlePiece p in groupMembers) {
				p.currentPosition = p.currentPosition + diff;
				p.locked = true;
			}
			return SnapResult(merged: merged, locked: true, finalGroupId: finalGroupId);
		}

		return SnapResult(merged: merged, locked: false, finalGroupId: finalGroupId);
	}

	/// 融合遮擋判定：兩群是否允許融合到 "B 平移 groupBTranslation" 後的位置。
	///
	/// **動機**：在散落區堆疊很亂時，兩個本來不打算合的群組可能正好對上「相對
	/// 位移」，被誤判融合（歪打正著）。這個檢查確保「玩家真的有把這兩群放在
	/// 看得見的位置去湊」才會成功 — 若有別的拼片在視覺上把該群成員擋住、玩家
	/// 應該根本看不見它能去拼。
	///
	/// **判斷邏輯**（per-piece）：
	/// 對群組裡每片 piece，只用「zIndex 比它高的外部 piece」作為 obstacles 算遮擋率；
	/// 因為 painter 是依 zIndex 由低到高繪製、zIndex 低的 piece 視覺上不會擋到 zIndex
	/// 高的 piece，這樣的 obstacle 在規則上不該被算進去。任一片實際遮擋率 > 20% 拒絕。
	static bool _mergeAllowed({
		required PuzzleLayout layout,
		required int groupAId,
		required int groupBId,
		required Offset groupBTranslation,
	}) {
		// 收集 A、B 成員與外部 piece
		final List<PuzzlePiece> groupA = <PuzzlePiece>[];
		final List<PuzzlePiece> groupB = <PuzzlePiece>[];
		final List<PuzzlePiece> outsiders = <PuzzlePiece>[];
		for (final PuzzlePiece p in layout.pieces) {
			if (p.groupId == groupAId) {
				groupA.add(p);
			} else if (p.groupId == groupBId) {
				groupB.add(p);
			} else if (!p.locked) {
				outsiders.add(p);
			}
		}
		if (outsiders.isEmpty) return true;

		if (_groupIsVisuallyBlockedAt(
			pieces: groupA,
			translation: Offset.zero,
			candidates: outsiders,
		)) {
			return false;
		}
		if (_groupIsVisuallyBlockedAt(
			pieces: groupB,
			translation: groupBTranslation,
			candidates: outsiders,
		)) {
			return false;
		}
		return true;
	}

	/// 對 [pieces] 中任一片：把 [candidates] 中「zIndex 比它高」的當 obstacles，
	/// 算實際輪廓遮擋率；超過 [_maxBlockedRatio] 回 true。
	///
	/// 採樣演算法見 [_targetIsBlocked]。
	static bool _groupIsVisuallyBlockedAt({
		required List<PuzzlePiece> pieces,
		required Offset translation,
		required List<PuzzlePiece> candidates,
	}) {
		for (final PuzzlePiece p in pieces) {
			// 只考慮 zIndex 比 p 高的 candidate — 較低層在視覺上不會擋住 p
			final List<PuzzlePiece> obstacles = <PuzzlePiece>[];
			for (final PuzzlePiece c in candidates) {
				if (c.zIndex > p.zIndex) obstacles.add(c);
			}
			if (obstacles.isEmpty) continue;

			final Offset targetTopLeft = p.currentPosition + translation;
			final Size sz = p.sourceRect.size;
			if (sz.width <= 0 || sz.height <= 0) continue;
			int insideCount = 0;
			int blockedCount = 0;
			final double dx = sz.width / _samplesPerAxis;
			final double dy = sz.height / _samplesPerAxis;
			for (int iy = 0; iy < _samplesPerAxis; iy++) {
				for (int ix = 0; ix < _samplesPerAxis; ix++) {
					final Offset localPt = Offset((ix + 0.5) * dx, (iy + 0.5) * dy);
					if (!p.localPath.contains(localPt)) continue;
					insideCount++;
					final Offset globalPt = targetTopLeft + localPt;
					for (final PuzzlePiece o in obstacles) {
						final Offset oLocal = globalPt - o.currentPosition;
						if (oLocal.dx < 0 ||
								oLocal.dy < 0 ||
								oLocal.dx > o.sourceRect.width ||
								oLocal.dy > o.sourceRect.height) {
							continue;
						}
						if (o.localPath.contains(oLocal)) {
							blockedCount++;
							break;
						}
					}
				}
			}
			if (insideCount == 0) continue;
			if (blockedCount / insideCount > _maxBlockedRatio) return true;
		}
		return false;
	}

	/// 鎖定遮擋判定：若群組中任一片 piece 在「鎖定後位置」會被「其他群組、且
	/// 未鎖定」的 piece 的**實際輪廓**蓋住超過 [_maxBlockedRatio] 比例，回 true。
	///
	/// 用 Monte Carlo 採樣估算「非透明像素重疊比例」：對目標 piece 在 sourceRect
	/// 內均勻取 [_samplesPerAxis]² 個點 → 篩掉不在 piece 形狀（localPath）內的
	/// → 對每個形狀內樣本檢查是否被某個外部 piece 的 localPath 命中 → 命中
	/// 比例即為遮擋率。比直接做 path-path 光柵化便宜很多，且精度足夠。
	static const double _maxBlockedRatio = 0.20;
	static const int _samplesPerAxis = 16;

	static bool _targetIsBlocked(
		PuzzleLayout layout,
		List<PuzzlePiece> groupMembers,
		int finalGroupId,
		Offset lockTranslation,
	) {
		// 先收集所有「外部」piece（不同群組且未鎖定），這些是潛在遮擋者。
		final List<PuzzlePiece> obstacles = <PuzzlePiece>[];
		for (final PuzzlePiece o in layout.pieces) {
			if (o.groupId == finalGroupId) continue;
			if (o.locked) continue;
			obstacles.add(o);
		}
		if (obstacles.isEmpty) return false;

		for (final PuzzlePiece p in groupMembers) {
			// 鎖定後 p 的左上角（global 座標）
			final Offset targetTopLeft = p.currentPosition + lockTranslation;
			final Size sz = p.sourceRect.size;
			if (sz.width <= 0 || sz.height <= 0) continue;

			// 在 p 的 sourceRect 區域內均勻取樣（cell 中心點）。
			// 樣本點以 piece 局部座標（0..w, 0..h）表示，等於 localPath 的座標系。
			int insideCount = 0;
			int blockedCount = 0;
			final double dx = sz.width / _samplesPerAxis;
			final double dy = sz.height / _samplesPerAxis;
			for (int iy = 0; iy < _samplesPerAxis; iy++) {
				for (int ix = 0; ix < _samplesPerAxis; ix++) {
					final Offset localPt = Offset((ix + 0.5) * dx, (iy + 0.5) * dy);
					// 點必須在 p 自身形狀內、才算是「p 的像素」
					if (!p.localPath.contains(localPt)) continue;
					insideCount++;
					// 換成 global 座標，再對每個 obstacle 換成它的局部座標檢查
					final Offset globalPt = targetTopLeft + localPt;
					for (final PuzzlePiece o in obstacles) {
						final Offset oLocal = globalPt - o.currentPosition;
						if (oLocal.dx < 0 ||
								oLocal.dy < 0 ||
								oLocal.dx > o.sourceRect.width ||
								oLocal.dy > o.sourceRect.height) {
							continue;
						}
						if (o.localPath.contains(oLocal)) {
							blockedCount++;
							break; // 一個 obstacle 命中就夠
						}
					}
				}
			}

			if (insideCount == 0) continue;
			final double ratio = blockedCount / insideCount;
			if (ratio > _maxBlockedRatio) return true;
		}
		return false;
	}

	/// 判斷群組中是否有任一片 piece 與「已鎖定 piece」共享一條有耳朵的邊，
	/// 或自身靠邊（有 flat 邊 → 邊框就是它的物理鄰居）。
	///
	/// 用於 [requireNeighborContact] 模式（不顯示提示線時），避免幼兒把孤立拼片
	/// 直接拋到中間正確位置而誤觸鎖定。
	///
	/// 鄰居條件用 [PuzzlePiece.tabNeighborIds]（與 [_findBestMerge] 一致），
	/// 即「兩片共用且有耳朵的邊」；純 flat / forceFlat 共用邊不算數，
	/// 因為這種邊在視覺上沒有卡榫、玩家從畫面上判斷不出它們應該相連。
	static bool _groupTouchesLockedOrFrame(
		PuzzleLayout layout,
		List<PuzzlePiece> groupMembers,
	) {
		// 收集已鎖定 piece id
		final Set<int> lockedIds = <int>{};
		for (final PuzzlePiece p in layout.pieces) {
			if (p.locked) lockedIds.add(p.id);
		}
		for (final PuzzlePiece p in groupMembers) {
			// 自身靠邊：有任一條 flat 邊
			for (final PuzzleEdge e in p.edges) {
				if (e.type == EdgeType.flat) return true;
			}
			// 與某個已鎖定 piece 透過「有耳朵的邊」相鄰
			for (final int nid in p.tabNeighborIds) {
				if (lockedIds.contains(nid)) return true;
			}
		}
		return false;
	}

	/// 在所有非自身群組的 piece 中，找出與 [groupId] 中某片「相對位移誤差最小」
	/// 且該誤差 ≤ per-pair tolerance 的配對。
	///
	/// per-pair tolerance：對 a、b 兩片各算 `(w+h)/2 × ratio`，取兩者較小者，
	/// 避免大塊把小塊「吸過去」造成不合理的融合。
	static _MergeCandidate? _findBestMerge({
		required PuzzleLayout layout,
		required int groupId,
		required Map<int, int> groupRotationDeg,
	}) {
		_MergeCandidate? best;
		double bestDist = double.infinity;
		// 角度存整數 mod 360，下面所有比較 / 計算用 double 度即可。
		final int draggingRotInt = groupRotationDeg[groupId] ?? 0;
		final double draggingRot = draggingRotInt.toDouble();

		for (final PuzzlePiece a in layout.pieces) {
			if (a.groupId != groupId) continue;
			if (a.locked) continue;
			for (final PuzzlePiece b in layout.pieces) {
				if (b.groupId == groupId) continue;
				if (b.locked) continue;
				// 必須是「共享一條有耳朵的邊」的鄰居才允許融合：
				// (1) 不相鄰的拼塊不可融合（相對位置巧合相同的誤判）；
				// (2) 共享邊是純直線（flat 或 forceFlat 的短邊）的拼塊也不可融合，
				//     因為這種邊在視覺上沒有卡榫，玩家從畫面上判斷不出它們有相關。
				// 群組內可能有多片，只要群組中「任一對」是 tab 鄰居即可。
				if (!a.tabNeighborIds.contains(b.id)) continue;
				// 旋轉模式：兩群角度必須相等才允許融合。groupRotationDeg 為空
				// （旋轉模式關閉）時 draggingRotInt 與 otherRot 都會是 0、自動通過。
				// 角度存 int + mod 360、可以直接精確比對。
				final int otherRot = groupRotationDeg[b.groupId] ?? 0;
				if (otherRot != draggingRotInt) continue;

				final double tolA = _pieceTolerance(a);
				final double tolB = _pieceTolerance(b);
				final double pairTol = tolA < tolB ? tolA : tolB;

				// 應有的相對位移（a → b，原座標系；尚未套上群組旋轉）
				final Offset rawExpected =
						b.correctPositionLocal - a.correctPositionLocal;

				// 計算「實際相對位移 actual」與「應有相對位移 expected」時必須
				// 都在「視覺座標系」進行比較：painter 對每片以「群組 pivot」為軸
				// 套上 R 度旋轉、視覺位置 = rotate_R_around(pivot, currentPosition)。
				// 兩群 pivot 不同、所以視覺差不等於 currentPosition 差。
				final Offset expected;
				final Offset actual;
				if (draggingRot.abs() < 0.01) {
					expected = rawExpected;
					actual = b.currentPosition - a.currentPosition;
				} else {
					final Offset pivotA = _pivotForGroup(layout, groupId);
					final Offset pivotB = _pivotForGroup(layout, b.groupId);
					final Offset va =
							_rotateAround(a.currentPosition, pivotA, draggingRot);
					final Offset vb =
							_rotateAround(b.currentPosition, pivotB, draggingRot);
					actual = vb - va;
					expected = _rotateAround(rawExpected, Offset.zero, draggingRot);
				}
				// 差距：要把 b 整群（世界座標）平移多少才會視覺對齊 a
				final Offset delta = expected - actual;
				final double d = delta.distance;
				if (d <= pairTol && d < bestDist) {
					bestDist = d;
					best = _MergeCandidate(
						aId: a.id,
						bId: b.id,
						otherGroupId: b.groupId,
						mergedGroupId: groupId < b.groupId ? groupId : b.groupId,
						translation: delta,
					);
				}
			}
		}
		return best;
	}

	/// 計算群組「polygonAabb 在世界座標的聯集中心」（與 PuzzleController.groupPivot
	/// 一致；放這裡因為 SnapDetector 沒有 controller 引用）。
	///
	/// 注意：用的是 `currentPosition`（未旋轉的世界座標）— 旋轉本身不會改變
	/// AABB 聯集中心、所以這個 pivot 在「未旋轉空間」與「視覺空間」是一致的。
	static Offset _pivotForGroup(PuzzleLayout layout, int groupId) {
		double minX = double.infinity;
		double minY = double.infinity;
		double maxX = -double.infinity;
		double maxY = -double.infinity;
		bool any = false;
		for (final PuzzlePiece p in layout.pieces) {
			if (p.groupId != groupId) continue;
			final Offset off = p.currentPosition -
					Offset(p.sourceRect.left, p.sourceRect.top);
			final double l = p.polygonAabb.left + off.dx;
			final double t = p.polygonAabb.top + off.dy;
			final double r = p.polygonAabb.right + off.dx;
			final double b = p.polygonAabb.bottom + off.dy;
			if (!any) {
				minX = l;
				minY = t;
				maxX = r;
				maxY = b;
				any = true;
			} else {
				if (l < minX) minX = l;
				if (t < minY) minY = t;
				if (r > maxX) maxX = r;
				if (b > maxY) maxY = b;
			}
		}
		if (!any) return Offset.zero;
		return Offset((minX + maxX) / 2, (minY + maxY) / 2);
	}

	/// 把 [p] 以 [pivot] 為軸旋轉 [deg] 度。
	static Offset _rotateAround(Offset p, Offset pivot, double deg) {
		final double rad = deg * pi / 180.0;
		final double cosR = cos(rad);
		final double sinR = sin(rad);
		final double dx = p.dx - pivot.dx;
		final double dy = p.dy - pivot.dy;
		return Offset(
			dx * cosR - dy * sinR + pivot.dx,
			dx * sinR + dy * cosR + pivot.dy,
		);
	}

	/// 一片拼片的吸附 / 鎖定容差：`((w + h) / 2) ^ exponent × ratio`。
	///
	/// 用「次方而非線性」的尺寸→容差關係，理由：幼兒的精細動作能力在大塊跟小塊
	/// 之間的差異不是線性的 — 大塊時容差應該明顯放寬，小塊時不能跟著等比例縮小。
	/// exponent > 1 讓大塊容差非線性放大、小塊維持較緊。
	///
	/// 用 `polygonAabb`（不含 tab 的核心矩形）而非 `sourceRect`，因為 sourceRect
	/// 含外凸耳會把容差放得不必要地大。
	///
	/// 公式常數從 [AppDimens] 拿（同一程式進程內固定不變），不需要當參數傳遞。
	static double _pieceTolerance(PuzzlePiece p) {
		final double avgSide = (p.polygonAabb.width + p.polygonAabb.height) / 2;
		return pow(avgSide, PuzzleDimens.snapToleranceExponent).toDouble() *
				PuzzleDimens.snapToleranceRatio;
	}

	static void _translateGroup(PuzzleLayout layout, int groupId, Offset delta) {
		for (final PuzzlePiece p in layout.pieces) {
			if (p.groupId == groupId) {
				p.currentPosition = p.currentPosition + delta;
			}
		}
	}
}

/// 吸附判定結果。
class SnapResult {
	const SnapResult({
		required this.merged,
		required this.locked,
		required this.finalGroupId,
	});

	/// 是否發生任何群組融合（即使只有一次）。
	final bool merged;

	/// 是否成功鎖定到正確位置。
	final bool locked;

	/// 操作結束後該群組的 ID（可能因融合改變）。
	final int finalGroupId;

	@override
	String toString() {
		return "SnapResult(merged=$merged, locked=$locked, group=$finalGroupId)";
	}
}

/// 內部：一個合併候選（兩片在不同群組之間的最佳配對）。
class _MergeCandidate {
	const _MergeCandidate({
		required this.aId,
		required this.bId,
		required this.otherGroupId,
		required this.mergedGroupId,
		required this.translation,
	});

	final int aId;
	final int bId;
	final int otherGroupId;
	final int mergedGroupId;

	/// 要套用到 otherGroup 的整體平移量（讓 b 對齊 a 的正確相對位置）。
	final Offset translation;
}
