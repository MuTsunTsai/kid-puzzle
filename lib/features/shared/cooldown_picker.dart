import "dart:math";

/// 「重複機率遞減」加權隨機抽樣器。
///
/// 對 N 個候選項目維護「上次被抽中的關卡序號」，每次抽樣時：
/// - 計算每個項目 i 的「距離」`d_i = currentLevel - lastShown[i]`，從未抽中
///   過視為 d=∞ → 權重 1
/// - 若 `d_i ≤ cooldown`（預設 `0.4 × N`）權重強制為 0，**保證冷卻期內絕不
///   重複**
/// - 否則權重 = `min(1, d_i / N)`，距離 N 關後達上限 1
///
/// 多片拼圖選圖、嵌入拼圖選類別、選類別內 items 都用這套，行為一致。
///
/// 不持有候選清單，只記錄「id → 上次關卡」+ 內部關卡計數。每個獨立的選取
/// 用一個獨立 instance（例如 _categoryPicker / _itemPicker），id 由呼叫端
/// 決定（int 索引、String id 都可）。
class CooldownPicker<K> {
	CooldownPicker({Random? random}) : _random = random ?? Random();

	final Random _random;
	final Map<K, int> _lastShownLevel = <K, int>{};
	int _levelCounter = 0;

	/// 自冷卻佔總數的比例。預設 0.4 即 puzzle_page 原行為。
	static const double _cooldownRatio = 0.4;

	/// 從 [candidates] 中加權隨機抽一個並記錄。candidates 為空時回 null。
	///
	/// 同一份 candidates 內的 key 不應有重複；若有重複只第一個生效。
	///
	/// [weightMultiplier] 可選：對每個候選的基礎權重再乘上一個倍率（例如把
	/// 已 cache 的關卡權重乘 3、增加抽中機率）。callback 回傳值 <= 0 視同 0、
	/// 會避開該候選；不傳則沿用基礎權重。倍率作用於「冷卻後的距離權重」、
	/// 不會繞過冷卻：冷卻期內的候選即使倍率高仍是 0。
	K? pick(
		Iterable<K> candidates, {
		double Function(K candidate)? weightMultiplier,
	}) {
		final List<K> list = candidates.toList(growable: false);
		final int n = list.length;
		if (n == 0) return null;
		if (n == 1) {
			_lastShownLevel[list[0]] = _levelCounter;
			_levelCounter++;
			return list[0];
		}
		final int cooldown = (n * _cooldownRatio).floor();
		final List<double> weights = List<double>.generate(n, (int i) {
			final K key = list[i];
			final int? last = _lastShownLevel[key];
			double base;
			if (last == null) {
				base = 1.0;
			} else {
				final int distance = _levelCounter - last;
				if (distance <= cooldown) {
					return 0.0;
				}
				base = distance / n;
				if (base > 1.0) base = 1.0;
			}
			if (weightMultiplier != null) {
				final double m = weightMultiplier(key);
				if (m <= 0) return 0.0;
				return base * m;
			}
			return base;
		});
		double total = 0;
		for (final double w in weights) {
			total += w;
		}
		final K picked;
		if (total <= 0) {
			// 極端保險：所有權重 0（理論上 cooldown < n 時不可能）→ 均勻抽
			picked = list[_random.nextInt(n)];
		} else {
			final double r = _random.nextDouble() * total;
			double acc = 0;
			K? hit;
			for (int i = 0; i < n; i++) {
				acc += weights[i];
				if (r < acc) {
					hit = list[i];
					break;
				}
			}
			picked = hit ?? list[n - 1];
		}
		_lastShownLevel[picked] = _levelCounter;
		_levelCounter++;
		return picked;
	}

