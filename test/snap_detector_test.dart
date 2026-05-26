import "dart:ui";

import "package:flutter_test/flutter_test.dart";
import "package:kid_puzzle/features/puzzle/domain/models/puzzle_layout.dart";
import "package:kid_puzzle/features/puzzle/domain/models/puzzle_piece.dart";
import "package:kid_puzzle/features/puzzle/domain/services/cell_planner.dart";
import "package:kid_puzzle/features/puzzle/domain/services/puzzle_cutter.dart";
import "package:kid_puzzle/features/puzzle/domain/services/snap_detector.dart";

const Size kBoardSize = Size(800, 600);
const double kPadding = 24;
const Offset kBoardOrigin = Offset(100, 50);
final Rect kInnerBounds = Rect.fromLTWH(
	kPadding,
	kPadding,
	kBoardSize.width - 2 * kPadding,
	kBoardSize.height - 2 * kPadding,
);

PuzzleLayout _makeLayout({int pieceCount = 4, int seed = 7}) {
	final CellLayout cellLayout = const GridCellPlanner().plan(
		pieceCount: pieceCount,
		innerBounds: kInnerBounds,
		seed: seed,
	);
	return PuzzleCutter.cut(
		boardSize: kBoardSize,
		boardPadding: kPadding,
		cellLayout: cellLayout,
		seed: seed,
	);
}

/// 把所有 piece 放到「散得很遠」的初始狀態，並重新指定群組各自獨立。
void _scatter(PuzzleLayout layout) {
	double x = 1000;
	for (final PuzzlePiece p in layout.pieces) {
		p.currentPosition = Offset(x, 800);
		p.groupId = p.id;
		p.locked = false;
		x += 200;
	}
}

