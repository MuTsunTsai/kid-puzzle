import "dart:math";
import "dart:ui" as ui;

import "package:flutter/foundation.dart";
import "package:flutter/material.dart" show Color;

import "../../../core/sprites/sprite_manifest.dart";
import "../../../core/sprites/sprite_registry.dart";
import "../../puzzle/presentation/puzzle_controller.dart" show PuzzleStageLayout;
import "../../shared/draggable_controller.dart";
import "../../shared/macaron_color.dart";
import "../../shared/scatter_layout.dart";
import "../../shared/touch_vote_hit.dart";
import "../domain/inset_piece.dart";
import "../domain/profanity_filter.dart";

/// 嵌入拼圖遊戲狀態。
///
/// - 每片 = 一個 sprite 物件、不需切割
/// - 每片在 board 上有一個 [InsetPiece.slotRect]（凹槽位置）
/// - snap 用「片中心 vs slot 中心距離 < tolerance」判定；鎖定後無法再拖
/// - 全鎖定 → onCompleted
class InsetPuzzleController extends DraggableController<InsetPiece> {
	InsetPuzzleController({
		required this.stageLayout,
		required this.registry,
		required this.category,
		required this.pieces,
		required this.boardColor,
	});

	final PuzzleStageLayout stageLayout;
	final SpriteRegistry registry;
	final SpriteCategory category;
	final List<InsetPiece> pieces;

	/// 底板的馬卡龍底色（painter 烤底板時用）。
	Color boardColor;

	final ValueNotifier<int> _repaintTick = ValueNotifier<int>(0);
	ValueListenable<int> get repaintTick => _repaintTick;

	void bumpRepaint() {
		_repaintTick.value = _repaintTick.value + 1;
	}

	/// 4:3 底板區域在 stage 全域座標下的矩形。佔 stageLayout.boardRect 內最大
	/// 的 4:3、置中。各 piece 的 slotRect 都在這個 board 內。
	ui.Rect boardRect = ui.Rect.zero;

	// ───────── 回呼 ─────────
	// onPickup / onDrop / onCompleted 在 base 上、不重複宣告。

	/// 一片 snap 成功（鎖定）時觸發。引數是被鎖定的 piece。
	/// 呼叫端可用來播該物件名稱語音（缺語音 fallback 到 snap.mp3）。
	void Function(InsetPiece piece)? onSnap;

	bool _completed = false;
	bool get completed => _completed;

	// ───────── HitTest ─────────

	/// 命中測試：對未鎖定 piece 由 z 高到低找第一個 alpha > 門檻。
	/// 用 sprite alpha 而非矩形 bounds，避免「點在透明 padding 上也命中」。
	///
	/// [fuzzy] = true（觸控）：走 [touchVoteHit] — 在點上方半圓內取樣投票，
	/// 票數最高的 candidate 勝出。對應「使用者把手指對在物件下緣」的習慣。
	/// [fuzzy] = false（滑鼠）：嚴格單點命中。
	@override
	InsetPiece? hitTest(ui.Offset pos,
			{bool fuzzy = false, int alphaThreshold = 32}) {
		final ui.Offset stagePos = pos;
		final List<InsetPiece> active = pieces.where((InsetPiece p) => !p.locked).toList()
			..sort((InsetPiece a, InsetPiece b) {
				final int byZ = b.zIndex.compareTo(a.zIndex);
				return byZ != 0 ? byZ : a.id.compareTo(b.id);
			});
		if (!fuzzy) {
			for (final InsetPiece p in active) {
				if (_alphaAtStagePoint(p, stagePos) > alphaThreshold) return p;
			}
			return null;
		}
		return touchVoteHit<InsetPiece>(
			point: stagePos,
			candidates: active,
			idOf: (InsetPiece p) => p.id,
			hitsAt: (InsetPiece p, ui.Offset sample) =>
					_alphaAtStagePoint(p, sample) > alphaThreshold,
		);
	}

	/// 給按鈕重疊判定用：任一未鎖定片在該點 alpha > 門檻就回 true。
	bool isOpaqueAtStagePoint(ui.Offset stagePos, {int alphaThreshold = 32}) {
		for (final InsetPiece p in pieces) {
			if (p.locked) continue;
			if (_alphaAtStagePoint(p, stagePos) > alphaThreshold) return true;
		}
		return false;
	}

