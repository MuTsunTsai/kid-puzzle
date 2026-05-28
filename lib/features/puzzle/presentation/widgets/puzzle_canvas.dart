import "package:flutter/gestures.dart";
import "package:flutter/material.dart";
import "package:flutter/scheduler.dart";

import "../../puzzle_dimens.dart";
import "../../domain/models/puzzle_piece.dart";
import "../painters/puzzle_board_painter.dart";
import "../painters/puzzle_pieces_painter.dart";
import "../puzzle_controller.dart";

/// 整合拼圖盤、散落區與手勢輸入的 widget。
///
/// 結構：Stack（board painter 在底、pieces painter 在中、GestureDetector 在上）。
/// 內部持有兩個 AnimationController：
/// - [_lockFeedback]：每次 endDrag 觸發鎖定就跑一次 220ms elasticOut 0→1，
///   painter 把它換算成 scale 1.0 → 1.05 → 1.0 套到「最近鎖定」的 pieces。
/// - [_intro]：進關卡 / 換關卡時跑一次：散落區拼片從正確位置飛到散落位 +
///   切割線提示沿 path 描繪浮現。
class PuzzleCanvas extends StatefulWidget {
	const PuzzleCanvas({
		super.key,
		required this.controller,
		this.showCutLineHint = true,
		this.imageShownAt,
	});

	final PuzzleController controller;
	final bool showCutLineHint;

	/// 「未切割大圖開始顯示」的時刻。Canvas mount 後會比對 `now - imageShownAt`：
	/// 若小於 200ms 就先 hold 補滿 200ms 再啟動進場動畫；否則立刻啟動。
	/// null 表示不做 hold（行為與舊版相同）。
	final DateTime? imageShownAt;

	@override
	State<PuzzleCanvas> createState() => _PuzzleCanvasState();
}