void main() {
	group("SnapDetector", () {
		test("兩片相對位置正確時應融合", () {
			final PuzzleLayout layout = _makeLayout();
			_scatter(layout);

			final PuzzlePiece a = layout.pieces[0];
			final PuzzlePiece b = layout.pieces[1];

			// 故意把 b 放到「相對 a 正確相對位置 + (5, -3) 微誤差」的位置（< tolerance）
			a.currentPosition = const Offset(500, 500);
			b.currentPosition = a.currentPosition +
					(b.correctPositionLocal - a.correctPositionLocal) +
					const Offset(5, -3);

			final SnapResult result = SnapDetector.resolve(
				layout: layout,
				draggingGroupId: a.groupId,
				boardOrigin: kBoardOrigin,
			);

			expect(result.merged, isTrue);
			expect(a.groupId, b.groupId, reason: "兩片融合後 groupId 應一致");

			// 融合後 b 應該被平移到「相對 a 完全正確」的位置
			final Offset expectedB = a.currentPosition +
					(b.correctPositionLocal - a.correctPositionLocal);
			expect((b.currentPosition - expectedB).distance, lessThan(1e-6));
		});

		test("相對位置誤差大於容差時不融合", () {
			final PuzzleLayout layout = _makeLayout();
			_scatter(layout);

			final PuzzlePiece a = layout.pieces[0];
			final PuzzlePiece b = layout.pieces[1];

			a.currentPosition = const Offset(500, 500);
			// 故意製造 > tolerance 的誤差（容差用 (avgSide)^1.5 × ratio，
			// 對 800×600 / 4 塊大約是 ~117 px，所以 200 px 一定超出）
			b.currentPosition = a.currentPosition +
					(b.correctPositionLocal - a.correctPositionLocal) +
					const Offset(200, 0);

			final SnapResult result = SnapDetector.resolve(
				layout: layout,
				draggingGroupId: a.groupId,
				boardOrigin: kBoardOrigin,
			);

			expect(result.merged, isFalse);
			expect(a.groupId == b.groupId, isFalse);
		});

		test("放在正確位置（vs board）時整群鎖定", () {
			final PuzzleLayout layout = _makeLayout();
			_scatter(layout);

			final PuzzlePiece a = layout.pieces[0];
			// 故意把 a 放在「正確位置 + (3, 4)」誤差（< tolerance）
			a.currentPosition = a.correctPositionLocal + kBoardOrigin + const Offset(3, 4);

			final SnapResult result = SnapDetector.resolve(
				layout: layout,
				draggingGroupId: a.groupId,
				boardOrigin: kBoardOrigin,
			);

			expect(result.locked, isTrue);
			expect(a.locked, isTrue);
			expect(
				(a.currentPosition - (a.correctPositionLocal + kBoardOrigin)).distance,
				lessThan(1e-6),
			);
		});

		test("融合與鎖定條件同時滿足時、只觸發融合（拼片 snap 優先）", () {
			final PuzzleLayout layout = _makeLayout();
			_scatter(layout);

			final PuzzlePiece a = layout.pieces[0];
			final PuzzlePiece b = layout.pieces[1];

			// 把 a 放在「接近正確位置」，把 b 放在「接近與 a 正確相對位置」
			a.currentPosition = a.correctPositionLocal + kBoardOrigin + const Offset(2, 2);
			b.currentPosition = a.currentPosition +
					(b.correctPositionLocal - a.correctPositionLocal) +
					const Offset(-3, 1);

			final SnapResult result = SnapDetector.resolve(
				layout: layout,
				draggingGroupId: a.groupId,
				boardOrigin: kBoardOrigin,
			);

			// 同次 resolve 只觸發一次 snap：融合優先、且不會在同一次裡再做鎖定。
			expect(result.merged, isTrue);
			expect(result.locked, isFalse);
			expect(a.locked, isFalse);
			expect(b.locked, isFalse);
			// 融合後 a、b 應已在同一群、且相對位置已對齊。
			expect(a.groupId, equals(b.groupId));

			// 第二次 resolve（模擬「使用者再次拖曳結束」）才會觸發鎖定。
			final SnapResult result2 = SnapDetector.resolve(
				layout: layout,
				draggingGroupId: a.groupId,
				boardOrigin: kBoardOrigin,
			);
			expect(result2.locked, isTrue);
			expect(a.locked, isTrue);
			expect(b.locked, isTrue);
		});

		test("已 locked 的 piece 不會被當作合併對象", () {
			final PuzzleLayout layout = _makeLayout();
			_scatter(layout);

			final PuzzlePiece a = layout.pieces[0];
			final PuzzlePiece b = layout.pieces[1];

			// b 已鎖定且在正確位置
			b.locked = true;
			b.currentPosition = b.correctPositionLocal + kBoardOrigin;

			// a 拖到「相對 b 正確相對位置 + 微誤差」
			a.currentPosition = b.currentPosition +
					(a.correctPositionLocal - b.correctPositionLocal) +
					const Offset(5, 5);

			final SnapResult result = SnapDetector.resolve(
				layout: layout,
				draggingGroupId: a.groupId,
				boardOrigin: kBoardOrigin,
			);

			// 不應與已鎖定的 b 融合
			expect(result.merged, isFalse);
			// 但因為 a 此時也接近自己的正確位置，所以會直接鎖定
			expect(result.locked, isTrue);
		});

		test("不相鄰的兩片即使相對位置正確也不會融合", () {
			// 4 塊 2x2：piece 0 = 左上, piece 3 = 右下，這兩片不共享邊（對角）。
			// 把 piece 3 放到「相對 piece 0 的正確相對位置」，融合應該不觸發。
			final PuzzleLayout layout = _makeLayout(pieceCount: 4, seed: 0);
			_scatter(layout);

			final PuzzlePiece a = layout.pieces[0];
			// 找一片與 a 不相鄰的 piece
			final PuzzlePiece nonNeighbor = layout.pieces.firstWhere(
				(PuzzlePiece p) =>
						p.id != a.id && !a.neighborIds.contains(p.id) && !p.locked,
			);

			a.currentPosition = const Offset(500, 500);
			// 故意精準擺在相對位置正確的點
			nonNeighbor.currentPosition = a.currentPosition +
					(nonNeighbor.correctPositionLocal - a.correctPositionLocal);

			final SnapResult result = SnapDetector.resolve(
				layout: layout,
				draggingGroupId: a.groupId,
				boardOrigin: kBoardOrigin,
			);

			expect(result.merged, isFalse,
					reason: "不相鄰拼塊不該融合（即使相對位置精準對齊）");
			expect(a.groupId == nonNeighbor.groupId, isFalse);
		});

		test("共享邊無耳朵的鄰居不會融合", () {
			// 模擬「相鄰但共享邊是 flat / forceFlat」的情境：
			// 直接從拼塊的 tabNeighborIds 移掉對方。
			final PuzzleLayout layout = _makeLayout();
			_scatter(layout);

			final PuzzlePiece a = layout.pieces[0];
			final PuzzlePiece b = layout.pieces[1];

			// 確保 a 仍是 b 的鄰居（neighborIds），但「無耳朵鄰居」表中沒有彼此。
			a.tabNeighborIds.remove(b.id);
			b.tabNeighborIds.remove(a.id);

			// 故意把 b 放到「相對 a 完全正確」的位置
			a.currentPosition = const Offset(500, 500);
			b.currentPosition = a.currentPosition +
					(b.correctPositionLocal - a.correctPositionLocal);

			final SnapResult result = SnapDetector.resolve(
				layout: layout,
				draggingGroupId: a.groupId,
				boardOrigin: kBoardOrigin,
			);

			expect(result.merged, isFalse,
					reason: "共享邊沒有耳朵的鄰居不該融合，即使相對位置精準對齊");
			expect(a.groupId == b.groupId, isFalse);
		});

		test("合併取較小的 groupId", () {
			final PuzzleLayout layout = _makeLayout();
			_scatter(layout);

			final PuzzlePiece a = layout.pieces[0];
			final PuzzlePiece b = layout.pieces[1];

			a.currentPosition = const Offset(500, 500);
			b.currentPosition = a.currentPosition +
					(b.correctPositionLocal - a.correctPositionLocal);

			final int smaller = a.groupId < b.groupId ? a.groupId : b.groupId;
			SnapDetector.resolve(
				layout: layout,
				draggingGroupId: a.groupId,
				boardOrigin: kBoardOrigin,
			);
			expect(a.groupId, smaller);
			expect(b.groupId, smaller);
		});
	});
}