	int _alphaAtStagePoint(InsetPiece p, ui.Offset stagePos) {
		final double dx = stagePos.dx - p.currentPosition.dx;
		final double dy = stagePos.dy - p.currentPosition.dy;
		final double w = p.displaySize.width;
		final double h = p.displaySize.height;
		if (dx < 0 || dy < 0 || dx >= w || dy >= h) return 0;
		final SpriteSheet sheet = category.sheet;
		final int lx = (dx / w * sheet.tile).floor();
		final int ly = (dy / h * sheet.tile).floor();
		// 3×3 鄰域取最大 alpha，避免戳到細筆畫的空隙
		int best = 0;
		for (int oy = -1; oy <= 1; oy++) {
			for (int ox = -1; ox <= 1; ox++) {
				final int a = registry.alphaInItemLocal(p.item, lx + ox, ly + oy);
				if (a > best) best = a;
			}
		}
		return best;
	}

	// ───────── 拖曳 API （走 base [DraggableController] 統一管理 session） ─────────

	/// 同一片不能被兩指搶；已 locked 的片也不可再被拖。
	@override
	bool canBeginDragOn(InsetPiece piece) {
		if (piece.locked) return false;
		for (final DragSession<InsetPiece> s in sessions.values) {
			if (s.piece.id == piece.id) return false;
		}
		return true;
	}

	@override
	void onDragPickup(InsetPiece piece) {
		_bringToFront(piece);
		bumpRepaint();
	}

	/// 套 delta 到 piece、回 clamped。base 用 clamped 餵 speed tracker。
	@override
	ui.Offset onDragMove(
		DragSession<InsetPiece> session,
		ui.Offset delta,
	) {
		final InsetPiece p = session.piece;
		if (p.locked) return ui.Offset.zero;
		final ui.Offset clamped = _clampPieceDelta(p, delta);
		p.currentPosition = p.currentPosition + clamped;
		bumpRepaint();
		return clamped;
	}

	/// 嘗試 snap（auto-snap 與手動 endDrag 共用入口）。
	/// 沒 snap 成功時回 [DragOutcome.none]、base 在手動 endDrag 路徑會觸發
	/// `onDrop`、在 auto-snap 路徑會保留 session 給玩家繼續拖。
	@override
	DragOutcome onDragFinalize(
		DragSession<InsetPiece> session, {
		required bool isAutoSnap,
	}) {
		final InsetPiece p = session.piece;
		if (p.locked) return DragOutcome.none;
		if (!_trySnap(p)) {
			return DragOutcome.none;
		}
		final bool nowCompleted = !_completed && _allLocked();
		if (nowCompleted) _completed = true;
		bumpRepaint();
		return DragOutcome(didSomething: true, completed: nowCompleted);
	}

	/// 嘗試把 [p] snap 到自己的 slot。回傳是否 snap 成功。
	/// 給 [onDragFinalize]（手動 endDrag 與 auto-snap 都呼叫它）使用。
	bool _trySnap(InsetPiece p) {
		final ui.Offset pieceCenter = p.currentPosition +
				ui.Offset(p.displaySize.width / 2, p.displaySize.height / 2);
		final ui.Offset slotCenter = p.slotRect.center;
		final double dist = (pieceCenter - slotCenter).distance;
		final double tolerance = p.slotRect.shortestSide * 0.3;
		if (dist >= tolerance) return false;
		p.currentPosition = p.slotRect.topLeft;
		p.locked = true;
		onSnap?.call(p);
		// 過關判定統一在 [onDragFinalize] 內處理（用 DragOutcome.completed 通知 base
		// 觸發 onCompleted、避免重複）。這裡只 snap 與 lock。
		return true;
	}

	bool _allLocked() {
		for (final InsetPiece p in pieces) {
			if (!p.locked) return false;
		}
		return true;
	}

	void _bringToFront(InsetPiece p) {
		int maxZ = 0;
		for (final InsetPiece q in pieces) {
			if (q.zIndex > maxZ) maxZ = q.zIndex;
		}
		p.zIndex = maxZ + 1;
	}

	static const double _insetPx = 20.0;

