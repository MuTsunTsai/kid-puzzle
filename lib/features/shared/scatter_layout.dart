import "dart:math";
import "dart:ui";

import "../puzzle/domain/services/voronoi.dart";

/// 在 [bounds] 內為 N 個物件計算「均勻分散」的中心位置，給散落區用。
///
/// 用 [VoronoiBuilder.generatePoissonLikePoints]（隨機 + Lloyd 鬆弛）產生
/// 分散點，比純 random 在小數量時看起來更自然、不會擠在一起。
///
/// 回傳中心位置陣列，**不**做「avoid clamp 到 bounds 內」這層處理 — 因為
/// 不同遊戲模式可能有不同 piece 尺寸 / 邊界規則（例如多片拼圖每片大小不同、
/// 嵌入拼圖統一 tile）。呼叫端自行 clamp。
Future<List<Offset>> computeScatterCenters({
	required Rect bounds,
	required int count,
	required Random random,
	int lloydIterations = 3,
}) async {
	if (count <= 0) return const <Offset>[];
	return VoronoiBuilder.generatePoissonLikePoints(
		bounds: bounds,
		count: count,
		random: random,
		lloydIterations: lloydIterations,
	);
}
