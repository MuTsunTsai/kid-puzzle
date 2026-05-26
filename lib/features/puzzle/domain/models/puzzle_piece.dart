import "dart:ui";

import "puzzle_edge.dart";

/// 一塊拼圖。
///
/// **不可變欄位**：[id]、[gridCellId]、[polygonAabb]、[sourceRect]、[edges]、[localPath]。
/// 由 puzzle_cutter 建構時填好，後續絕不更動。
///
/// **可變欄位**：[currentPosition]、[groupId]、[locked]、[zIndex]。
/// 由 PuzzleController 在遊戲過程中更新。
class PuzzlePiece {
	PuzzlePiece({
		required this.id,
		required this.gridCellId,
		required this.polygonAabb,
		required this.sourceRect,
		required this.edges,
		required this.neighborIds,
		required this.tabNeighborIds,
		required this.localPath,
		required this.currentPosition,
		required this.groupId,
		this.locked = false,
		this.zIndex = 0,
	});

	/// 拼圖塊的識別碼（0 起算，唯一）。
	final int id;

	/// 在 cell planner 輸出的 cells 中的索引。
	final int gridCellId;

	/// piece 多邊形「不含 tab」的 AABB（在拼圖盤座標系）。
	///
	/// 對 grid 模式：即原本的 coreRect（cell 矩形）。
	/// 對 voronoi 模式：cell polygon 的軸對齊外接矩形。
	/// 用於計算「正確位置」與「相鄰塊正確相對位移」。
	final Rect polygonAabb;

	/// 含 tab 凸出的實際像素區域（在拼圖盤座標系）。
	///
	/// 用於 Canvas.drawImageRect 的 src 參數。
	final Rect sourceRect;

	/// piece 多邊形每條邊的描述。
	///
	/// 索引 i 的邊連接 polygon 頂點 i → 頂點 (i+1) % n。
	/// edges 長度 = polygon 頂點數。
	final List<PuzzleEdge> edges;

	/// 此 piece 在 layout 中的「鄰居 piece id 集合」（共享至少一條邊的其他 cell）。
	///
	/// 由 [PuzzleCutter] 在切割時計算。
	final Set<int> neighborIds;

	/// [neighborIds] 之中、共享邊「實際有耳朵」（既不是 flat，也不是 forceFlat）
	/// 的鄰居子集合。
	///
	/// snap_detector 用此判斷融合是否合法：只允許共享「有耳朵」邊的拼塊融合，
	/// 因為純直線邊的拼塊融合在視覺上無法被卡住、容易發生意外吸附。
	final Set<int> tabNeighborIds;

	/// 拼圖塊形狀的封閉 Path。
	///
	/// **以 sourceRect.topLeft 為原點 (0, 0) 的局部座標系**。
	/// 命中測試與繪製時，依 [currentPosition] 平移後使用。
	final Path localPath;

	/// 拼圖塊目前左上角在畫布的位置（sourceRect.topLeft 對應的點）。
	Offset currentPosition;

	/// 進關卡飛散動畫的起點（一般為「拼圖盤上的正確位置」）。
	///
	/// 由 [PuzzleController.scatterPiecesToRight] 設定；painter 在 introProgress
	/// < 1 時用 [Offset.lerp] 把 piece 從這裡飛到 [currentPosition]。null 表示
	/// 不做飛散（例如鎖定後、或關閉動畫）。
	Offset? introStartPosition;

	/// 所屬群組 ID（初始時等於 piece id；融合後群組成員共用）。
	int groupId;

	/// 是否已鎖在左側正確位置（不可再拖）。
	bool locked;

	/// 繪製 z-order（大者繪製在上）。
	int zIndex;

	/// 在拼圖盤局部座標系中的「正確位置」（即 sourceRect 左上角應對齊的點）。
	///
	/// 等同 sourceRect.topLeft；獨立屬性以便閱讀。
	/// 注意：要與 currentPosition 比較時，呼叫端需先把它轉成 stage-global
	/// （加上 stageLayout.boardOrigin）。
	Offset get correctPositionLocal => sourceRect.topLeft;

	@override
	String toString() {
		return "PuzzlePiece(id=$id, gridCell=$gridCellId, group=$groupId, "
				"locked=$locked, currentPosition=$currentPosition)";
	}
}