	ui.Offset _clampPieceDelta(InsetPiece p, ui.Offset delta) {
		final ui.Size size = stageLayout.totalSize;
		final double cx = p.currentPosition.dx + p.displaySize.width / 2;
		final double cy = p.currentPosition.dy + p.displaySize.height / 2;
		double dx = delta.dx;
		double dy = delta.dy;
		final double minX = _insetPx;
		final double maxX = size.width - _insetPx;
		final double minY = _insetPx;
		final double maxY = size.height - _insetPx;
		if (dx > 0 && cx + dx > maxX) dx = (maxX - cx).clamp(0, double.infinity);
		if (dx < 0 && cx + dx < minX) dx = (minX - cx).clamp(double.negativeInfinity, 0);
		if (dy > 0 && cy + dy > maxY) dy = (maxY - cy).clamp(0, double.infinity);
		if (dy < 0 && cy + dy < minY) dy = (minY - cy).clamp(double.negativeInfinity, 0);
		return ui.Offset(dx, dy);
	}

	// ───────── Rescale ─────────

	/// 視窗 / canvas 尺寸變動時呼叫。重算 [boardRect]、所有 slot 與未鎖定片位置。
	void rescaleStage(PuzzleStageLayout newStage) {
		final ui.Size oldTotal = stageLayout.totalSize;
		if (oldTotal.width <= 0 || oldTotal.height <= 0) return;
		final ui.Rect oldBoard = boardRect;

		// 1. 算新 boardRect（newStage.boardRect 內最大 4:3、置中）
		boardRect = _fit43(newStage.boardRect);

		// 2. 每片 slotRect / displaySize 按 board 縮放
		final double sx = oldBoard.width > 0 ? boardRect.width / oldBoard.width : 1;
		final double sy = oldBoard.height > 0 ? boardRect.height / oldBoard.height : 1;
		for (final InsetPiece p in pieces) {
			// slot 相對 board 的位置等比縮放
			final double slotRelLeft = (p.slotRect.left - oldBoard.left) * sx;
			final double slotRelTop = (p.slotRect.top - oldBoard.top) * sy;
			final double newW = p.slotRect.width * sx;
			final double newH = p.slotRect.height * sy;
			p.slotRect = ui.Rect.fromLTWH(
				boardRect.left + slotRelLeft,
				boardRect.top + slotRelTop,
				newW,
				newH,
			);
			p.displaySize = ui.Size(newW, newH);

			if (p.locked) {
				p.currentPosition = p.slotRect.topLeft;
			} else {
				// 未鎖定片：用「中心相對 totalSize 比例」重映射
				final double oldCx = p.currentPosition.dx + (p.displaySize.width / 2) / sx;
				final double oldCy = p.currentPosition.dy + (p.displaySize.height / 2) / sy;
				final double ratioX = oldCx / oldTotal.width;
				final double ratioY = oldCy / oldTotal.height;
				p.currentPosition = ui.Offset(
					ratioX * newStage.totalSize.width - newW / 2,
					ratioY * newStage.totalSize.height - newH / 2,
				);
			}
		}

		// 3. 原地更新 stageLayout
		stageLayout.totalSize = newStage.totalSize;
		stageLayout.boardOrigin = newStage.boardOrigin;
		stageLayout.boardSize = newStage.boardSize;
		stageLayout.scatterOrigin = newStage.scatterOrigin;
		stageLayout.scatterSize = newStage.scatterSize;

		_clampPiecesIntoStage();
		bumpRepaint();
	}

	void _clampPiecesIntoStage() {
		final ui.Size size = stageLayout.totalSize;
		final double minX = _insetPx;
		final double maxX = size.width - _insetPx;
		final double minY = _insetPx;
		final double maxY = size.height - _insetPx;
		for (final InsetPiece p in pieces) {
			if (p.locked) continue;
			final double cx = p.currentPosition.dx + p.displaySize.width / 2;
			final double cy = p.currentPosition.dy + p.displaySize.height / 2;
			double dx = 0;
			double dy = 0;
			if (cx < minX) dx = minX - cx;
			if (cx > maxX) dx = maxX - cx;
			if (cy < minY) dy = minY - cy;
			if (cy > maxY) dy = maxY - cy;
			if (dx != 0 || dy != 0) {
				p.currentPosition = p.currentPosition + ui.Offset(dx, dy);
			}
		}
	}

	@override
	void dispose() {
		_repaintTick.dispose();
		super.dispose();
	}

	// ───────── 工廠 ─────────

	/// 在 [outer] 內取最大 4:3 矩形、置中。
	static ui.Rect _fit43(ui.Rect outer) {
		double w = outer.width;
		double h = outer.height;
		if (w / h > 4 / 3) {
			w = h * 4 / 3;
		} else {
			h = w * 3 / 4;
		}
		return ui.Rect.fromCenter(center: outer.center, width: w, height: h);
	}

