/// 拖曳速度追蹤器：用於「拖很慢時自動 snap」判定。
///
/// 動機：幼兒缺乏「放開以確認」概念；當拖曳速度降到某個閾值以下、且目前
/// 位置已符合 snap 條件時，直接觸發 snap 比要求他們鬆手更友善。
///
/// 用法：
/// ```dart
/// final tracker = DragSpeedTracker();
/// // pointer down 時：
/// tracker.start();
/// // 每次 drag delta 套到 piece 後：
/// if (tracker.recordAndCheckSlow(distance: actualMoveDistance)) {
///   trySnap();
/// }
/// ```
///
/// 內建：
/// - **Warmup**：start 後 [warmupMs] 內不觸發（避免「剛抓起來就 snap」）。
/// - **Sliding window**：累積最近 [windowSize] 筆 (distance, elapsedSec)，
///   取總距離 / 總時間當平均速度。單幀速度因取樣頻率不穩 + distance 量化
///   到整數 px 波動大，平均後穩定很多。
/// - **採用 clamped distance**：呼叫端應傳「實際套到 piece 的位移量」（邊界
///   clamp 後的值），讓貼牆瞬間視同停止。
class DragSpeedTracker {
	DragSpeedTracker({
		this.warmupMs = 500,
		this.windowSize = 20,
		this.slowThreshold = 30.0,
	});

	/// 拖曳開始後多久才開始考慮自動 snap。
	final int warmupMs;

	/// 滑動視窗大小。
	final int windowSize;

	/// 平均速度（px/sec）低於此值視為「慢」。
	final double slowThreshold;

	int _startMicros = 0;
	int _lastMicros = 0;
	final List<({double distance, double elapsedSec})> _window =
			<({double distance, double elapsedSec})>[];

	void start() {
		final int now = DateTime.now().microsecondsSinceEpoch;
		_startMicros = now;
		_lastMicros = now;
		_window.clear();
	}

	/// 紀錄一次拖曳的實際位移量，回傳是否「慢」（達 warmup + 視窗滿 + 平均速度 < 閾值）。
	bool recordAndCheckSlow({required double distance}) {
		final int now = DateTime.now().microsecondsSinceEpoch;
		final int prev = _lastMicros;
		_lastMicros = now;
		if (now - _startMicros < warmupMs * 1000) return false;
		final double elapsedSec = (now - prev) / 1e6;
		if (elapsedSec <= 0) return false;
		_window.add((distance: distance, elapsedSec: elapsedSec));
		if (_window.length > windowSize) _window.removeAt(0);
		if (_window.length < windowSize) return false;
		double sumD = 0;
		double sumT = 0;
		for (final ({double distance, double elapsedSec}) e in _window) {
			sumD += e.distance;
			sumT += e.elapsedSec;
		}
		final double avgSpeed = sumT > 0 ? sumD / sumT : 0;
		return avgSpeed < slowThreshold;
	}
}
