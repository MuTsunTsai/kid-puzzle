import "dart:ui";

/// 記憶遊戲卡片排版結果：每張卡的矩形（與卡片 index 一一對應）。
class MemoryGridLayout {
	const MemoryGridLayout({
		required this.columns,
		required this.rows,
		required this.cardSize,
		required this.rects,
	});

	final int columns;
	final int rows;

	/// 正方形卡片邊長。
	final double cardSize;

	final List<Rect> rects;

	/// 在 [area] 內排 [count] 張正方形卡片，挑「卡片最大」的 columns × rows。
	///
	/// - 卡間距 = 卡片邊長 × [gapRatio]
	/// - 卡片最大相同時，偏好空格較少的組合（最後一列不滿的情況少）
	/// - 最後一列不滿時水平置中；整體在 [area] 內置中
	/// - [maxCardSize] 限制卡片上限（張數少時避免卡片大到誇張）
	static MemoryGridLayout compute({
		required Rect area,
		required int count,
		double gapRatio = 0.12,
		double? maxCardSize,
	}) {
		if (count <= 0 || area.width <= 0 || area.height <= 0) {
			return const MemoryGridLayout(
				columns: 0,
				rows: 0,
				cardSize: 0,
				rects: <Rect>[],
			);
		}
		int bestCols = 1;
		int bestRows = count;
		double bestSize = -1;
		int bestEmpty = 1 << 30;
		for (int cols = 1; cols <= count; cols++) {
			final int rows = (count + cols - 1) ~/ cols;
			// cols 張卡 + (cols-1) 個間距 = s × (cols + (cols-1) × gapRatio)
			final double sw = area.width / (cols + (cols - 1) * gapRatio);
			final double sh = area.height / (rows + (rows - 1) * gapRatio);
			final double s = sw < sh ? sw : sh;
			final int empty = cols * rows - count;
			// 尺寸差 < 0.5px 視為相同、改比空格數
			final bool better = s > bestSize + 0.5 ||
					((s - bestSize).abs() <= 0.5 && empty < bestEmpty);
			if (better) {
				bestCols = cols;
				bestRows = rows;
				bestSize = s;
				bestEmpty = empty;
			}
		}
		double size = bestSize;
		if (maxCardSize != null && size > maxCardSize) size = maxCardSize;
		final double gap = size * gapRatio;
		final double totalH = bestRows * size + (bestRows - 1) * gap;
		final double top = area.top + (area.height - totalH) / 2;
		final List<Rect> rects = <Rect>[];
		for (int i = 0; i < count; i++) {
			final int row = i ~/ bestCols;
			final int col = i % bestCols;
			final int inRow = row == bestRows - 1
					? count - row * bestCols
					: bestCols;
			final double rowW = inRow * size + (inRow - 1) * gap;
			final double left = area.left + (area.width - rowW) / 2;
			rects.add(Rect.fromLTWH(
				left + col * (size + gap),
				top + row * (size + gap),
				size,
				size,
			));
		}
		return MemoryGridLayout(
			columns: bestCols,
			rows: bestRows,
			cardSize: size,
			rects: rects,
		);
	}
}