	/// 開新一關：抽 N 物件、物理模擬安排不重疊的 slot、散落到右半。
	///
	/// 流程：
	/// 1. 抽 N 個物件
	/// 2. 所有片用同一 tile 尺寸（依片數公式）
	/// 3. 物理模擬：隨機分布後迭代（斥力 = alpha 重疊面積、引力 = 朝群體
	///    重心的常數加速度）直到穩定或達 maxIters
	/// 4. 二分法找最大 scale 把整群塞進 board × (1 - padding)
	/// 5. 散落片到右半 scatter 區
	static Future<InsetPuzzleController> newLevel({
		required PuzzleStageLayout stageLayout,
		required SpriteRegistry registry,
		required SpriteCategory category,
		required List<SpriteItem> chosen,
		required int seed,
		/// Debug 用：每代結束後呼叫一次（給 UI 畫動畫）。null = 不推進度。
		///
		/// 第一個 callback `onSettleChosen` 在抽完 items 後、settle 開始前
		/// 觸發一次，讓呼叫端拿到 items 用以畫 sprite（chosen items 順序與
		/// 之後 onSettleStep 的 centers 一一對應）。
		void Function(List<SpriteItem> chosen, ui.Rect container)? onSettleChosen,
		Future<void> Function(List<ui.Offset> centers, double tile)? onSettleStep,
	}) async {
		await registry.preloadCategory(category);
		await registry.preloadCategoryPixels(category);

		final Random random = Random(seed);
		final Color boardColor = macaronColor(random);
		final int n = chosen.length;

		// 2. 物理模擬（撞球模型）：在 4:3 邊框內、tile 動態縮放、無引力。
		//    收斂後直接拿到 finalCenters + finalTile。
		const double paddingFactor = 0.9;
		final ui.Rect board = _fit43(stageLayout.boardRect);
		final ui.Rect container = ui.Rect.fromCenter(
			center: board.center,
			width: board.width * paddingFactor,
			height: board.height * paddingFactor,
		);
		final double initialTile = container.shortestSide / sqrt(n);
		// 初次 settle 前：把當前 chosen 順序通知 debug UI（後續 reroll 會再
		// 補一次、見下方 loop）。
		onSettleChosen?.call(chosen, container);

		// 髒字檢查 + reroll loop：
		// 物理收斂後檢查當前 (items 順序 × centers) 是否會在橫排上拼出髒字；
		// 若有 → shuffle items 順序、復用既有 centers 當初始位置、重 settle。
		// 因為位置已經大致就位、shuffle 只造成少量重疊、物理收斂很快。
		List<SpriteItem> currentChosen = chosen;
		List<ui.Offset> settledCenters;
		double settledTile;
		(settledCenters, settledTile) = await _settleLayout(
			registry: registry,
			items: currentChosen,
			initialTile: initialTile,
			container: container,
			random: random,
			onStep: onSettleStep,
		);
		const int maxRerolls = 8;
		for (int attempt = 0; attempt < maxRerolls; attempt++) {
			if (!ProfanityFilter.detect(
				centers: settledCenters,
				items: currentChosen,
				tile: settledTile,
			)) {
				break;
			}
			debugPrint("[inset_puzzle] profanity detected, reroll #${attempt + 1}");
			// Shuffle items 順序（centers 不動 → 等於每個位置換成另一個 item）。
			final List<SpriteItem> shuffled = List<SpriteItem>.of(currentChosen)
				..shuffle(random);
			currentChosen = shuffled;
			onSettleChosen?.call(currentChosen, container);
			(settledCenters, settledTile) = await _settleLayout(
				registry: registry,
				items: currentChosen,
				initialTile: settledTile,
				container: container,
				random: random,
				onStep: onSettleStep,
				initialCenters: settledCenters,
			);
		}
		// retry 上限到了仍有髒字 → 硬撐用最後一次結果（極端 case 不卡死遊戲）。
		// 從 chosen 改名為 currentChosen、後續流程用 currentChosen 對應 centers。

		// 3. 後處理：算整群「實際非透明像素」的 AABB（每片用 alphaBoundsOf 推算），
		//    縮放使該 AABB 剛好塞進 container（padding 用完）、整體置中。
		//    這修正了物理模擬的兩種尾巴：
		//    (a) 收斂時還沒貼牆但已穩定 → 留白太多 → 放大
		//    (b) 收斂時某片超出 board（dilation 邊距吃到 padding）→ 縮小
		final (List<ui.Offset> finalCenters, double finalTile) =
				_fitAndCenter(
			centers: settledCenters,
			tile: settledTile,
			items: currentChosen,
			registry: registry,
			container: container,
		);

		// 5. 散落到右半 scatter 區。用 Voronoi-Lloyd 分散點 + 夾擠到 scatter 內。
		final ui.Rect scatter = stageLayout.scatterRect;
		final List<ui.Offset> scatterCenters = await computeScatterCenters(
			bounds: scatter,
			count: n,
			random: random,
		);
		final double halfTile = finalTile / 2;
		final double minCx = scatter.left + halfTile;
		final double maxCx = scatter.right - halfTile;
		final double minCy = scatter.top + halfTile;
		final double maxCy = scatter.bottom - halfTile;
		final List<InsetPiece> built = <InsetPiece>[];
		for (int i = 0; i < n; i++) {
			final ui.Rect slot = ui.Rect.fromCenter(
				center: finalCenters[i],
				width: finalTile,
				height: finalTile,
			);
			final ui.Offset rawCenter = scatterCenters[i];
			final double cx = minCx > maxCx
					? scatter.center.dx
					: rawCenter.dx.clamp(minCx, maxCx);
			final double cy = minCy > maxCy
					? rawCenter.dy
					: rawCenter.dy.clamp(minCy, maxCy);
			built.add(InsetPiece(
				id: currentChosen[i].id,
				item: currentChosen[i],
				slotRect: slot,
				displaySize: ui.Size(finalTile, finalTile),
				currentPosition: ui.Offset(cx - halfTile, cy - halfTile),
			));
		}
		for (int i = 0; i < built.length; i++) {
			built[i].zIndex = i;
		}

		final InsetPuzzleController c = InsetPuzzleController(
			stageLayout: stageLayout,
			registry: registry,
			category: category,
			pieces: built,
			boardColor: boardColor,
		);
		c.boardRect = board;
		return c;
	}

