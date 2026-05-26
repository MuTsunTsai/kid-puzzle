import "dart:ui";

import "puzzle_piece.dart";

/// 一場拼圖遊戲所需的完整切割布局。
///
/// 由 puzzle_cutter 從 [GridLayoutSpec] 與圖片尺寸建構。
class PuzzleLayout {
	const PuzzleLayout({
		required this.pieceCount,
		required this.boardSize,
		required this.boardPadding,
		required this.pieces,
		required this.tabSize,
	});

	/// 總拼圖塊數（4~10）。
	final int pieceCount;

	/// 拼圖盤的總尺寸（含外圈 padding）。
	final Size boardSize;

	/// 外圈 padding（左右上下相同）。實際切割發生在內部矩形。
	final double boardPadding;

	/// 所有拼圖塊。索引即 piece.id。
	final List<PuzzlePiece> pieces;

	/// 凸耳尺寸（相鄰邊長度 * tabSizeRatio）。
	///
	/// 因為 5/7 不規則切法中不同 cell 的寬高可能不同，此值代表
	/// 「整體性」的耳尺寸（取最短邊乘上比例）；個別邊可在 puzzle_cutter
	/// 內依該邊實際長度計算更精細的值。
	final double tabSize;

	/// 拼圖盤內可切割區域的左上角座標。
	Offset get innerOrigin => Offset(boardPadding, boardPadding);

	/// 拼圖盤內可切割區域的尺寸。
	Size get innerSize => Size(
		boardSize.width - 2 * boardPadding,
		boardSize.height - 2 * boardPadding,
	);

	@override
	String toString() {
		return "PuzzleLayout(count=$pieceCount, board=$boardSize, "
				"padding=$boardPadding, pieces=${pieces.length})";
	}
}