class _PuzzleCanvasState extends State<PuzzleCanvas>
		with TickerProviderStateMixin {
	late final AnimationController _lockFeedback;
	late final AnimationController _intro;
	late final AnimationController _outro;

	/// 目前已被本 widget 接管成 drag 的 pointer id 集合（=「第一指」們）。
	///
	/// 不限制並行數量：幼兒可能多指或手掌貼著、各自拖不同拼片都允許。同一片
	/// 不能被兩指搶的規則在 [PuzzleController.beginDrag] 內處理。沒被
	/// beginDrag 接管的 pointer 不會進這集合，後續 move / up 會被忽略，避免
	/// 「點到空白卻被當成拖曳」的雜訊。
	final Set<int> _activePointerIds = <int>{};

	/// 旋轉模式：每個 pointer 的最新位置（用來算兩指夾角、消歧距離）。
	///
	/// 涵蓋 drag 與 rotate 兩種角色的 pointer — drag pointer 也要記，因為
	/// rotate 公式需要「兩指當下位置」、且新 pointer 落下時需查 first 位置
	/// 算消歧距離。
	final Map<int, Offset> _pointerPositions = <int, Offset>{};

	/// 旋轉模式：第二指 pointer → 它依附的「第一指」（drag pointer）。
	/// 同一個 first pointer 同時只允許一個 rotate 第二指（更多手指都忽略）。
	final Map<int, int> _rotatePointerToFirst = <int, int>{};

	/// 旋轉動畫：每個未達 target 的群組「當前顯示角度」往 target 收斂。
	/// 只在 controller.rotationEnabled 開啟時建立，且只在有未達標群組時啟動。
	late final Ticker _rotationTicker;
	Duration? _lastTickerTime;

	@override
	void initState() {
		super.initState();
		_lockFeedback = AnimationController(
			vsync: this,
			duration: const Duration(milliseconds: 220),
		);
		// 進場動畫總長：500ms reveal + 1000ms scatter = 1500ms。
		// 200ms 最低 hold 由 page 端管（呼叫 _scheduleIntro 時計算 wait time）。
		_intro = AnimationController(
			vsync: this,
			duration: const Duration(milliseconds: 1500),
		);
		// 完成淡出：拼塊細節 1 → 0 在 500ms 內完成
		_outro = AnimationController(
			vsync: this,
			duration: const Duration(milliseconds: 500),
		);
		_rotationTicker = createTicker(_onRotationTick);
		widget.controller.lockBump.addListener(_onLockBump);
		widget.controller.completedListenable.addListener(_onCompletedChange);
		// 進場動畫：等到「圖顯示滿 200ms」才啟動 reveal 動畫。
		WidgetsBinding.instance.addPostFrameCallback((_) {
			if (mounted) _scheduleIntro();
		});
	}

	/// 計算「離 imageShownAt 滿 200ms」還要多久；到時間就 forward _intro。
	void _scheduleIntro() {
		const Duration hold = Duration(milliseconds: 200);
		final DateTime? shown = widget.imageShownAt;
		final Duration wait;
		if (shown == null) {
			wait = Duration.zero;
		} else {
			final Duration elapsed = DateTime.now().difference(shown);
			wait = elapsed >= hold ? Duration.zero : hold - elapsed;
		}
		if (wait == Duration.zero) {
			_intro.forward(from: 0);
		} else {
			Future<void>.delayed(wait, () {
				if (mounted) _intro.forward(from: 0);
			});
		}
	}

	/// 啟動旋轉動畫 ticker（若尚未跑）。Tick 函式自己會在沒有未達標群組時 stop。
	void _ensureRotationTicker() {
		if (!_rotationTicker.isActive) {
			_lastTickerTime = null;
			_rotationTicker.start();
		}
	}

	/// 每幀推進：對每個 target != current 的群組以 step / [rotationSnapMs] 速率
	/// 收斂；沒有未達標群組時停 ticker、避免 idle 耗電。
	void _onRotationTick(Duration elapsed) {
		final Duration? prev = _lastTickerTime;
		_lastTickerTime = elapsed;
		if (prev == null) return; // 第一幀無 dt 可用
		final double dtMs =
				(elapsed - prev).inMicroseconds / 1000.0;
		if (dtMs <= 0) return;
		// 旋轉一個 step（90° 或 45°）需要 rotationSnapMs 毫秒；推進量 = step × dt/snapMs。
		final double maxAdvance =
				widget.controller.rotationStepDeg * dtMs / PuzzleDimens.rotationSnapMs;

		bool stillActive = false;
		for (final int gid in _allGroupIds()) {
			final double target =
					widget.controller.groupTargetRotation(gid).toDouble();
			final double current = widget.controller.groupCurrentRotation(gid);
			// 最短弧距：target 已規範化在 (-180, 180]，current 可能任意大；先把
			// diff 規範化到 (-180, 180] 再推進，避免「轉了 N 圈，target 規範
			// 化後變小、動畫往反方向繞一大圈」。
			double diff = target - current;
			diff = diff % 360.0;
			if (diff > 180.0) diff -= 360.0;
			if (diff <= -180.0) diff += 360.0;
			if (diff.abs() < 0.001) {
				// 已對齊：把 current 鎖死到精確 target，避免浮點殘渣
				widget.controller.setGroupCurrentRotation(gid, target);
				continue;
			}
			final double step =
					diff.abs() <= maxAdvance ? diff : maxAdvance * diff.sign;
			final double nextCurrent = current + step;
			widget.controller.setGroupCurrentRotation(gid, nextCurrent);
			// 推進後若還沒到、保持 ticker 運作
			double remaining = (target - nextCurrent) % 360.0;
			if (remaining > 180.0) remaining -= 360.0;
			if (remaining <= -180.0) remaining += 360.0;
			if (remaining.abs() > 0.001) stillActive = true;
		}
		if (!stillActive) {
			_rotationTicker.stop();
			_lastTickerTime = null;
		}
	}

	/// 蒐集所有 piece 的 groupId（去重）— 用於 ticker 中遍歷未達標群組。
	Iterable<int> _allGroupIds() {
		final Set<int> ids = <int>{};
		for (final PuzzlePiece p in widget.controller.layout.pieces) {
			ids.add(p.groupId);
		}
		return ids;
	}

	@override
	void didUpdateWidget(covariant PuzzleCanvas oldWidget) {
		super.didUpdateWidget(oldWidget);
		if (oldWidget.controller != widget.controller) {
			oldWidget.controller.lockBump.removeListener(_onLockBump);
			oldWidget.controller.completedListenable.removeListener(_onCompletedChange);
			widget.controller.lockBump.addListener(_onLockBump);
			widget.controller.completedListenable.addListener(_onCompletedChange);
			_scheduleIntro();
			_outro.reset();
		}
	}

	void _onLockBump() {
		_lockFeedback.forward(from: 0);
	}

	// === Pointer 處理 ===
	// 用底層 [Listener] 自己管 active pointer，忽略多餘的觸控。
	// 幼兒可能同時用多指亂滑、確保只有一個拼片在拖。

	void _onPointerDown(PointerDownEvent event) {
		_pointerPositions[event.pointer] = event.localPosition;
		// 觸控用半圓投票（fuzzy）；滑鼠 / 觸控筆走嚴格精準命中。
		final bool isTouch = event.kind == PointerDeviceKind.touch;

		// 非旋轉模式：保留原行為 —— 命中未拖的拼片開新 drag、其他一律忽略。
		// （beginDrag 內已處理「同片不能兩指搶」、「不限制並行數」。）
		if (!widget.controller.rotationEnabled) {
			final bool started = widget.controller.beginDrag(
				event.pointer,
				event.localPosition,
				fuzzy: isTouch,
				strictLocking: !widget.showCutLineHint,
			);
			if (started) _activePointerIds.add(event.pointer);
			return;
		}

		// === 旋轉模式 ===
		// 決策樹（以 fuzzy hitTest 做半圓投票命中）：
		// (1) 命中正在被拖的群組 → 該群組旋轉第二指（已有 second 則忽略）。
		// (2) 命中未被拖的拼片 → 若離所有 active first 都 > 門檻就開新 drag、
		//     否則當「最近 first」的旋轉第二指（已有 second 則忽略）。
		// (3) 命中空白 → 找最近的 active first，若距離 ≤ 門檻就當它的旋轉第
		//     二指；否則忽略。
		final PuzzlePiece? hit = widget.controller.hitTest(
			event.localPosition,
			fuzzy: isTouch,
		);

		if (hit != null) {
			// 命中某拼片 P：先看 P 所屬群組是否正被某 first 拖。
			final int hitGroupId = hit.groupId;
			final int? firstOnSameGroup = _findFirstByGroup(hitGroupId);
			if (firstOnSameGroup != null) {
				// (1) 命中正在拖的群組 → 必旋轉。
				_tryAttachRotate(event.pointer, firstOnSameGroup);
				return;
			}
			// P 沒被拖：(2) 用距離決定開新 drag 還是旋轉。
			final int? nearestFirst = _nearestFirstWithinThreshold(
				event.localPosition,
			);
			if (nearestFirst == null) {
				// 離所有 first 都 > 門檻（或沒有任何 first）→ 開新 drag。
				final bool started = widget.controller.beginDrag(
					event.pointer,
					event.localPosition,
					fuzzy: isTouch,
					strictLocking: !widget.showCutLineHint,
				);
				if (started) _activePointerIds.add(event.pointer);
				return;
			}
			// 在門檻內 → 視為 nearestFirst 的旋轉第二指。
			_tryAttachRotate(event.pointer, nearestFirst);
			return;
		}

		// (3) 命中空白：只在門檻內找 first 可附；否則完全忽略。
		final int? nearestFirst = _nearestFirstWithinThreshold(
			event.localPosition,
		);
		if (nearestFirst != null) {
			_tryAttachRotate(event.pointer, nearestFirst);
		}
	}

	/// 嘗試把 [secondPointer] 附為 [firstPointer] 的旋轉第二指。
	/// 若該 first 已有 second 則 no-op（規則：每 first 最多一 second）。
	void _tryAttachRotate(int secondPointer, int firstPointer) {
		if (_findSecondPointerForFirst(firstPointer) != null) return;
		final int? groupId = widget.controller.groupIdForPointer(firstPointer);
		if (groupId == null) return;
		final Offset firstPos =
				_pointerPositions[firstPointer] ?? Offset.zero;
		final Offset secondPos =
				_pointerPositions[secondPointer] ?? Offset.zero;
		widget.controller.beginRotate(
			secondPointerId: secondPointer,
			groupId: groupId,
			firstPointerPos: firstPos,
			secondPointerPos: secondPos,
		);
		_rotatePointerToFirst[secondPointer] = firstPointer;
	}

	/// 找出當前正在拖某 [groupId] 的 first pointer（無則 null）。
	int? _findFirstByGroup(int groupId) {
		for (final int p in _activePointerIds) {
			if (widget.controller.groupIdForPointer(p) == groupId) return p;
		}
		return null;
	}

	/// 從所有 active first 中找距離 [pos] 最近的一個；要求距離 ≤
	/// [PuzzleDimens.rotationProximityPx] 才回傳，否則 null。
	int? _nearestFirstWithinThreshold(Offset pos) {
		int? nearest;
		double bestDist = PuzzleDimens.rotationProximityPx;
		for (final int p in _activePointerIds) {
			final Offset? fp = _pointerPositions[p];
			if (fp == null) continue;
			final double d = (fp - pos).distance;
			if (d <= bestDist) {
				bestDist = d;
				nearest = p;
			}
		}
		return nearest;
	}

	void _onPointerMove(PointerMoveEvent event) {
		_pointerPositions[event.pointer] = event.localPosition;
		if (_activePointerIds.contains(event.pointer)) {
			widget.controller.dragBy(event.pointer, event.delta);
			// 第一指在動：若它身上有第二指附著，要重算旋轉目標（用兩指當下位置）
			final int? secondPointer = _findSecondPointerForFirst(event.pointer);
			if (secondPointer != null) {
				_updateRotate(secondPointer);
			}
			return;
		}
		if (_rotatePointerToFirst.containsKey(event.pointer)) {
			_updateRotate(event.pointer);
			_ensureRotationTicker();
		}
	}

	void _onPointerUp(PointerUpEvent event) {
		_pointerPositions.remove(event.pointer);
		if (_activePointerIds.remove(event.pointer)) {
			// 第一指抬起。先結束它的拖曳；若有附著的第二指、嘗試讓第二指升級
			// 成新的 first（對幼兒友善：原本「兩指轉」其中一指放開、剩下那指
			// 自然延續操作）。
			final int? secondPointer = _findSecondPointerForFirst(event.pointer);
			if (secondPointer != null) {
				// 結束 rotate 對。second 暫時是 orphan。
				widget.controller.endRotate(secondPointer);
				_rotatePointerToFirst.remove(secondPointer);
			}
			widget.controller.endDrag(event.pointer);

			// second 升級：用它當前位置嘗試 beginDrag；命中拼片就成功。
			// 若失敗（second 落在空白處）就讓它變空閒 pointer、不再處理。
			if (secondPointer != null) {
				final Offset? sp = _pointerPositions[secondPointer];
				if (sp != null) {
					final bool started = widget.controller.beginDrag(
						secondPointer,
						sp,
						fuzzy: true,
						strictLocking: !widget.showCutLineHint,
					);
					if (started) {
						_activePointerIds.add(secondPointer);
						// 升級成 first 後、再看是否能配對到「等候中」的某指：
						// 此處沒有 pending 概念，剩下的 active first 若離 second
						// 近、可以反過來吃它當自己的 second。但這會讓行為過於
						// 複雜、不做。使用者要繼續旋轉就抬起重新觸控即可。
					}
				}
			}
			return;
		}
		if (_rotatePointerToFirst.remove(event.pointer) != null) {
			widget.controller.endRotate(event.pointer);
		}
	}

	void _onPointerCancel(PointerCancelEvent event) => _onPointerUp(
				PointerUpEvent(pointer: event.pointer, position: event.position),
			);

	/// 桌機版滑鼠滾輪 = 旋轉。對 hover 命中的群組推進一個 step（向下滾順時針、
	/// 向上滾逆時針）。觸控裝置不會發送 PointerScrollEvent，所以這條路徑不衝突。
	void _onPointerSignal(PointerSignalEvent event) {
		if (!widget.controller.rotationEnabled) return;
		if (event is! PointerScrollEvent) return;
		final double dy = event.scrollDelta.dy;
		if (dy == 0) return;
		final PuzzlePiece? hit = widget.controller.hitTest(event.localPosition);
		if (hit == null) return;
		final int gid = hit.groupId;
		final double step = widget.controller.rotationStepDeg;
		final double direction = dy > 0 ? 1.0 : -1.0;
		final double current =
				widget.controller.groupTargetRotation(gid).toDouble();
		widget.controller.setGroupTargetRotation(gid, current + step * direction);
		_ensureRotationTicker();
	}

	/// 找出依附於 [firstPointer] 的「第二指」pointer id（旋轉手勢）。
	int? _findSecondPointerForFirst(int firstPointer) {
		for (final MapEntry<int, int> e in _rotatePointerToFirst.entries) {
			if (e.value == firstPointer) return e.key;
		}
		return null;
	}

	void _updateRotate(int secondPointer) {
		final int? firstPointer = _rotatePointerToFirst[secondPointer];
		if (firstPointer == null) return;
		final Offset firstPos = _pointerPositions[firstPointer] ?? Offset.zero;
		final Offset secondPos =
				_pointerPositions[secondPointer] ?? Offset.zero;
		widget.controller.updateRotate(
			secondPointerId: secondPointer,
			firstPointerPos: firstPos,
			secondPointerPos: secondPos,
		);
		_ensureRotationTicker();
	}

	void _onCompletedChange() {
		if (widget.controller.completed) {
			_outro.forward(from: 0);
		} else {
			_outro.reset();
		}
	}

	/// 從整體 progress [t] 切出 [start, end] 區間的 0..1 子進度。
	static double _stageProgress(double t, double start, double end) {
		if (t <= start) return 0;
		if (t >= end) return 1;
		return ((t - start) / (end - start)).clamp(0.0, 1.0);
	}

	@override
	void dispose() {
		widget.controller.lockBump.removeListener(_onLockBump);
		widget.controller.completedListenable.removeListener(_onCompletedChange);
		_rotationTicker.dispose();
		_lockFeedback.dispose();
		_intro.dispose();
		_outro.dispose();
		super.dispose();
	}

	@override
	Widget build(BuildContext context) {
		final double dpr = MediaQuery.devicePixelRatioOf(context);
		return SizedBox.expand(
			child: Stack(
				children: <Widget>[
					Positioned.fill(
						child: AnimatedBuilder(
							animation: Listenable.merge(<Listenable>[_intro, _outro]),
							builder: (BuildContext context, _) {
								final double t = _intro.value.clamp(0.0, 1.0);
								// reveal 階段：0~500ms（佔總時長 0 ~ 500/1500）
								final double reveal = Curves.easeOut.transform(
									_stageProgress(t, 0, 500 / 1500),
								);
								final double outroFade = Curves.easeIn.transform(_outro.value);
								final double details = reveal * (1.0 - outroFade);
								return CustomPaint(
									painter: PuzzleBoardPainter(
										controller: widget.controller,
										showCutLineHint: widget.showCutLineHint,
										devicePixelRatio: dpr,
										cutLineRevealProgress: reveal,
										boardDetailsOpacity: details,
									),
								);
							},
						),
					),
					Positioned.fill(
						child: AnimatedBuilder(
							animation: Listenable.merge(<Listenable>[
								widget.controller.repaintTick,
								_lockFeedback,
								_intro,
								_outro,
							]),
							builder: (BuildContext context, _) {
								final double t = _intro.value.clamp(0.0, 1.0);
								final double reveal = Curves.easeOut.transform(
									_stageProgress(t, 0, 500 / 1500),
								);
								// scatter 階段：500ms~1500ms（佔總時長 500/1500 ~ 1.00）
								final double scatter = Curves.easeOutCubic.transform(
									_stageProgress(t, 500 / 1500, 1.0),
								);
								final double outroFade = Curves.easeIn.transform(_outro.value);
								return CustomPaint(
									painter: PuzzlePiecesPainter(
										controller: widget.controller,
										devicePixelRatio: dpr,
										draggingGroupIds: widget.controller.draggingGroupIds,
										lockFeedbackProgress: _lockFeedback.value,
										pieceBevelOpacity: reveal * (1.0 - outroFade),
										introProgress: scatter,
									),
								);
							},
						),
					),
					Positioned.fill(
						child: Listener(
							behavior: HitTestBehavior.opaque,
							onPointerDown: _onPointerDown,
							onPointerMove: _onPointerMove,
							onPointerUp: _onPointerUp,
							onPointerCancel: _onPointerCancel,
							onPointerSignal: _onPointerSignal,
						),
					),
				],
			),
		);
	}
}