	// ───────── 布局物理模擬（撞球模型） ─────────

	/// 迭代上限。
	static const int _maxIters = 100;

	/// 斥力增益：把 alpha 重疊像素數轉成位移量（stage-pixel）的係數。
	/// 模擬退火：起點大（積極推開）、終點小（細修微抖）。線性插值。
	/// 太小 → 片彼此推不動、tile 直接縮到沒重疊；太大 → 抖動發散。
	static const double _repulsionGainStart = 3.0;
	static const double _repulsionGainEnd = 0.1;

	/// 牆面回彈增益：被牆推回的位移量乘這個係數套到 piece。
	/// 1.0 = 全部退回；< 1 容許暫時越界但會被吸回，讓片之間有空間擠。
	static const double _wallPushGain = 0.5;

	/// 單代每片受力位移的上限（占 tile 比例）。避免單一次推力過大、片瞬間
	/// 飛進牆裡造成「方向看起來只剩另一軸」的假象。
	static const double _maxStepRatio = 0.15;

	/// 每代 tile 基準膨脹率：沒任何斥力 / 壓力時 tile 會以此速率放大。
	/// 模擬退火：起點大（積極膨脹）、終點小（細修），與斥力一起線性衰退。
	static const double _tileGrowRateStart = 1.1;
	static const double _tileGrowRateEnd = 1.005;

	/// 壓力對膨脹的抵消係數：tileRate = grow - _pressureGain × (壓力 / N / tile)。
	/// 壓力 / 片數 / tile = 「平均每片每 tile 受到的位移量」，無量綱、和 tile
	/// 尺度無關，這個係數的物理意義是「壓力多大時膨脹速率降到 0」。
	/// 取 grow / threshold；threshold = 0.05 表示「每片每代被推 5% tile 時剛好不膨脹」。
	static const double _pressureGain = 0.20;

	/// 連續多少代「tile 變化 < tileEps + 總位移 < moveEps」才算穩定。
	static const int _stableStreak = 6;

	/// tile 變化量比例閾值（占當代 tile）。
	static const double _tileEps = 0.0005;

	/// 每代總位移占 tile 比例閾值。
	static const double _moveEps = 0.002;

	/// 重疊判定的「擴張半徑」（占 tile 比例）。等效於對 alpha mask 做這麼大
	/// 的 dilation 再比對 — 讓拼片之間至少留出這個比例的安全間距。
	static const double _dilateRatio = 0.07;

