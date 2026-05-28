import "dart:math";
import "dart:ui" as ui;

import "package:flutter/foundation.dart";
import "package:flutter/widgets.dart" show Matrix4;

import "../puzzle_dimens.dart";
import "../domain/models/puzzle_layout.dart";
import "../domain/models/puzzle_piece.dart";
import "../domain/services/cell_planner.dart";
import "../domain/services/puzzle_cutter.dart";
import "../domain/services/snap_detector.dart";
import "../domain/services/triangle_planner.dart";
import "../domain/services/voronoi.dart";
import "_diag.dart";

/// 拼圖場景的可繪製區域劃分。
///
/// 拼圖盤（左側）與散落區（右側）以一條垂直分割線為界。
class PuzzleStageLayout {
	PuzzleStageLayout({
		required this.totalSize,
		required this.boardOrigin,
		required this.boardSize,
		required this.scatterOrigin,
		required this.scatterSize,
	});

	/// 整個拼圖頁面可用區域（視窗 / canvas size）。
	///
	/// 視窗尺寸變動時 [PuzzleController.rescaleStage] 會直接覆蓋這個物件的
	/// 全部欄位（不重建 PuzzleController，以保留遊戲進度）。
	ui.Size totalSize;

	ui.Offset boardOrigin;
	ui.Size boardSize;

	ui.Offset scatterOrigin;
	ui.Size scatterSize;

	ui.Rect get boardRect => boardOrigin & boardSize;
	ui.Rect get scatterRect => scatterOrigin & scatterSize;

	/// 根據整體可用尺寸生成 layout：左半放拼圖盤、右半放散落區。
	///
	/// 拼圖盤本身用 4:3 比例，盡量塞滿左半的高度；橫向多餘的給散落區。
	static PuzzleStageLayout forSize(ui.Size totalSize) {
		final double halfW = totalSize.width / 2;
		final double h = totalSize.height;
		// 4:3 比例：寬 = h * 4/3
		double boardW = h * 4 / 3;
		double boardH = h;
		if (boardW > halfW) {
			boardW = halfW;
			boardH = boardW * 3 / 4;
		}
		// 微縮一點留邊距
		boardW *= 0.95;
		boardH *= 0.95;

		final ui.Offset boardOrigin = ui.Offset(
			(halfW - boardW) / 2,
			(h - boardH) / 2,
		);
		final ui.Offset scatterOrigin = ui.Offset(halfW, 0);
		final ui.Size scatterSize = ui.Size(totalSize.width - halfW, h);

		return PuzzleStageLayout(
			totalSize: totalSize,
			boardOrigin: boardOrigin,
			boardSize: ui.Size(boardW, boardH),
			scatterOrigin: scatterOrigin,
			scatterSize: scatterSize,
		);
	}
}

/// 拼圖遊戲狀態控制器。
///
/// 持有當前 layout、所有 piece 的位置；
/// 拖曳期間透過 [repaintTick] 觸發 painter 重繪而不 rebuild widget tree。
class PuzzleController extends ChangeNotifier {
	PuzzleController({
		required this.stageLayout,
		required this.boardImage,
		required this.boardImageSize,
		required this.layout,
	}) {
		_repaintTick = ValueNotifier<int>(0);
	}

	final PuzzleStageLayout stageLayout;

	/// 拼圖盤上要切的整張原圖。
	final ui.Image boardImage;

	/// 原圖的尺寸（pixel）。
	final ui.Size boardImageSize;

	/// 切割結果。
	final PuzzleLayout layout;

	late final ValueNotifier<int> _repaintTick;
	ValueListenable<int> get repaintTick => _repaintTick;

	/// 鎖定脈衝：每次 endDrag 觸發鎖定就 +1，給「鎖定回饋動畫」widget 訂閱。
	final ValueNotifier<int> _lockBump = ValueNotifier<int>(0);
	ValueListenable<int> get lockBump => _lockBump;

	/// 觸發 painter 重繪。
	void bumpRepaint() {
		_repaintTick.value = _repaintTick.value + 1;
	}

	/// piece bevel bitmap 快取（pieceId → Image）。
	///
	/// 第一次繪製時由 painter 用 [BevelPainter.rasterize] 生成、存進此 map。
	/// 拖曳時直接 drawImage、不再每幀重算光澤。dispose 時釋放。
	final Map<int, ui.Image> bevelCache = <int, ui.Image>{};

	/// 相框 bevel（padding 環）bitmap 快取。
	///
	/// boardRect + padding 都不會變、bevel 是純幾何計算，因此可一次烤成 bitmap，
	/// 每幀只 drawImageRect 一次。否則 `_drawFrameBevel` 每幀沿 ~5000px 周長
	/// 採樣 ~1700 次 drawLine，是 raster thread 上的最大開銷。
	/// dispose 時釋放。
	ui.Image? frameBevelCache;

	/// 目前正在拖曳的群組 ID 集合（空表示沒有任何拖曳）。
	///
	/// 支援多指同時拖曳：每個 pointer 認領一個群組。同一群組不允許被兩指搶。
	final Set<int> _draggingGroupIds = <int>{};
	Set<int> get draggingGroupIds => _draggingGroupIds;

	/// 每個 pointer 對應的拖曳狀態。key 是 pointer id。
	final Map<int, _DragSession> _dragSessions = <int, _DragSession>{};

	/// 給 canvas 用：查詢某 pointer 正在拖曳哪個群組。沒有對應 session 時回 null。
	/// 用於旋轉模式中、找出第二指應依附的群組 — 比 hitTest 第一指位置更可靠
	/// （第一指此刻可能落在 piece 邊框 1~2 px 之外、命中失敗導致旋轉手勢被吞）。
	int? groupIdForPointer(int pointerId) => _dragSessions[pointerId]?.groupId;

	// === 旋轉模式 ===

	/// 是否啟用旋轉模式（由外部在 newLevel 後設定）。
	///
	/// true 時：painter 會繪製群組角度；snap_detector 會檢查融合的角度一致與
	/// 鎖定的角度為 0；canvas 會把「同群組第二指」解讀成旋轉手勢。
	/// false 時：所有群組角度視為 0，行為與舊版完全相同。
	bool rotationEnabled = false;