	/// [pickMany] 的高階版本：抽到候選時呼叫 [accept(candidate, alreadyChosen)]
	/// 判斷是否接受。reject 的候選**不**進入結果、**不**佔該關 lastShown
	/// 紀錄（視同沒被抽到、下回合不進冷卻）、且本輪不會再被選到（避免無窮
	/// 迴圈）。
	///
	/// 用途：嵌入拼圖選 item 時排除「輪廓與已選太接近」的物件 — 抽到太像
	/// 已選的就丟棄、改抽其他。
	///
	/// 若候選池在某輪所有非冷卻候選都被 reject、本實作會降級成「均勻抽
	/// 一個非 taken 候選」(視同 pickMany 的 total<=0 fallback)、避免極端
	/// 情況下湊不到 count 個。
	List<K> pickManyWhere(
		Iterable<K> candidates,
		int count,
		bool Function(K candidate, List<K> alreadyChosen) accept,
	) {
		final List<K> list = candidates.toList();
		final int n = list.length;
		if (n == 0 || count <= 0) return <K>[];
		final int k = count > n ? n : count;
		final int cooldown = (n * _cooldownRatio).floor();
		final List<K> result = <K>[];
		final Set<K> taken = <K>{};   // 已接受（會記錄到 lastShown）
		final Set<K> rejected = <K>{}; // 本輪 reject、之後不再抽
		while (result.length < k && taken.length + rejected.length < n) {
			final List<int> idx = <int>[];
			final List<double> weights = <double>[];
			for (int i = 0; i < n; i++) {
				final K key = list[i];
				if (taken.contains(key) || rejected.contains(key)) continue;
				final int? last = _lastShownLevel[key];
				double w;
				if (last == null) {
					w = 1.0;
				} else {
					final int distance = _levelCounter - last;
					if (distance <= cooldown) {
						w = 0.0;
					} else {
						w = distance / n;
						if (w > 1.0) w = 1.0;
					}
				}
				idx.add(i);
				weights.add(w);
			}
			if (idx.isEmpty) break;
			double total = 0;
			for (final double w in weights) {
				total += w;
			}
			final int chosen;
			if (total <= 0) {
				chosen = idx[_random.nextInt(idx.length)];
			} else {
				final double r = _random.nextDouble() * total;
				double acc = 0;
				int hit = idx.last;
				for (int j = 0; j < idx.length; j++) {
					acc += weights[j];
					if (r < acc) {
						hit = idx[j];
						break;
					}
				}
				chosen = hit;
			}
			final K candidate = list[chosen];
			if (accept(candidate, result)) {
				taken.add(candidate);
				result.add(candidate);
			} else {
				rejected.add(candidate);
			}
		}
		// 只把接受的記錄為「同一關」、下一次 pick* 才前進。
		for (final K key in result) {
			_lastShownLevel[key] = _levelCounter;
		}
		_levelCounter++;
		return result;
	}

	/// 從 [candidates] 中**不重複地**抽 [count] 個並記錄；count > candidates
	/// 長度時只回 candidates 長度個。每次抽樣都會更新 lastShown，但內部關卡
	/// 計數只前進一次 — 同一關內被一起抽中的 items 視為同一輪、冷卻起算點
	/// 相同。
	List<K> pickMany(Iterable<K> candidates, int count) {
		final List<K> list = candidates.toList();
		final int n = list.length;
		if (n == 0 || count <= 0) return <K>[];
		final int k = count > n ? n : count;
		final int cooldown = (n * _cooldownRatio).floor();
		final List<K> result = <K>[];
		// 同一輪內已抽中的不再進候選，但其它候選的權重仍以「進入本輪前」的
		// lastShown 為基準計算 — 避免單一輪內後抽的權重被同輪先抽影響。
		final Set<K> taken = <K>{};
		for (int round = 0; round < k; round++) {
			final List<int> idx = <int>[];
			final List<double> weights = <double>[];
			for (int i = 0; i < n; i++) {
				if (taken.contains(list[i])) continue;
				final int? last = _lastShownLevel[list[i]];
				double w;
				if (last == null) {
					w = 1.0;
				} else {
					final int distance = _levelCounter - last;
					if (distance <= cooldown) {
						w = 0.0;
					} else {
						w = distance / n;
						if (w > 1.0) w = 1.0;
					}
				}
				idx.add(i);
				weights.add(w);
			}
			if (idx.isEmpty) break;
			double total = 0;
			for (final double w in weights) {
				total += w;
			}
			final int chosen;
			if (total <= 0) {
				chosen = idx[_random.nextInt(idx.length)];
			} else {
				final double r = _random.nextDouble() * total;
				double acc = 0;
				int hit = idx.last;
				for (int j = 0; j < idx.length; j++) {
					acc += weights[j];
					if (r < acc) {
						hit = idx[j];
						break;
					}
				}
				chosen = hit;
			}
			taken.add(list[chosen]);
			result.add(list[chosen]);
		}
		// 全部一起記錄為「同一關」，下一次 pick / pickMany 才前進。
		for (final K key in result) {
			_lastShownLevel[key] = _levelCounter;
		}
		_levelCounter++;
		return result;
	}
}
