import "cooldown_picker.dart";

/// 「Cache-aware 關卡抽樣」共用包裝（多片拼圖、嵌入拼圖、未來新遊戲模式都用）。
///
/// 為什麼存在：所有遊戲模式都遵守同一條 web 載入加速策略 —
/// - **第一關只從 cached 抽**（全沒 cache 才退回全集）：避免進關卡的第一幀
///   就要等網路 fetch
/// - **之後關卡**：已 cache 的候選權重 × [defaultCachedWeightBoost]（3 倍）；
///   全 cache 時等同無偏好
///
/// 各遊戲模式間「身份」不同（多片拼圖：圖 token / index；嵌入拼圖：sprite
/// category id），只要呼叫端提供 `isCached(K)` callback 就能共用整套邏輯。
///
/// 非 web 平台：`isCached` 預期一律回 true（沒有「未下載」狀態）、自動退化
/// 為純 CooldownPicker 行為。
class CacheAwarePicker {
	const CacheAwarePicker._();

	/// 「已 cache 候選」在第二關起的權重倍率。所有遊戲模式共用同一值、UX 一致。
	static const double defaultCachedWeightBoost = 3.0;

	/// 用 [picker] 從 [candidates] 中抽一個。
	///
	/// - [firstLevel] = true → 候選池只保留 `isCached` 為 true 的；全沒 cache
	///   時退回全集（首裝且 SW cache 全空的情境）
	/// - [firstLevel] = false → cached 候選 × [cachedWeightBoost]、其餘 ×1
	///
	/// 回傳被選中的 K（同時更新 picker 內部 lastShown / level counter）；
	/// 候選池為空時回 null（與 picker.pick 一致）。
	static K? pick<K>({
		required CooldownPicker<K> picker,
		required Iterable<K> candidates,
		required bool Function(K candidate) isCached,
		required bool firstLevel,
		double cachedWeightBoost = defaultCachedWeightBoost,
	}) {
		if (firstLevel) {
			final List<K> all = candidates.toList(growable: false);
			final List<K> cached = <K>[
				for (final K k in all)
					if (isCached(k)) k,
			];
			return picker.pick(cached.isNotEmpty ? cached : all);
		}
		return picker.pick(
			candidates,
			weightMultiplier: (K k) =>
					isCached(k) ? cachedWeightBoost : 1.0,
		);
	}
}
