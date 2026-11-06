import "dart:math";

/// 單張卡片的狀態。
enum MemoryCardState {
	/// 背面朝上、可以翻。
	faceDown,

	/// 正面朝上（第一張、或翻了兩張正在等待判定 / 翻回）。
	faceUp,

	/// 已配對成功（正在播消失特效、或已消失）；不再接受點擊。
	matched,
}

/// 單張卡片。[pairKey] 相同的兩張為一組。
class MemoryCard<K> {
	MemoryCard({required this.index, required this.pairKey});

	/// 在盤面上的位置索引（0 ~ 2N-1），也是 layout slot 的索引。
	final int index;

	/// 配對依據（例如 sprite item id）。
	final K pairKey;

	MemoryCardState state = MemoryCardState.faceDown;
}

/// [MemoryBoard.flip] 的結果。
sealed class FlipResult {
	const FlipResult();
}

/// 點擊被忽略：卡片非背面、或正在等待不符合的兩張翻回。
class FlipIgnored extends FlipResult {
	const FlipIgnored();
}

/// 翻開第一張。
class FlipFirst extends FlipResult {
	const FlipFirst(this.index);
	final int index;
}

/// 翻開第二張且配對成功；兩張都已標成 [MemoryCardState.matched]。
class FlipMatch extends FlipResult {
	const FlipMatch(this.first, this.second);
	final int first;
	final int second;
}

/// 翻開第二張但不符合；盤面進入鎖定、直到呼叫 [MemoryBoard.hideMismatch]。
class FlipMismatch extends FlipResult {
	const FlipMismatch(this.first, this.second);
	final int first;
	final int second;
}

/// 記憶遊戲盤面狀態機（不含任何 UI / 計時）。
///
/// 規則：
/// - 一次最多兩張正面朝上的未配對卡
/// - 第二張與第一張 [MemoryCard.pairKey] 相同 → 兩張 matched
/// - 不同 → 鎖定盤面（之後的 flip 一律 [FlipIgnored]），由呼叫端在停頓後
///   呼叫 [hideMismatch] 翻回並解鎖
/// - 配對成功不鎖盤面：消失特效播放期間仍可繼續翻其他卡
class MemoryBoard<K> {
	MemoryBoard._(this.cards);

	/// 用 [pairKeys]（每個 key 一組）建立 2N 張卡、以 [random] 洗牌。
	factory MemoryBoard.shuffled(List<K> pairKeys, Random random) {
		final List<K> keys = <K>[...pairKeys, ...pairKeys]..shuffle(random);
		return MemoryBoard<K>._(<MemoryCard<K>>[
			for (int i = 0; i < keys.length; i++)
				MemoryCard<K>(index: i, pairKey: keys[i]),
		]);
	}

	final List<MemoryCard<K>> cards;

	/// 目前翻開、尚未判定的第一張（null = 沒有）。
	int? _firstIndex;

	/// 不符合的兩張（等待翻回）；非 null 時盤面鎖定。
	(int, int)? _pendingMismatch;

	bool get isLocked => _pendingMismatch != null;

	/// 全部卡片都已配對。
	bool get isCompleted =>
			cards.every((MemoryCard<K> c) => c.state == MemoryCardState.matched);

	FlipResult flip(int index) {
		if (index < 0 || index >= cards.length) return const FlipIgnored();
		if (isLocked) return const FlipIgnored();
		final MemoryCard<K> card = cards[index];
		if (card.state != MemoryCardState.faceDown) return const FlipIgnored();
		card.state = MemoryCardState.faceUp;
		final int? first = _firstIndex;
		if (first == null) {
			_firstIndex = index;
			return FlipFirst(index);
		}
		_firstIndex = null;
		final MemoryCard<K> firstCard = cards[first];
		if (firstCard.pairKey == card.pairKey) {
			firstCard.state = MemoryCardState.matched;
			card.state = MemoryCardState.matched;
			return FlipMatch(first, index);
		}
		_pendingMismatch = (first, index);
		return FlipMismatch(first, index);
	}

	/// 把等待中的不符合兩張翻回背面並解鎖。沒有等待中的配對時 no-op。
	void hideMismatch() {
		final (int, int)? pending = _pendingMismatch;
		if (pending == null) return;
		cards[pending.$1].state = MemoryCardState.faceDown;
		cards[pending.$2].state = MemoryCardState.faceDown;
		_pendingMismatch = null;
	}
}