	/// 撞球模型：在 [container] 內讓 N 片彼此推擠 + 撞牆，同時動態縮放 tile。
	///
	/// 收斂規則：
	/// - 每代：算斥力 + 牆面推回 → 套到 piece 位置；無重疊也無撞牆 → tile 放大、
	///   否則 → tile 縮小
	/// - 連續 [_stableStreak] 代 tile 與位移都低於閾值 → 穩定停止
	/// - 上限 [_maxIters]
	///
	/// 回傳 (centers, tile)：centers 在 stage 全域座標、tile 為最終正方形邊長。
	///
	/// 若 [onStep] 不為 null，每代結束後會呼叫一次 + await（給 debug 動畫用、
	/// 同步把每幀推到 UI；正式 newLevel 不傳，跑完一次完成）。
	static Future<(List<ui.Offset>, double)> _settleLayout({
		required SpriteRegistry registry,
		required List<SpriteItem> items,
		required double initialTile,
		required ui.Rect container,
		required Random random,
		Future<void> Function(List<ui.Offset> centers, double tile)? onStep,
		/// 可選的初始 center 位置（長度需等於 items.length）。
		/// 給「shuffle items 後復用既有位置」的 reroll 流程用，物理會從這組
		/// 位置開始解少量重疊、收斂快很多。null = 走原本的均勻隨機初始化。
		List<ui.Offset>? initialCenters,
	}) async {
		final int n = items.length;
		if (n == 0) return (const <ui.Offset>[], initialTile);

		double tile = initialTile;

		// 初始位置：若呼叫端傳入 initialCenters 就直接用；否則均勻散在
		// container 內（避開貼牆、留半 tile 邊距）。
		final List<ui.Offset> centers = initialCenters != null &&
						initialCenters.length == n
				? List<ui.Offset>.of(initialCenters)
				: <ui.Offset>[
						for (int i = 0; i < n; i++)
							ui.Offset(
								container.left + tile / 2 +
										random.nextDouble() * (container.width - tile),
								container.top + tile / 2 +
										random.nextDouble() * (container.height - tile),
							),
					];

		// 預烤每片的低解析度 dilated alpha mask（res×res，res 由 registry 決定）。
		// 熱迴圈內 O(1) 查詢，比 alphaInItemLocal 快數十倍。
		final List<DilatedMask?> masks = <DilatedMask?>[
			for (final SpriteItem item in items)
				registry.dilatedMaskOf(item, _dilateRatio),
		];

		int stableCount = 0;
		for (int iter = 0; iter < _maxIters; iter++) {
			// 模擬退火：iter 從 0 → _maxIters - 1 對應退火進度 0 → 1。
			final double t = _maxIters > 1 ? iter / (_maxIters - 1) : 1.0;
			final double repulsionGain =
					_repulsionGainStart + (_repulsionGainEnd - _repulsionGainStart) * t;
			final double tileGrowRate =
					_tileGrowRateStart + (_tileGrowRateEnd - _tileGrowRateStart) * t;

			final List<ui.Offset> forces = List<ui.Offset>.filled(n, ui.Offset.zero);
			double repulsionMag = 0;
			double wallPush = 0;

			// 1. 斥力（軟碰撞）
			for (int i = 0; i < n; i++) {
				for (int j = i + 1; j < n; j++) {
					final int overlap = _maskOverlapCount(
						maskA: masks[i], aCenter: centers[i],
						maskB: masks[j], bCenter: centers[j],
						tile: tile,
					);
					if (overlap <= 0) continue;
					ui.Offset dir = centers[j] - centers[i];
					double dist = dir.distance;
					if (dist < 0.001) {
						final double a = random.nextDouble() * pi * 2;
						dir = ui.Offset(cos(a), sin(a));
						dist = 1;
					}
					final ui.Offset unit = dir / dist;
					final double mag = overlap * repulsionGain;
					forces[i] = forces[i] - unit * mag;
					forces[j] = forces[j] + unit * mag;
					// 雙向各算一次的位移量都計入「壓力」
					repulsionMag += mag * 2;
				}
			}

			// 2. 更新位置 + 牆面硬碰撞（clamp 並累計推回量當壓力指標）
			//    先把每片受力 clamp 到「最多 tile × _maxStepRatio」，避免單代位移
			//    過大、片直接飛進牆裡 → 牆全力反推時方向看起來只剩另一軸。
			double totalMove = 0;
			final double half = tile / 2;
			final double maxStep = tile * _maxStepRatio;
			for (int i = 0; i < n; i++) {
				ui.Offset f = forces[i];
				final double fLen = f.distance;
				if (fLen > maxStep) f = f * (maxStep / fLen);
				ui.Offset np = centers[i] + f;
				double pushX = 0, pushY = 0;
				if (np.dx - half < container.left) {
					pushX = container.left + half - np.dx;
				} else if (np.dx + half > container.right) {
					pushX = container.right - half - np.dx;
				}
				if (np.dy - half < container.top) {
					pushY = container.top + half - np.dy;
				} else if (np.dy + half > container.bottom) {
					pushY = container.bottom - half - np.dy;
				}
				if (pushX != 0 || pushY != 0) {
					np = np + ui.Offset(pushX, pushY) * _wallPushGain;
					wallPush += pushX.abs() + pushY.abs();
				}
				final ui.Offset moved = np - centers[i];
				centers[i] = np;
				totalMove += moved.distance;
			}

			// 3. 動態縮放：tile 總是「想」以當代 tileGrowRate 膨脹；總壓力
			//    （斥力 + 牆面推回）會抵消這個膨脹率。壓力大到一定程度，
			//    膨脹率變負 → tile 縮小。穩定態 = 膨脹欲望剛好被壓力抵消。
			//    退火進度 t 把 grow 與斥力一起壓低、加速收斂。
			final double prevTile = tile;
			final double pressure = (repulsionMag + wallPush) / n / tile;
			final double growExcess = tileGrowRate - 1.0;
			final double rate = 1.0 + growExcess - _pressureGain * pressure;
			tile *= rate.clamp(0.5, 2.0); // 安全範圍，避免 numerical 爆掉

			// 4. 收斂判定
			final double tileRel = (tile - prevTile).abs() / prevTile;
			final double moveRel = totalMove / n / tile;
			if (tileRel < _tileEps && moveRel < _moveEps) {
				stableCount++;
				if (stableCount >= _stableStreak) {
					// 收斂前也呼叫一次 onStep 讓 UI 顯示最終態
					if (onStep != null) await onStep(centers, tile);
					break;
				}
			} else {
				stableCount = 0;
			}

			// 5. debug 動畫：把這代 snapshot 推到 UI、await 控制節奏
			if (onStep != null) {
				await onStep(List<ui.Offset>.of(centers), tile);
			} else if ((iter & 7) == 0) {
				// 正式路徑：每 8 代讓出 UI thread，避免高片數時阻塞
				await Future<void>.delayed(Duration.zero);
			}
		}
		return (centers, tile);
	}


