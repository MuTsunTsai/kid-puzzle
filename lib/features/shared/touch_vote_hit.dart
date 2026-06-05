import "dart:ui";

/// 觸控的「上方半圓投票」命中測試。
///
/// 動機：幼兒觸控的「實際手指接觸區」是一塊圓形，而 pointer 報告的點通常是
/// 接觸區重心；但手指會把實際想點的物件擋住，使用者多半把手指對在「目標的
/// 下緣」附近。因此命中區域取「pointer 點上方的半圓」更貼近意圖。
///
/// 流程：在上方半圓內以 [step] 為間距均勻取樣 → 對每個樣本由 z 高到低
/// (candidate list 先排好) 找第一個命中者得票 → 票數最高的 candidate 勝出。
///
/// 通用化：呼叫端負責提供 [candidates]（已依 z 高到低排序）、唯一 id getter
/// [idOf]、以及樣本點命中判斷 [hitsAt]（candidate, samplePoint → bool）。
///
/// 找不到 (votes 為空) 回 null。
T? touchVoteHit<T>({
	required Offset point,
	required List<T> candidates,
	required Object Function(T) idOf,
	required bool Function(T candidate, Offset sample) hitsAt,
	double radius = 24,
	double step = 4,
}) {
	final double r2 = radius * radius;
	final Map<Object, int> votes = <Object, int>{};
	for (double dy = -radius; dy <= 0; dy += step) {
		for (double dx = -radius; dx <= radius; dx += step) {
			if (dx * dx + dy * dy > r2) continue;
			final Offset sample = point + Offset(dx, dy);
			for (final T c in candidates) {
				if (hitsAt(c, sample)) {
					final Object id = idOf(c);
					votes[id] = (votes[id] ?? 0) + 1;
					break;
				}
			}
		}
	}
	if (votes.isEmpty) return null;
	Object? bestId;
	int bestVotes = 0;
	votes.forEach((Object id, int v) {
		if (v > bestVotes) {
			bestVotes = v;
			bestId = id;
		}
	});
	for (final T c in candidates) {
		if (idOf(c) == bestId) return c;
	}
	return null;
}
