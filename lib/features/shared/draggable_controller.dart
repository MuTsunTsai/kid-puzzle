// 跨遊戲模式共用的拖曳基底 controller。
//
// 動機：兩個（含未來更多）遊戲模式都有「多指拖曳 piece / group」的需求、
// session lifecycle 邏輯應該共用一份。同時統一處理一個棘手的 web 邊角：
//
// **stale session sweep**：Flutter web 多指場景下、`pointerup` 偶爾不會 fire
// （iOS Safari 與 Android Chrome 皆有回報），導致 endDrag 沒被呼叫、session
// 殘留、該片之後在 [beginDrag] 被 [canBeginDragOn] 擋住、卡死無法再被拖。
// 解法是 dragBy 進來時先檢查 session 是否已過期、若是則 silently 清掉、再
// 用當前絕對位置 fallback 重新 beginDrag、玩家無感繼續操作。
//
// subclass 必須實作幾個 hook：[hitTest] / [canBeginDragOn] /
// [onDragMove] / [onDragFinalize] / [onDragPickup]。base 完全不認得任何
// game-specific 概念（group、snap、lock）、只跑 session 流程。

import "dart:ui";

import "package:flutter/foundation.dart";

import "drag_speed_tracker.dart";

/// session 超過此時間沒任何 [dragBy] 活動就視為 stale、會被 sweep 清掉。
///
/// 500ms 的取捨：
/// - 太短（< 200ms）會誤砍「使用者短暫停頓」的合法 session
/// - 太長（> 1s）使用者要等很久才能恢復、體感差
/// - 真實漏 fire 場景下：使用者放手後不會再產生 dragBy、500ms 後該 session
///   被 sweep；下次 down 進來 beginDrag 就能順利通過
const Duration kSessionStaleAfter = Duration(milliseconds: 500);

/// 單一 pointer 的拖曳狀態。
///
/// 用 generic [P] 表示拖曳對象的型別（PuzzlePiece / InsetPiece / …）。
/// subclass 透過 [DraggableController] 的 hook methods 拿到 session 後、
/// 自己決定怎麼解讀 `piece`（多片拼圖視為「群組代表片」、嵌入拼圖視為
/// 「該片本身」）。
class DragSession<P> {
	DragSession({required this.piece})
			: speed = DragSpeedTracker(
					slowThreshold: defaultAutoSnapSpeedThreshold,
				)..start(),
				lastActivity = DateTime.now();

	/// 此次拖曳的對象。
	final P piece;

	/// 速度追蹤、給 auto-snap 用。
	final DragSpeedTracker speed;

	/// 最後一次 [DraggableController.dragBy] 觸發的時間戳。
	/// 給 stale sweep 比對用、會被 base 自動更新。
	DateTime lastActivity;
}

/// auto-snap 的速度門檻預設值（px/sec）。
/// 各 subclass 若需要覆寫、繼續沿用該值即可（DragSpeedTracker 在 base 內固定用此值）。
const double defaultAutoSnapSpeedThreshold = 30.0;

/// 拖曳結束（手動 endDrag 或 auto-snap）後的結果摘要。
///
/// base 只用兩個欄位決定後續行為：
/// - `didSomething`：subclass 是否視為「有效 snap」（merged / locked / snapped）；
///   true 時 base 不會再呼叫 `onDrop`、session 直接結束
/// - `completed`：整關是否完成；true 時 base 呼叫 [DraggableController.onCompleted]
class DragOutcome {
	const DragOutcome({
		this.didSomething = false,
		this.completed = false,
	});

	final bool didSomething;
	final bool completed;

	static const DragOutcome none = DragOutcome();
}

/// 抽象拖曳 controller。subclass 實作 game-specific hook、base 跑 session
/// lifecycle + stale sweep + fallback。
abstract class DraggableController<P> extends ChangeNotifier {
	/// 所有 active session（key = pointer id）。
	/// 用 protected map 而非 private、給 subclass 在自訂 [canBeginDragOn] 時
	/// 線性掃描（例如「同一 group 是否已被別指拖」）。
	@protected
	final Map<int, DragSession<P>> sessions = <int, DragSession<P>>{};

	/// 玩家放下拼片但沒 snap 時觸發；以及 auto-snap 時觸發 didSomething 路徑、
	/// 由 subclass 自己呼叫對應的 `onSnap` 回調。
	void Function()? onDrop;

	/// beginDrag 成功時觸發。
	void Function()? onPickup;

	/// 整關完成時觸發一次（subclass 透過 [DragOutcome.completed] 通知 base）。
	/// 由 subclass 自行追蹤是否已過關、避免重複觸發。
	void Function()? onCompleted;

	// ───────── 必 override 的 hook ─────────