	/// 用預烤的 dilated mask 算兩片重疊像素數。AABB 不交集即 0。
	///
	/// 與舊的 [_alphaOverlapCount] 邏輯等價（同樣是「dilated 中心 vs dilated
	/// 中心」），但執行期單點查 = 一次陣列存取、比每點 9 次 alphaInItemLocal
	/// 快數十倍。
	///
	/// 採樣步長從 stage-pixel 2px 放寬到 4px，再砍 4 倍工作量；對「壓力指標」
	/// 精度仍足夠。
	static int _maskOverlapCount({
		required DilatedMask? maskA,
		required ui.Offset aCenter,
		required DilatedMask? maskB,
		required ui.Offset bCenter,
		required double tile,
	}) {
		if (maskA == null || maskB == null) return 0;
		final double halfTile = tile / 2;
		final ui.Rect rectA = ui.Rect.fromLTWH(
				aCenter.dx - halfTile, aCenter.dy - halfTile, tile, tile);
		final ui.Rect rectB = ui.Rect.fromLTWH(
				bCenter.dx - halfTile, bCenter.dy - halfTile, tile, tile);
		final ui.Rect inter = rectA.intersect(rectB);
		if (inter.isEmpty) return 0;
		// 採樣解析度 = mask 解析度（已經是 1/10 原圖、再採更密無意義）。
		final int resA = maskA.resolution;
		final int resB = maskB.resolution;
		final Uint8List dataA = maskA.data;
		final Uint8List dataB = maskB.data;
		// stage-pixel → mask-local
		final double scaleA = resA / tile;
		final double scaleB = resB / tile;
		final double relALeft = inter.left - rectA.left;
		final double relATop = inter.top - rectA.top;
		final double relBLeft = inter.left - rectB.left;
		final double relBTop = inter.top - rectB.top;
		// step = 一個 mask cell 對應的 stage-pixel；對較小 res（A/B 不同也可能）
		// 取較密那邊以免錯過接觸區。
		final double step = tile / (resA > resB ? resA : resB);
		int count = 0;
		double yOff = 0;
		while (yOff < inter.height) {
			final int layRaw = ((relATop + yOff) * scaleA).toInt();
			final int lbyRaw = ((relBTop + yOff) * scaleB).toInt();
			if (layRaw >= 0 && layRaw < resA && lbyRaw >= 0 && lbyRaw < resB) {
				final int rowAOffset = layRaw * resA;
				final int rowBOffset = lbyRaw * resB;
				double xOff = 0;
				while (xOff < inter.width) {
					final int laxRaw = ((relALeft + xOff) * scaleA).toInt();
					final int lbxRaw = ((relBLeft + xOff) * scaleB).toInt();
					if (laxRaw >= 0 && laxRaw < resA &&
							lbxRaw >= 0 && lbxRaw < resB) {
						if (dataA[rowAOffset + laxRaw] != 0 &&
								dataB[rowBOffset + lbxRaw] != 0) {
							count++;
						}
					}
					xOff += step;
				}
			}
			yOff += step;
		}
		return count;
	}

