import "dart:ui";

import "../../../core/sprites/sprite_manifest.dart";

/// 嵌入拼圖的單一拼片。
///
/// 每片對應一個 [SpriteItem]（去背物件），用「同一張 sheet ui.Image +
/// srcRect」呈現、不需要切割。
///
/// 三組座標 / 尺寸：
/// - [displaySize]：sprite tile 的渲染尺寸（正方形）
/// - [slotRect]：此片在左半 board 上的「正確位置」矩形（與 displaySize 相符；
///   stage 全域座標）— 是底板凹槽的位置
/// - [currentPosition]：片左上角當下在 stage 上的位置；鎖定後等於 slotRect.topLeft
class InsetPiece {
	InsetPiece({
		required this.id,
		required this.item,
		required this.slotRect,
		required this.displaySize,
		required this.currentPosition,
	});

	/// 用來 reference 的 id，採用 [SpriteItem.id]，每局唯一。
	final String id;

	/// 對應的 sprite 物件 metadata（含 sheet index / row / col / 中文名等）。
	final SpriteItem item;

	/// 此片在左半 board 上的「正確位置」矩形（含尺寸；以 stage 座標表示）。
	/// 視窗 / canvas 尺寸變動時由 controller.rescaleStage 整批覆寫。
	Rect slotRect;

	/// 渲染尺寸（與 slotRect 一致）。獨立欄位避免每次取尺寸都 destructure。
	/// 同樣會被 rescaleStage 覆寫。
	Size displaySize;

	/// 目前畫面位置（stage 座標，左上角）。
	Offset currentPosition;

	/// 是否已歸位鎖定。鎖定後不再可拖、painter 直接畫在 slotRect 上。
	bool locked = false;

	/// z-order；越大越上層。每次抓起 +1 提到最高。
	int zIndex = 0;
}
