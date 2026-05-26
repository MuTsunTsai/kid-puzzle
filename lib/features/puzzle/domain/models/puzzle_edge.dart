/// 拼圖塊的一條邊。
///
/// 一塊拼圖有 N 條邊（N = polygon 頂點數，4=方形、5=五邊形…），每條邊有形狀類型：
/// - [EdgeType.flat] 直線（外圈邊）
/// - [EdgeType.tabOut] 凸出（耳朵突出去）
/// - [EdgeType.tabIn] 凹入（耳朵凹進來）
///
/// 兩片相鄰拼圖共用同一條邊資料，但類型必須互補：
/// 一片是 tabOut 則另一片必為 tabIn，反之亦然。
library;

/// 邊的形狀類型。
enum EdgeType {
	flat,
	tabOut,
	tabIn,
}

/// 一條邊的描述：類型 + 種子（用於曲線細節變化）。
///
/// 同一條共用邊的 [seed] 相同；類型在兩側互補。
class PuzzleEdge {
	const PuzzleEdge({
		required this.type,
		required this.seed,
	});

	final EdgeType type;
	final int seed;

	/// 回傳互補類型：tabOut <-> tabIn，flat 保持 flat。
	EdgeType get complement {
		switch (type) {
			case EdgeType.flat:
				return EdgeType.flat;
			case EdgeType.tabOut:
				return EdgeType.tabIn;
			case EdgeType.tabIn:
				return EdgeType.tabOut;
		}
	}

	@override
	String toString() => "PuzzleEdge($type, seed=$seed)";
}