	/// 物理模擬收斂後的「最後一哩」：算「所有片實際非透明像素」AABB 聯集，
	/// 縮放使其剛好塞進 [container]、整體置中。
	///
	/// 修正物理模擬的兩種尾巴：
	/// (a) 收斂但還沒貼牆 → 留白太多 → 放大
	/// (b) 收斂時某片局部超出 board（dilation 邊距吃到 padding）→ 縮小
	static (List<ui.Offset>, double) _fitAndCenter({
		required List<ui.Offset> centers,
		required double tile,
		required List<SpriteItem> items,
		required SpriteRegistry registry,
		required ui.Rect container,
	}) {
		final int n = centers.length;
		if (n == 0) return (centers, tile);

		// 1. 算每片實際非透明 AABB（stage 座標）。alphaBoundsOf 回的是 tile-local
		//    pixel；換成「相對 tile center」的比例後再乘 tile 套到 stage center。
		double minX = double.infinity;
		double minY = double.infinity;
		double maxX = -double.infinity;
		double maxY = -double.infinity;
		for (int i = 0; i < n; i++) {
			final SpriteItem item = items[i];
			final SpriteCategory? cat = registry.categoryOfItem(item.id);
			if (cat == null) continue;
			final int tilePx = cat.sheet.tile;
			final ui.Rect? bounds = registry.alphaBoundsOf(item);
			final ui.Rect rel = bounds ??
					ui.Rect.fromLTWH(0, 0, tilePx.toDouble(), tilePx.toDouble());
			// rel 是相對 tile 左上的 pixel 座標；換到 stage：以 center 為基準
			final double scale = tile / tilePx;
			final double left = centers[i].dx - tile / 2 + rel.left * scale;
			final double top = centers[i].dy - tile / 2 + rel.top * scale;
			final double right = left + rel.width * scale;
			final double bottom = top + rel.height * scale;
			if (left < minX) minX = left;
			if (top < minY) minY = top;
			if (right > maxX) maxX = right;
			if (bottom > maxY) maxY = bottom;
		}
		if (minX == double.infinity) return (centers, tile);

		final double unionW = maxX - minX;
		final double unionH = maxY - minY;
		final ui.Offset unionCenter = ui.Offset(
			(minX + maxX) / 2,
			(minY + maxY) / 2,
		);

		// 2. 算把該 union 塞進 container 的最大 scale（取 x/y 較緊那邊）。
		final double sx = unionW > 0 ? container.width / unionW : 1.0;
		final double sy = unionH > 0 ? container.height / unionH : 1.0;
		final double scale = sx < sy ? sx : sy;

		// 3. 以 unionCenter 為錨點 scale + 平移到 container.center。
		final List<ui.Offset> out = <ui.Offset>[
			for (final ui.Offset c in centers)
				ui.Offset(
					(c.dx - unionCenter.dx) * scale + container.center.dx,
					(c.dy - unionCenter.dy) * scale + container.center.dy,
				),
		];
		return (out, tile * scale);
	}
}

// 嵌入拼圖的 per-pointer 拖曳狀態已搬到 base [DragSession]。
// auto-snap 速度門檻沿用 base 的 [defaultAutoSnapSpeedThreshold]。