	/// hit test：給定畫面座標、回傳被命中的 piece、沒命中回 null。
	@protected
	P? hitTest(Offset pos, {bool fuzzy = false});

	/// 是否允許在 [piece] 上開始新的 drag。
	/// 例如多片拼圖檢查「該 group 是否已被別指拖」、嵌入拼圖檢查「該片是否已 locked」。
	@protected
	bool canBeginDragOn(P piece);

	/// 套 [rawDelta] 到 [session] 對應的內容物上、回傳實際套用的 delta（可能因
	/// 邊界 clamp 而比 raw 小）。回傳值會餵 [DragSession.speed] 算 auto-snap。
	@protected
	Offset onDragMove(DragSession<P> session, Offset rawDelta);

	/// 嘗試結束此次拖曳的 snap 邏輯（手動 endDrag 與 auto-snap 共用入口）。
	/// 回傳 [DragOutcome] 告訴 base 是否要視為「有效 snap」、是否觸發整關完成。
	///
	/// [isAutoSnap] = true 時表示由 [dragBy] 內速度低自動觸發、subclass 可選擇
	/// 不同行為（例如不播 onDrop）。
	@protected
	DragOutcome onDragFinalize(DragSession<P> session, {required bool isAutoSnap});

	/// beginDrag 成功時呼叫、subclass 用來做 bring-to-front 等視覺處理。
	/// base 已經呼叫過 [onPickup] callback、subclass 不需要重複。
	@protected
	void onDragPickup(P piece);

	// ───────── 對外 API ─────────

	/// 嘗試開始拖曳。
	/// 回傳 true = 開啟成功、false = 沒命中或 [canBeginDragOn] 拒絕。
	bool beginDrag(int pointerId, Offset pos, {bool fuzzy = false}) {
		final P? hit = hitTest(pos, fuzzy: fuzzy);
		if (hit == null) return false;
		if (!canBeginDragOn(hit)) return false;
		sessions[pointerId] = DragSession<P>(piece: hit);
		onDragPickup(hit);
		onPickup?.call();
		notifyListeners();
		return true;
	}

	/// 拖曳中：套 [delta] 到對應 session 的內容物。
	///
	/// 額外行為：
	/// - 進來時若該 pointer 的 session 已逾時 [kSessionStaleAfter]、視為「up event
	///   漏 fire 的殘留」、silently 清掉
	/// - 若 session 不存在（含剛被 sweep / 從未 beginDrag）、用 [absolutePos]
	///   嘗試 fallback 重 beginDrag、玩家無感繼續拖
	/// - 套完 delta 後若速度低、呼叫 [onDragFinalize] 做 auto-snap
	void dragBy(int pointerId, Offset absolutePos, Offset delta) {
		DragSession<P>? session = sessions[pointerId];

		// 1. stale sweep：silently 清、不呼叫 onDragFinalize（符合「timeout 不
		//    觸發 snap」的設計）
		if (session != null && _isStale(session)) {
			sessions.remove(pointerId);
			session = null;
		}

		// 2. fallback 重 beginDrag：使用者其實沒放手、平台漏 fire 才走這條
		if (session == null) {
			if (!beginDrag(pointerId, absolutePos, fuzzy: true)) return;
			session = sessions[pointerId];
			if (session == null) return;
		}

		// 3. 正常 move
		session.lastActivity = DateTime.now();
		final Offset clamped = onDragMove(session, delta);

		// 4. auto-snap：速度低 + warmup + 視窗滿
		if (session.speed.recordAndCheckSlow(distance: clamped.distance)) {
			final DragOutcome outcome =
					onDragFinalize(session, isAutoSnap: true);
			if (outcome.didSomething) {
				// 直接 remove、不呼叫 onDrop（auto-snap 已是「snap 成功」path）
				sessions.remove(pointerId);
				if (outcome.completed) onCompleted?.call();
			}
		}
		notifyListeners();
	}

	/// 結束拖曳（pointer up / cancel）。session 不在表示已被 auto-snap 或
	/// stale sweep 提早清掉、直接 no-op。
	void endDrag(int pointerId) {
		final DragSession<P>? session = sessions.remove(pointerId);
		if (session == null) {
			notifyListeners();
			return;
		}
		final DragOutcome outcome =
				onDragFinalize(session, isAutoSnap: false);
		if (!outcome.didSomething) {
			onDrop?.call();
		}
		if (outcome.completed) onCompleted?.call();
		notifyListeners();
	}

	/// 換新關卡 / dispose 時呼叫、把所有 session 清空。
	@protected
	void clearAllSessions() {
		sessions.clear();
	}

	bool _isStale(DragSession<P> session) {
		return DateTime.now().difference(session.lastActivity) >
				kSessionStaleAfter;
	}
}
