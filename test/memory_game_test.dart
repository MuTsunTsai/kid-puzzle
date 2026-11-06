import "dart:math";
import "dart:ui";

import "package:flutter_test/flutter_test.dart";
import "package:kid_puzzle/features/memory_game/domain/memory_board.dart";
import "package:kid_puzzle/features/memory_game/domain/memory_grid_layout.dart";

/// 找出與 [index] 同組的另一張、以及一張不同組的卡。
({int partner, int other}) _partnerAndOther(MemoryBoard<String> board, int index) {
	final String key = board.cards[index].pairKey;
	int partner = -1;
	int other = -1;
	for (final MemoryCard<String> c in board.cards) {
		if (c.index == index) continue;
		if (c.pairKey == key) {
			partner = c.index;
		} else if (other < 0) {
			other = c.index;
		}
	}
	return (partner: partner, other: other);
}

void main() {
	group("MemoryBoard", () {
		test("每個 key 恰好兩張", () {
			final MemoryBoard<String> board =
					MemoryBoard<String>.shuffled(<String>["a", "b", "c"], Random(1));
			expect(board.cards.length, 6);
			final Map<String, int> counts = <String, int>{};
			for (final MemoryCard<String> c in board.cards) {
				counts[c.pairKey] = (counts[c.pairKey] ?? 0) + 1;
				expect(c.state, MemoryCardState.faceDown);
			}
			expect(counts, <String, int>{"a": 2, "b": 2, "c": 2});
		});

		test("配對成功 → 兩張 matched、盤面不鎖", () {
			final MemoryBoard<String> board =
					MemoryBoard<String>.shuffled(<String>["a", "b"], Random(2));
			final int p = _partnerAndOther(board, 0).partner;
			expect(board.flip(0), isA<FlipFirst>());
			// 同一張再點一次 → 忽略
			expect(board.flip(0), isA<FlipIgnored>());
			final FlipResult r = board.flip(p);
			expect(r, isA<FlipMatch>());
			expect(board.cards[0].state, MemoryCardState.matched);
			expect(board.cards[p].state, MemoryCardState.matched);
			expect(board.isLocked, isFalse);
			// 已配對的卡不能再翻
			expect(board.flip(p), isA<FlipIgnored>());
		});

		test("不符合 → 鎖定直到 hideMismatch", () {
			final MemoryBoard<String> board =
					MemoryBoard<String>.shuffled(<String>["a", "b", "c"], Random(3));
			final ({int partner, int other}) po = _partnerAndOther(board, 0);
			board.flip(0);
			expect(board.flip(po.other), isA<FlipMismatch>());
			expect(board.isLocked, isTrue);
			// 鎖定中翻任何卡都被忽略
			expect(board.flip(po.partner), isA<FlipIgnored>());
			expect(board.cards[po.partner].state, MemoryCardState.faceDown);
			board.hideMismatch();
			expect(board.isLocked, isFalse);
			expect(board.cards[0].state, MemoryCardState.faceDown);
			expect(board.cards[po.other].state, MemoryCardState.faceDown);
		});

		test("全部配對 → isCompleted", () {
			final MemoryBoard<String> board = MemoryBoard<String>.shuffled(
					<String>["a", "b", "c", "d"], Random(4));
			while (!board.isCompleted) {
				final int first = board.cards
						.firstWhere((MemoryCard<String> c) =>
								c.state == MemoryCardState.faceDown)
						.index;
				board.flip(first);
				board.flip(_partnerAndOther(board, first).partner);
			}
			expect(
				board.cards.every(
						(MemoryCard<String> c) => c.state == MemoryCardState.matched),
				isTrue,
			);
		});
	});

	group("MemoryGridLayout", () {
		test("所有卡片在範圍內且互不重疊", () {
			const Rect area = Rect.fromLTWH(84, 20, 800, 380);
			for (int count = 4; count <= 20; count += 2) {
				final MemoryGridLayout layout =
						MemoryGridLayout.compute(area: area, count: count);
				expect(layout.rects.length, count);
				expect(layout.columns * layout.rows, greaterThanOrEqualTo(count));
				for (int i = 0; i < count; i++) {
					final Rect r = layout.rects[i];
					expect(r.left, greaterThanOrEqualTo(area.left - 1e-6));
					expect(r.top, greaterThanOrEqualTo(area.top - 1e-6));
					expect(r.right, lessThanOrEqualTo(area.right + 1e-6));
					expect(r.bottom, lessThanOrEqualTo(area.bottom + 1e-6));
					for (int j = i + 1; j < count; j++) {
						expect(r.overlaps(layout.rects[j]), isFalse,
								reason: "count=$count i=$i j=$j");
					}
				}
			}
		});

		test("橫向畫面偏好較多欄", () {
			final MemoryGridLayout layout = MemoryGridLayout.compute(
				area: const Rect.fromLTWH(0, 0, 900, 400),
				count: 12,
			);
			expect(layout.columns, greaterThan(layout.rows));
		});

		test("maxCardSize 限制卡片大小", () {
			final MemoryGridLayout layout = MemoryGridLayout.compute(
				area: const Rect.fromLTWH(0, 0, 900, 400),
				count: 4,
				maxCardSize: 150,
			);
			expect(layout.cardSize, 150);
		});
	});
}