	/// 旋轉時角度 snap 的 step（度）。grid → 90、voronoi → 45（由外部設定）。
	double rotationStepDeg = 90.0;

	/// 每個群組的「目標角度」（整數度，[0, 360) 區間，snap 後的精確值）。
	///
	/// 用整數 + mod 360 儲存的理由：旋轉判定（融合的「角度相等」、鎖定的「角度
	/// 為 0」）要絕對精確，浮點累積誤差會導致「視覺已對齊但 0.0001° 殘渣」造成
	/// 鎖定失敗。step 一定是 90 或 45 整數，target 永遠是 step 倍數、可以安全
	/// 存 int。
	///
	/// 沒有 entry 視為 0。
	final Map<int, int> _groupTargetRotation = <int, int>{};

	/// 每個群組的「當前顯示角度」（painter 真正讀的值，double 度）。動畫期間
	/// 由 canvas 推進、結束時等於 [_groupTargetRotation]。需 double 才能讓動畫
	/// 順滑（不會跳格）。
	///
	/// 沒有 entry 視為 0。
	final Map<int, double> _groupCurrentRotation = <int, double>{};

	/// 群組目標角度（整數度，[0, 360)）。給 canvas 用來判定是否還要繼續推進動畫，
	/// 也是 [SnapDetector] 用來判定融合 / 鎖定的精確值。
	int groupTargetRotation(int groupId) => _groupTargetRotation[groupId] ?? 0;

	/// 群組目前實際繪製角度（double 度）。painter 讀此值套到 canvas.rotate。
	double groupCurrentRotation(int groupId) =>
			_groupCurrentRotation[groupId] ?? 0.0;

	/// 給 [SnapDetector] 讀的 target map（整數度）。直接 expose 避免每次新建 map。
	Map<int, int> get groupTargetRotations => _groupTargetRotation;

	/// 由 canvas 的動畫迴圈呼叫：把群組的當前顯示角度推進到 [deg]。
	void setGroupCurrentRotation(int groupId, double deg) {
		_groupCurrentRotation[groupId] = deg;
		bumpRepaint();
	}

	/// 設定群組目標角度（會 snap 到 [rotationStepDeg] 倍數、規範化到 [0, 360)）。
	///
	/// 用整數 mod 360 儲存：避免「連續轉好幾圈時 rawDeg 累積到 720 → 視覺等同 0
	/// 但數值非 0、lock 失敗」與浮點累積誤差兩個問題。
	void setGroupTargetRotation(int groupId, double rawDeg) {
		final int step = rotationStepDeg.round();
		// snap 到 step 整數倍 → 結果一定是 step 的倍數 → 安全存 int
		final int snapped = (rawDeg / rotationStepDeg).round() * step;
		final int normalized = _normalizeAngle(snapped);
		final int? prev = _groupTargetRotation[groupId];
		_groupTargetRotation[groupId] = normalized;
		if (prev != null && prev != normalized) {
			onRotateStep?.call();
		}
	}

	/// 把角度規範化到 [0, 360)。e.g. 360 → 0、540 → 180、-270 → 90。
	static int _normalizeAngle(int deg) {
		final int a = deg % 360;
		return a < 0 ? a + 360 : a;
	}

	/// 立即把群組的 current 與 target 都設成 [deg]（不動畫）。用於 scatter
	/// 與群組融合時統一兩群角度。[deg] 必須是 step 倍數（呼叫端負責）。
	void setGroupRotationImmediate(int groupId, double deg) {
		_groupTargetRotation[groupId] = _normalizeAngle(deg.round());
		_groupCurrentRotation[groupId] = deg;
	}

