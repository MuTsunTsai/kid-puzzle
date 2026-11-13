/// 3D 點擊的選取：一次點擊取好幾條視線（手指上方半圓內的樣本，比照
/// features/shared/touch_vote_hit.dart 的範圍），每條視線打到一串動物。
///
/// 選擇規則：先比 [tier]（越大越優先），同 tier 選離手指中心最近的。
///
/// 2D 拼圖是「票數」最多的勝出，要測完所有樣本；3D 每條視線都要逐一測模型的三角形
/// （引擎沒有加速結構），60 幾條視線在桌機就要 100 多 ms。所以：
/// - 由近到遠一條一條測，一碰到最高優先（[maxTier]，例如還沒數過的題目動物）就停：
///   最常見的「直接點在題目動物身上」只要測一條。
/// - 已經找到某個 tier 之後，後面的視線只需要找「更高 tier」的：[castRay] 收到目前的
///   tier，應該直接排除不高於它的（不測它們的三角形），例如點到已數過的動物時，
///   不會每條視線都重測牠。
///
/// [castRay]：第 i 條視線（0 = 離中心最近）、只要 tier > [minTierExclusive] 的命中
/// （由近到遠）。[rayCount]：視線總數。
T? pickNearestByTier<T extends Object>({
	required int rayCount,
	required Iterable<T> Function(int i, int minTierExclusive) castRay,
	required int Function(T) tier,
	required int maxTier,
}) {
	T? best;
	int bestTier = -1;
	for (int i = 0; i < rayCount; i++) {
		for (final T a in castRay(i, bestTier)) {
			final int t = tier(a);
			// 同 tier 不換：先找到的離中心比較近
			if (t > bestTier) {
				best = a;
				bestTier = t;
				if (t >= maxTier) return best;
			}
		}
	}
	return best;
}

/// 手指上方半圓內的取樣點（相對於按下的位置），依離中心的距離由近到遠排列。
List<({double dx, double dy})> upperHalfDiscSamples(double radius, double step) {
	final List<({double dx, double dy})> out = <({double dx, double dy})>[
		for (double dy = -radius; dy <= 0; dy += step)
			for (double dx = -radius; dx <= radius; dx += step)
				if (dx * dx + dy * dy <= radius * radius) (dx: dx, dy: dy),
	];
	out.sort((({double dx, double dy}) a, ({double dx, double dy}) b) =>
			(a.dx * a.dx + a.dy * a.dy).compareTo(b.dx * b.dx + b.dy * b.dy));
	return out;
}