	/// 計算群組的「實際旋轉中心」（stage-global 座標）。
	///
	/// 用群組成員的 polygonAabb（不含外凸耳）聯集中心 — 視覺上比 sourceRect
	/// 中心更穩定。polygonAabb 是拼圖盤座標，需配合 piece 的 currentPosition
	/// 來換算到 stage-global。
	ui.Offset groupPivot(int groupId) {
		double minX = double.infinity;
		double minY = double.infinity;
		double maxX = -double.infinity;
		double maxY = -double.infinity;
		bool any = false;
		for (final PuzzlePiece p in layout.pieces) {
			if (p.groupId != groupId) continue;
			// piece local 內：polygonAabb 是「相對拼圖盤」、sourceRect 也是。
			// piece 在 stage 上的位置：currentPosition - sourceRect.topLeft（=
			// piece local 原點對應的 stage 點）。所以 polygonAabb 在 stage 的位置：
			// currentPosition + (polygonAabb - sourceRect.topLeft)
			final ui.Offset off = p.currentPosition -
					ui.Offset(p.sourceRect.left, p.sourceRect.top);
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
		if (!any) return ui.Offset.zero;
		return ui.Offset((minX + maxX) / 2, (minY + maxY) / 2);
	}

	/// 每個 pointer 對應的旋轉手勢狀態（第二指）。key 是「第二指」的 pointer id。
	final Map<int, _RotateSession> _rotateSessions = <int, _RotateSession>{};

	/// 開始旋轉手勢：指定「第二指」屬於哪個拖曳 session（亦即哪個群組）、
	/// 記下基準向量。
	///
	/// [firstPointerPos] / [secondPointerPos]：兩指當下的位置。
	/// [groupId]：第一指拖曳的群組 ID。
	void beginRotate({
		required int secondPointerId,
		required int groupId,
		required ui.Offset firstPointerPos,
		required ui.Offset secondPointerPos,
	}) {
		if (!rotationEnabled) return;
		final ui.Offset v0 = secondPointerPos - firstPointerPos;
		_rotateSessions[secondPointerId] = _RotateSession(
			groupId: groupId,
			v0AngleRad: atan2(v0.dy, v0.dx),
			a0Deg: groupTargetRotation(groupId).toDouble(),
		);
	}

	/// 旋轉手勢更新：兩指當下位置算出 V1、與 V0 角度差 × gain 套到群組。
	///
	/// `v1 - v0` 算出的瞬時角度差因為 atan2 的值域是 (-π, π]，當第二指繞過
	/// V0 的反向延伸線時、deltaDeg 可能瞬間從 +179° 跳到 -181° 之類，造成
	/// 「反向旋轉一大圈」。修法：跟 [session.prevDeltaDeg] 比較、補 ±360°
	/// 使得新的 delta 跟前一次 delta 在連續軌跡上、不會突然翻轉。
	void updateRotate({
		required int secondPointerId,
		required ui.Offset firstPointerPos,
		required ui.Offset secondPointerPos,
	}) {
		final _RotateSession? s = _rotateSessions[secondPointerId];
		if (s == null) return;
		final ui.Offset v1 = secondPointerPos - firstPointerPos;
		final double v1AngleRad = atan2(v1.dy, v1.dx);
		double deltaDeg = (v1AngleRad - s.v0AngleRad) * 180 / pi;
		// 跟前一次 delta 比較、補 360° 使移動軌跡連續（unwrap）。
		final double prev = s.prevDeltaDeg;
		while (deltaDeg - prev > 180.0) {
			deltaDeg -= 360.0;
		}
		while (deltaDeg - prev < -180.0) {
			deltaDeg += 360.0;
		}
		s.prevDeltaDeg = deltaDeg;
		final double rawDeg = s.a0Deg + deltaDeg * PuzzleDimens.rotationGestureGain;
		setGroupTargetRotation(s.groupId, rawDeg);
	}

	/// 第二指放開：清掉 session。目標角度已在 update 過程中 snap，不需處理。
	void endRotate(int secondPointerId) {
		_rotateSessions.remove(secondPointerId);
	}

	/// 是否已過關（所有 piece 鎖定）。
	bool _completed = false;
	bool get completed => _completed;

	/// 是否已過關（ValueListenable 版，給 widget 訂閱用）。
	final ValueNotifier<bool> _completedNotifier = ValueNotifier<bool>(false);
	ValueListenable<bool> get completedListenable => _completedNotifier;

	/// 最近一次 endDrag 的吸附結果（給 UI / 音效播放用）。
	SnapResult? _lastSnapResult;
	SnapResult? get lastSnapResult => _lastSnapResult;

	/// 過關回呼（鎖定最後一片時觸發一次）。
	VoidCallback? onCompleted;

	/// 吸附 / 鎖定發生時的回呼（給音效用）。
	///
	/// 參數：[merged] 是否發生融合、[locked] 是否發生鎖定。
	void Function(bool merged, bool locked)? onSnap;

	/// 抓起 piece 時觸發（命中、開始拖曳）。
	VoidCallback? onPickup;

	/// 結束拖曳但沒發生融合也沒鎖定時觸發（單純放開）。
	VoidCallback? onDrop;

	/// 群組目標旋轉角度跨過一個 step 時觸發（給音效用「咔」一聲提示）。
	/// 兩指旋轉手勢與滾輪步進都會吃到；scatter / 融合時的 immediate set 不會。
	VoidCallback? onRotateStep;

	/// 最近一次 endDrag 觸發了「鎖定回饋動畫」的 pieceId 集合（給 painter 讀）。
	///
	/// 由 [PuzzlePiecesPainter] 或 [PuzzleBoardPainter] 取用、配合
	/// AnimationController 對該些 piece 做 elastic scale 回饋。
	/// 觸發後由動畫端用 [clearLastLockedPieces] 清除。
	final Set<int> _lastLockedPieces = <int>{};
	Set<int> get lastLockedPieces => _lastLockedPieces;
	void clearLastLockedPieces() => _lastLockedPieces.clear();

	/// 命中測試。
	///
	/// [fuzzy] = true（觸控）：用「觸點 + 上方半圓」內均勻取樣投票決定 — 每個
	/// 樣本對未鎖定 piece 由 z 高到低測 `localPath.contains`、第一個命中的 piece
	/// 得票，最後票數最多者勝出。只往上找因為下方被手指遮住。
	///
	/// [fuzzy] = false（滑鼠）：嚴格精準命中，由 z 高到低找第一個命中的 piece。
	///
	/// 找不到回傳 null。
	PuzzlePiece? hitTest(ui.Offset localPos, {bool fuzzy = false}) {
		final List<PuzzlePiece> active = layout.pieces
				.where((PuzzlePiece p) => !p.locked)
				.toList()
			..sort((PuzzlePiece a, PuzzlePiece b) {
				final int byZ = b.zIndex.compareTo(a.zIndex);
				return byZ != 0 ? byZ : b.id.compareTo(a.id);
			});

		if (!fuzzy) {
			// 滑鼠：嚴格精準命中
			for (final PuzzlePiece p in active) {
				if (p.localPath.contains(_unrotateForPiece(localPos, p))) {
					return p;
				}
			}
			return null;
		}

		// 觸控：上方半圓投票
		final Map<int, int> votes = <int, int>{}; // pieceId → 票數
		final double r = _hitNearPx;
		final double r2 = r * r;
		const double step = 4.0; // 取樣間距 4px → 半圓內約 ~55 點
		for (double dy = -r; dy <= 0; dy += step) {
			for (double dx = -r; dx <= r; dx += step) {
				if (dx * dx + dy * dy > r2) continue;
				final ui.Offset sample = localPos + ui.Offset(dx, dy);
				for (final PuzzlePiece p in active) {
					if (p.localPath.contains(_unrotateForPiece(sample, p))) {
						votes[p.id] = (votes[p.id] ?? 0) + 1;
						break; // 找到 z 最高的命中、後面跳過
					}
				}
			}
		}
		if (votes.isEmpty) return null;
		int bestId = -1;
		int bestVotes = 0;
		votes.forEach((int id, int v) {
			if (v > bestVotes) {
				bestVotes = v;
				bestId = id;
			}
		});
		for (final PuzzlePiece p in active) {
			if (p.id == bestId) return p;
		}
		return null;
	}

	/// 觸控時的投票半徑（pixel）。
	static const double _hitNearPx = 24.0;

	/// 把 stage-global 的點 [pos] 反向轉到「該 piece 自己 localPath 的座標系」。
	///
	/// painter 端：先以 group pivot 為軸 rotate(+deg)、再 translate(currentPosition)、
	/// 最後在 localPath 座標系畫。命中要倒著做：
	///   1) 以 pivot 為軸 rotate(-deg)（抵銷群組旋轉）
	///   2) 減 currentPosition（回到 piece 局部）
	///
	/// 旋轉模式關閉或群組角度 = 0 時直接走原本的 `pos - currentPosition`，沒額外成本。
	ui.Offset _unrotateForPiece(ui.Offset pos, PuzzlePiece p) {
		final double rotDeg = rotationEnabled ? groupCurrentRotation(p.groupId) : 0.0;
		if (rotDeg == 0.0) return pos - p.currentPosition;
		final ui.Offset pivot = groupPivot(p.groupId);
		final double rad = -rotDeg * pi / 180.0;
		final double cosA = cos(rad);
		final double sinA = sin(rad);
		final double dx = pos.dx - pivot.dx;
		final double dy = pos.dy - pivot.dy;
		final ui.Offset rotated = ui.Offset(
			dx * cosA - dy * sinA + pivot.dx,
			dx * sinA + dy * cosA + pivot.dy,
		);
		return rotated - p.currentPosition;
	}

	/// 開始拖曳：把命中的 piece 所屬群組標為 dragging、提升 z-index。
	///
	/// [pointerId] 由呼叫端帶入，多指可同時各自拖曳不同群組。同一群組若已被
	/// 另一個 pointer 拖曳中，此次 beginDrag 直接失敗（false），避免兩指搶同片。
	/// [fuzzy] = true 用觸控的半圓投票命中；false 用滑鼠的精準命中。
	/// [strictLocking] 記下、給 [dragBy] 的「自動 snap」與 [endDrag] 共用判定。
	/// 回傳是否成功啟動拖曳（false 表示沒命中任何 piece、或群組已被佔用）。
	bool beginDrag(
		int pointerId,
		ui.Offset localPos, {
		bool fuzzy = false,
		bool strictLocking = false,
	}) {
		// 不設並行 drag 上限：幼兒操作時手掌可能貼著螢幕、若限制兩指就會把「真的
		// 想動拼片的那指」擋掉。同一群組不能被兩指同時搶（下方 _draggingGroupIds
		// 檢查），但「不同群組可以同時被多指各自拖」是允許的。
		final PuzzlePiece? hit = hitTest(localPos, fuzzy: fuzzy);
		if (hit == null) return false;
		// 同一群組不允許被兩指同時拖曳
		if (_draggingGroupIds.contains(hit.groupId)) return false;

		final DateTime now = DateTime.now();
		_dragSessions[pointerId] = _DragSession(
			groupId: hit.groupId,
			strictLocking: strictLocking,
			startTimestamp: now,
			lastTimestamp: now,
		);
		_draggingGroupIds.add(hit.groupId);
		_bringGroupToFront(hit.groupId);
		onPickup?.call();
		bumpRepaint();
		return true;
	}

	/// 自動 snap 啟用前的延遲：本次 [beginDrag] 後至少要經過這麼久才考慮自動 snap。
	static const Duration _autoSnapWarmup = Duration(milliseconds: 500);

	/// 速度滑動視窗大小：最近 N 幀的 (distance, elapsedSec)，取總距離 / 總時間
	/// = 視窗平均速度。單幀速度因取樣頻率不穩 + distance 量化到整數 px、波動
	/// 很大，平均後比較穩定。
	static const int _speedWindowSize = 20;

	/// 拖曳中：把 delta 套到指定 pointer 對應 dragging 群組所有成員。
	///
	/// 邊界限制：拖曳群組「任一片的中心」都必須留在畫面（含 padding）內，避免
	/// 幼兒不小心把拼片拋到畫面外、找不回來。實作上算每一軸的「最大允許 delta」、
	/// 把實際 delta 夾擠之後再套用。
	///
	/// 自動 snap：每次 update 後若視窗平均速度低於
	/// [PuzzleDimens.autoSnapSpeedThreshold]，試算 snap 結果；若會 merge / lock
	/// 就直接執行、結束此次拖曳。
	void dragBy(int pointerId, ui.Offset delta) {
		final _DragSession? session = _dragSessions[pointerId];
		if (session == null) return;
		final int gid = session.groupId;
		final ui.Offset clamped = _clampGroupDelta(gid, delta);
		for (final PuzzlePiece p in layout.pieces) {
			if (p.groupId == gid) {
				p.currentPosition = p.currentPosition + clamped;
			}
		}

		// 算瞬時速度（用實際套到 piece 的 clamped delta、不用原始 delta；
		// 邊界 clamp 後速度應該算成 0）。
		// warmup：拖曳剛起步時不算自動 snap，避免「一抓起來剛好命中」就觸發。
		final DateTime now = DateTime.now();
		final DateTime prev = session.lastTimestamp;
		session.lastTimestamp = now;
		final bool warmedUp =
				now.difference(session.startTimestamp) >= _autoSnapWarmup;
		if (warmedUp) {
			final double distance = clamped.distance;
			final double elapsedSec = now.difference(prev).inMicroseconds / 1e6;
			if (elapsedSec > 0) {
				// 放進滑動視窗
				session.speedWindow
						.add((distance: distance, elapsedSec: elapsedSec));
				if (session.speedWindow.length > _speedWindowSize) {
					session.speedWindow.removeAt(0);
				}
				// 視窗滿了才考慮自動 snap（避免起步階段樣本太少不穩定）
				if (session.speedWindow.length >= _speedWindowSize) {
					double sumD = 0;
					double sumT = 0;
					for (final ({double distance, double elapsedSec}) e
							in session.speedWindow) {
						sumD += e.distance;
						sumT += e.elapsedSec;
					}
					final double avgSpeed = sumT > 0 ? sumD / sumT : 0;
					if (avgSpeed < PuzzleDimens.autoSnapSpeedThreshold) {
						_tryAutoSnap(pointerId);
					}
				}
			}
		}
		bumpRepaint();
	}

	/// 嘗試自動 snap：用相同的 [SnapDetector.resolve] 判定，成功就執行同 endDrag
	/// 的後續邏輯，並直接移除該 pointer 的 session — 後續 dragBy / endDrag 因為
	/// 找不到 session 都會 no-op，避免 `onSnap` 被同一次黏合反覆觸發、把音效
	/// 切掉自己。
	void _tryAutoSnap(int pointerId) {
		final _DragSession? session = _dragSessions[pointerId];
		if (session == null) return;
		final int gid = session.groupId;
		final SnapResult result = SnapDetector.resolve(
			layout: layout,
			draggingGroupId: gid,
			boardOrigin: stageLayout.boardOrigin,
			requireNeighborContact: session.strictLocking,
			groupRotationDeg:
					rotationEnabled ? _groupTargetRotation : const <int, int>{},
		);
		if (!result.merged && !result.locked) return;

		// 融合後新群組沿用「拖曳群」的角度（必然等於目標群、見 _findBestMerge）。
		if (result.merged && rotationEnabled) {
			final double rot = groupCurrentRotation(gid);
			setGroupRotationImmediate(result.finalGroupId, rot);
		}

		_lastSnapResult = result;
		onSnap?.call(result.merged, result.locked);
		if (result.merged) {
			_bringGroupToFront(result.finalGroupId);
		}
		if (result.locked) {
			_lastLockedPieces.clear();
			for (final PuzzlePiece p in layout.pieces) {
				if (p.groupId == result.finalGroupId && p.locked) {
					_lastLockedPieces.add(p.id);
				}
			}
			_lockBump.value = _lockBump.value + 1;
		}
		if (!_completed && _checkCompleted()) {
			_completed = true;
			_completedNotifier.value = true;
			onCompleted?.call();
		}

		// 結束此次拖曳：直接把 session 移除，後續 dragBy 找不到就 no-op，
		// 避免拼塊已 snap 之後 dragBy 又進入 SnapDetector 重複觸發 `onSnap`
		// 而把音效不斷 stop+restart 切掉自己。endDrag 同樣找不到就 no-op。
		_draggingGroupIds.remove(gid);
		_dragSessions.remove(pointerId);
	}

	/// 拼片中心必須距畫面邊緣至少這麼多 px，避免幼兒拖到看不見。
	static const double _dragBoundsInsetPx = 20.0;

	/// 把套到群組成員的 delta 夾擠到「每片中心離畫面邊緣 ≥ inset」。
	///
	/// 算法：對群組每片 piece 算「sourceRect 中心 + currentPosition」的位置；
	/// 與允許範圍 `[inset, totalW-inset] × [inset, totalH-inset]` 比較、
	/// 算出該軸最多還能加 / 減多少。各片之最小值即為實際允許量。
	ui.Offset _clampGroupDelta(int groupId, ui.Offset delta) {
		final ui.Size size = stageLayout.totalSize;
		final double minX = _dragBoundsInsetPx;
		final double maxX = size.width - _dragBoundsInsetPx;
		final double minY = _dragBoundsInsetPx;
		final double maxY = size.height - _dragBoundsInsetPx;

		double allowedDx = delta.dx;
		double allowedDy = delta.dy;
		for (final PuzzlePiece p in layout.pieces) {
			if (p.groupId != groupId) continue;
			final double cx = p.currentPosition.dx + p.sourceRect.width / 2;
			final double cy = p.currentPosition.dy + p.sourceRect.height / 2;
			if (allowedDx > 0) {
				final double room = maxX - cx;
				if (allowedDx > room) allowedDx = room < 0 ? 0 : room;
			} else if (allowedDx < 0) {
				final double room = minX - cx; // negative
				if (allowedDx < room) allowedDx = room > 0 ? 0 : room;
			}
			if (allowedDy > 0) {
				final double room = maxY - cy;
				if (allowedDy > room) allowedDy = room < 0 ? 0 : room;
			} else if (allowedDy < 0) {
				final double room = minY - cy;
				if (allowedDy < room) allowedDy = room > 0 ? 0 : room;
			}
		}
		return ui.Offset(allowedDx, allowedDy);
	}

	/// 結束拖曳：執行吸附 / 鎖定判定，必要時觸發過關。
	///
	/// [pointerId] 對應 [beginDrag] 時帶入的 pointer。若該 pointer 沒有 active
	/// session（例如已被自動 snap 提前結束），只清理 session 就 return。
	void endDrag(int pointerId) {
		final _DragSession? session = _dragSessions.remove(pointerId);
		if (session == null) {
			// 沒有 session：要嘛是 pointer 從未被 beginDrag 接管，要嘛是自動 snap
			// 已在 dragBy 中提早把 session 清掉。兩種情況都直接 no-op。
			bumpRepaint();
			return;
		}
		final int gid = session.groupId;
		_draggingGroupIds.remove(gid);

		final SnapResult result = SnapDetector.resolve(
			layout: layout,
			draggingGroupId: gid,
			boardOrigin: stageLayout.boardOrigin,
			requireNeighborContact: session.strictLocking,
			groupRotationDeg:
					rotationEnabled ? _groupTargetRotation : const <int, int>{},
		);
		_lastSnapResult = result;
		if (result.merged || result.locked) {
			onSnap?.call(result.merged, result.locked);
			// 融合後新群組沿用「拖曳群」的角度（必然等於目標群、見 _findBestMerge）。
			if (result.merged && rotationEnabled) {
				final double rot = groupCurrentRotation(gid);
				setGroupRotationImmediate(result.finalGroupId, rot);
			}
			// 融合後把整個合併群組的 z-index 提到最高，避免被其他散落塊蓋住造成
			// 奇怪的層級錯亂（融合是把 other group 拉過來，那群可能 z 較低）。
			if (result.merged) {
				_bringGroupToFront(result.finalGroupId);
			}
			// 記錄此次鎖定的 piece 們供動畫使用，並 bump 訊號
			if (result.locked) {
				_lastLockedPieces.clear();
				for (final PuzzlePiece p in layout.pieces) {
					if (p.groupId == result.finalGroupId && p.locked) {
						_lastLockedPieces.add(p.id);
					}
				}
				_lockBump.value = _lockBump.value + 1;
			}
		} else {
			// 純放開（沒融合也沒鎖定）
			onDrop?.call();
		}

		// 過關檢查：所有 piece 都鎖定 → 觸發一次
		if (!_completed && _checkCompleted()) {
			_completed = true;
			_completedNotifier.value = true;
			onCompleted?.call();
		}

		bumpRepaint();
	}

	/// 過關條件：所有 piece 都 locked。
	bool _checkCompleted() {
		for (final PuzzlePiece p in layout.pieces) {
			if (!p.locked) return false;
		}
		return true;
	}

	/// 把指定群組成員的 zIndex 全部設為「目前最大值 + 1」。
	void _bringGroupToFront(int groupId) {
		int maxZ = 0;
		for (final PuzzlePiece p in layout.pieces) {
			if (p.zIndex > maxZ) maxZ = p.zIndex;
		}
		final int newZ = maxZ + 1;
		for (final PuzzlePiece p in layout.pieces) {
			if (p.groupId == groupId) {
				p.zIndex = newZ;
			}
		}
	}

	/// 把所有 piece 飛散到散落區的隨機位置。
	///
	/// 用「完全隨機 + Lloyd 兩次」產生 N 個分散點當作各片的中心（與 Voronoi
	/// 切割模式同一套演算法，效果均勻自然）。每片中心位置會在 scatterRect 內
	/// 被夾擠，確保 sourceRect 完全落在 scatter 區域內 — 若 piece 比 scatter
	/// 還大就讓它對稱溢出。
	void scatterPiecesToRight({int seed = 0}) {
		// 換關卡時把所有拖曳 / 旋轉狀態清掉，避免舊 pointer 事件留下殘留 session。
		_dragSessions.clear();
		_draggingGroupIds.clear();
		_rotateSessions.clear();
		_groupTargetRotation.clear();
		_groupCurrentRotation.clear();
		final Random random = Random(seed);
		final ui.Rect scatter = stageLayout.scatterRect;
		final List<PuzzlePiece> pieces = layout.pieces;
		final int n = pieces.length;

		// 與 Voronoi 種子點同一套演算法（完全隨機 + 3 次 Lloyd 鬆弛）。
		final List<ui.Offset> centers = VoronoiBuilder.generatePoissonLikePoints(
			bounds: scatter,
			count: n,
			random: random,
			lloydIterations: 3,
		);

		// shuffle 配對，避免 piece id 與位置綁定
		final List<int> order = List<int>.generate(n, (int i) => i)
			..shuffle(random);

		for (int i = 0; i < n; i++) {
			final PuzzlePiece p = pieces[order[i]];
			final ui.Offset center = centers[i];
			final double halfW = p.sourceRect.width / 2;
			final double halfH = p.sourceRect.height / 2;

			// 把中心夾擠到「sourceRect 不外露」的範圍；若 piece 比 scatter 還大
			// （半邊大過 scatter 一半），clamp 的下界 > 上界、會反向。改用
			// 直接保留 generated center（即使會溢出 scatter 邊界），這樣 N=2
			// voronoi 切左右兩半時，piece 高度等同 scatter 全高、仍可保留
			// generatePoissonLikePoints 旋轉後的垂直分散。
			final double minCx = scatter.left + halfW;
			final double maxCx = scatter.right - halfW;
			final double cx = minCx > maxCx
					? scatter.center.dx
					: center.dx.clamp(minCx, maxCx);
			final double minCy = scatter.top + halfH;
			final double maxCy = scatter.bottom - halfH;
			final double cy = minCy > maxCy
					? center.dy // piece 比 scatter 高、保留原 center 容許溢出
					: center.dy.clamp(minCy, maxCy);

			p.introStartPosition = correctPositionFor(p);
			p.currentPosition = ui.Offset(cx - halfW, cy - halfH);
			p.locked = false;
			p.groupId = p.id;
		}

		// 啟用旋轉模式時、為每片（scatter 時每片自成一群）隨機選一個 step 倍數
		// 的初始角度。範圍：0 ~ 360 內所有 step 倍數，例如 grid（step=90）有
		// {0, 90, 180, 270}、voronoi（step=45）有 8 個選項。
		if (rotationEnabled && rotationStepDeg > 0) {
			final int stepCount = (360 / rotationStepDeg).round();
			for (final PuzzlePiece p in pieces) {
				final double deg = random.nextInt(stepCount) * rotationStepDeg;
				setGroupRotationImmediate(p.id, deg);
			}
		}
		_completed = false;
		_completedNotifier.value = false;
		bumpRepaint();
	}

	/// 視窗尺寸變動時呼叫：把整個拼圖場景（盤、padding、所有 piece 幾何、
	/// piece 當前位置與動畫起點）按比例縮放到新的 [newStage] 尺寸。
	///
	/// 保留所有遊戲狀態：鎖定狀態、群組關係、旋轉角度等。鎖定的 piece 用
	/// 新的「正確位置」覆蓋 currentPosition（必然完美對齊）；未鎖定的 piece
	/// 以「中心點相對 totalSize 的比例不變」原則重新放置，再夾擠回畫面內。
	///
	/// 副作用：清空 bevel / frameBevel bitmap 快取（因為都跟新尺寸不符）。
	void rescaleStage(PuzzleStageLayout newStage) {
		final ui.Size oldBoard = stageLayout.boardSize;
		if (oldBoard.width <= 0 || oldBoard.height <= 0) return;
		final double sx = newStage.boardSize.width / oldBoard.width;
		final double sy = newStage.boardSize.height / oldBoard.height;
		// 微差忽略，避免每幀都白做工。
		if ((sx - 1.0).abs() < 1e-6 &&
				(sy - 1.0).abs() < 1e-6 &&
				stageLayout.totalSize == newStage.totalSize &&
				stageLayout.boardOrigin == newStage.boardOrigin) {
			return;
		}
		final ui.Size oldTotal = stageLayout.totalSize;
		final ui.Offset oldBoardOrigin = stageLayout.boardOrigin;
		final double sScalar = (sx + sy) / 2; // padding / tabSize 走均值

		// 1. 縮放 layout-level 欄位
		layout.boardSize = newStage.boardSize;
		layout.boardPadding = layout.boardPadding * sScalar;
		layout.tabSize = layout.tabSize * sScalar;

		// 2. 縮放每片 piece 的幾何 + 位置
		final Float64List pathScale = Matrix4.diagonal3Values(sx, sy, 1).storage;
		for (final PuzzlePiece p in layout.pieces) {
			final ui.Rect oldSrc = p.sourceRect;
			p.sourceRect = _scaleRect(oldSrc, sx, sy);
			p.polygonAabb = _scaleRect(p.polygonAabb, sx, sy);
			p.localPath = p.localPath.transform(pathScale);

			if (p.locked) {
				// 鎖定的 piece 必然在「盤上 + sourceRect.topLeft」位置；新的正確
				// 位置由新 stage 推算（用 mutated layout 內的新 sourceRect.topLeft）。
				p.currentPosition = ui.Offset(
					p.sourceRect.left + newStage.boardOrigin.dx,
					p.sourceRect.top + newStage.boardOrigin.dy,
				);
			} else {
				// 未鎖定 piece：用「中心點相對 totalSize 比例」重映射。
				final double oldCx = p.currentPosition.dx + oldSrc.width / 2;
				final double oldCy = p.currentPosition.dy + oldSrc.height / 2;
				final double ratioX = oldTotal.width > 0 ? oldCx / oldTotal.width : 0;
				final double ratioY = oldTotal.height > 0 ? oldCy / oldTotal.height : 0;
				final double newCx = ratioX * newStage.totalSize.width;
				final double newCy = ratioY * newStage.totalSize.height;
				p.currentPosition = ui.Offset(
					newCx - p.sourceRect.width / 2,
					newCy - p.sourceRect.height / 2,
				);
			}

			// 進場 / 飛散動畫起點：若還在進行中、用同樣規則重算（沒有就 null）。
			final ui.Offset? introStart = p.introStartPosition;
			if (introStart != null) {
				// introStart 一般是「盤上正確位置」 = oldBoardOrigin + oldSrc.topLeft。
				// 直接用新 boardOrigin + 新 sourceRect.topLeft 即可。
				p.introStartPosition = ui.Offset(
					p.sourceRect.left + newStage.boardOrigin.dx,
					p.sourceRect.top + newStage.boardOrigin.dy,
				);
			}
			// 消除未使用警告：oldBoardOrigin 預留給未來 debug 需要時取用。
			oldBoardOrigin;
		}

		// 3. 原地更新 stageLayout 內部欄位（保持物件 reference 相同，外部持有
		//    者不必重新取）。
		stageLayout.totalSize = newStage.totalSize;
		stageLayout.boardOrigin = newStage.boardOrigin;
		stageLayout.boardSize = newStage.boardSize;
		stageLayout.scatterOrigin = newStage.scatterOrigin;
		stageLayout.scatterSize = newStage.scatterSize;

		// 4. 清空與舊尺寸綁定的 bitmap 快取
		for (final ui.Image img in bevelCache.values) {
			img.dispose();
		}
		bevelCache.clear();
		frameBevelCache?.dispose();
		frameBevelCache = null;

		// 5. 把溢出畫面的未鎖定 piece 夾擠回允許範圍內
		_clampPiecesIntoStage();

		bumpRepaint();
	}

	static ui.Rect _scaleRect(ui.Rect r, double sx, double sy) {
		return ui.Rect.fromLTRB(
			r.left * sx,
			r.top * sy,
			r.right * sx,
			r.bottom * sy,
		);
	}

	/// 把所有未鎖定 piece 的中心點夾擠到「畫面內 + 距邊 inset」的允許範圍。
	///
	/// 規則同 [_clampGroupDelta]：每片中心離畫面邊緣至少 [_dragBoundsInsetPx]。
	/// 同一群組的成員會以「群組要被推多少」為單位整體平移、保留相對位置。
	void _clampPiecesIntoStage() {
		final ui.Size size = stageLayout.totalSize;
		final double minX = _dragBoundsInsetPx;
		final double maxX = size.width - _dragBoundsInsetPx;
		final double minY = _dragBoundsInsetPx;
		final double maxY = size.height - _dragBoundsInsetPx;
		// 群組 → 需要平移的量（取所有成員「最大正向不足」與「最大負向不足」）
		final Map<int, ui.Offset> groupDelta = <int, ui.Offset>{};
		for (final PuzzlePiece p in layout.pieces) {
			if (p.locked) continue;
			final double cx = p.currentPosition.dx + p.sourceRect.width / 2;
			final double cy = p.currentPosition.dy + p.sourceRect.height / 2;
			double dx = 0;
			double dy = 0;
			if (cx < minX) dx = minX - cx;
			if (cx > maxX) dx = maxX - cx;
			if (cy < minY) dy = minY - cy;
			if (cy > maxY) dy = maxY - cy;
			if (dx == 0 && dy == 0) continue;
			final ui.Offset prev = groupDelta[p.groupId] ?? ui.Offset.zero;
			// 取「絕對值較大」的，讓所有成員都進得來。
			groupDelta[p.groupId] = ui.Offset(
				dx.abs() > prev.dx.abs() ? dx : prev.dx,
				dy.abs() > prev.dy.abs() ? dy : prev.dy,
			);
		}
		if (groupDelta.isEmpty) return;
		for (final PuzzlePiece p in layout.pieces) {
			final ui.Offset? d = groupDelta[p.groupId];
			if (d == null) continue;
			p.currentPosition = p.currentPosition + d;
		}
	}

	/// 把所有 piece 放回正確位置並標記鎖定（用於 debug / 預覽完整圖）。
	///
	/// 會觸發 [onCompleted] 一次（如果尚未過關）。
	void snapAllToCorrect() {
		for (final PuzzlePiece p in layout.pieces) {
			p.currentPosition = correctPositionFor(p);
			p.locked = true;
		}
		if (!_completed) {
			_completed = true;
			_completedNotifier.value = true;
			onCompleted?.call();
		}
		bumpRepaint();
	}

	/// 把 piece 的「拼圖盤局部正確位置」轉成 stage-global 座標。
	ui.Offset correctPositionFor(PuzzlePiece p) {
		return ui.Offset(
			p.correctPositionLocal.dx + stageLayout.boardOrigin.dx,
			p.correctPositionLocal.dy + stageLayout.boardOrigin.dy,
		);
	}

	@override
	void dispose() {
		_repaintTick.dispose();
		_lockBump.dispose();
		_completedNotifier.dispose();
		for (final ui.Image img in bevelCache.values) {
			img.dispose();
		}
		bevelCache.clear();
		frameBevelCache?.dispose();
		frameBevelCache = null;
		super.dispose();
	}

	/// 工廠：給定圖片與塊數隨機產生一場新關卡。
	///
	/// - [stageLayout]：場景區域劃分。
	/// - [boardImage] + [boardImageSize]：要拼的圖。
	/// - [pieceCount]：4~10。
	/// - [seed]：用於 cell plan 與切割（同 seed 同關卡）。
	/// - [cutMode]：切割模式（grid 方格或 voronoi 隨機）。
	static PuzzleController newLevel({
		required PuzzleStageLayout stageLayout,
		required ui.Image boardImage,
		required ui.Size boardImageSize,
		required int pieceCount,
		required int seed,
		CutMode cutMode = CutMode.grid,
	}) {
		final double boardPadding = stageLayout.boardSize.shortestSide * 0.06;
		final ui.Rect innerBounds = ui.Rect.fromLTWH(
			boardPadding,
			boardPadding,
			stageLayout.boardSize.width - 2 * boardPadding,
			stageLayout.boardSize.height - 2 * boardPadding,
		);
		final CellPlanner planner = switch (cutMode) {
			CutMode.grid => const GridCellPlanner(),
			// 不規則模式：用 Triangle planner（Voronoi 頂點 + Delaunay + 群組成長）。
			CutMode.voronoi => const TriangleCellPlanner(),
		};

		// 切割安全檢查：每片 piece 必須至少有一條 flat 邊（相鄰邊框）或一個
		// tab neighbor（透過耳朵連到其他片），否則該片在「無提示線」模式下
		// 永遠無法鎖定（見 [PuzzleCutter.validateLockability] / SnapDetector）。
		// 在加入這個防護之前，實務上從來沒有遇過這種狀況真的發生，
		// 所以就算理論上這個不是完全不可能、也是機率極低的現象，
		// 但總之保險起見還是加上防護。
		// 若檢查失敗就用新 seed 重切；retry 數量上限避免極端情況下無限迴圈。
		PuzzleLayout layout;
		int trySeed = seed;
		const int maxRetries = 20;
		// 診斷用：總 newLevel 切割耗時、每次 attempt 耗時。
		// 用來追查網頁版偶發的「過關後當機」— 若超過 500ms 印 warning。
		final Stopwatch totalSw = Stopwatch()..start();
		final List<int> attemptMs = <int>[];
		diag("newLevel: enter retry loop n=$pieceCount cutMode=$cutMode seed=$seed");
		for (int attempt = 0; ; attempt++) {
			final Stopwatch attemptSw = Stopwatch()..start();
			diag("newLevel: attempt=$attempt trySeed=$trySeed → planner.plan");
			final CellLayout cellLayout = planner.plan(
				pieceCount: pieceCount,
				innerBounds: innerBounds,
				seed: trySeed,
			);
			diag("newLevel: attempt=$attempt planner.plan done cells=${cellLayout.cells.length} → cutter");
			layout = PuzzleCutter.cut(
				boardSize: stageLayout.boardSize,
				boardPadding: boardPadding,
				cellLayout: cellLayout,
				seed: trySeed,
			);
			attemptSw.stop();
			attemptMs.add(attemptSw.elapsedMilliseconds);
			diag("newLevel: attempt=$attempt cutter done pieces=${layout.pieces.length} elapsed=${attemptSw.elapsedMilliseconds}ms → validate");
			if (PuzzleCutter.validateLockability(layout)) {
				diag("newLevel: attempt=$attempt validate PASS, break");
				break;
			}
			if (attempt >= maxRetries) {
				diag("newLevel: attempt=$attempt hit maxRetries, break");
				break;
			}
			diag("newLevel: attempt=$attempt validate FAIL, retry");
			trySeed = trySeed * 1664525 + 1013904223; // LCG 衍生下一個 seed
		}
		diag("newLevel: exit retry loop");
		totalSw.stop();
		if (totalSw.elapsedMilliseconds > 500) {
			debugPrint(
				"[puzzle] SLOW newLevel: total=${totalSw.elapsedMilliseconds}ms "
				"n=$pieceCount cutMode=$cutMode attempts=${attemptMs.length} "
				"per-attempt=$attemptMs ms",
			);
		}
		// 把 piece 的位置從相對 (0,0) 轉成相對 stage（加 boardOrigin）
		for (final PuzzlePiece p in layout.pieces) {
			p.currentPosition = ui.Offset(
				p.sourceRect.left + stageLayout.boardOrigin.dx,
				p.sourceRect.top + stageLayout.boardOrigin.dy,
			);
		}
		return PuzzleController(
			stageLayout: stageLayout,
			boardImage: boardImage,
			boardImageSize: boardImageSize,
			layout: layout,
		);
	}
}

/// 單一旋轉手勢的狀態（第二指）。第一指的拖曳 session 另外存於 [_DragSession]。
///
/// 設計重點：[v0AngleRad] 與 [a0Deg] 都是「第二指放下當下」的快照、不隨時間更新。
/// 每次 [PuzzleController.updateRotate] 都用「兩指當下夾角」減 [v0AngleRad]、
/// 乘 gain、加 [a0Deg] = target；用 fixed baseline 避免累積誤差。
class _RotateSession {
	_RotateSession({
		required this.groupId,
		required this.v0AngleRad,
		required this.a0Deg,
	});

	final int groupId;
	final double v0AngleRad;
	final double a0Deg;

	/// 上一次 [PuzzleController.updateRotate] 算出的「兩指夾角差」（度，未限值域）。
	/// 用於 unwrap：新 delta 經由 ±360 補正後跟此值連續。
	double prevDeltaDeg = 0.0;
}

/// 單一 pointer 的拖曳狀態。每根手指各自獨立。
class _DragSession {
	_DragSession({
		required this.groupId,
		required this.strictLocking,
		required this.startTimestamp,
		required this.lastTimestamp,
	});

	/// 此 pointer 正在拖曳的群組 ID。
	final int groupId;

	/// 進入時記下的「無提示線」嚴格鎖定旗標，給 dragBy / 自動 snap 共用。
	final bool strictLocking;

	/// 此次 beginDrag 時間戳，用於 auto-snap warmup 判定。
	final DateTime startTimestamp;

	/// 上一次 dragBy 時間戳，用於算瞬時速度。
	DateTime lastTimestamp;

	/// 速度滑動視窗。
	final List<({double distance, double elapsedSec})> speedWindow =
			<({double distance, double elapsedSec})>[];
}
