import "dart:ui";

/// 「右上角 X 按鈕」是否該因為內容物太靠近而隱藏的共用判定。
///
/// X 按鈕（[LongPressProgressButton] size=96 + `Positioned(top:12, right:12)`）
/// 在 stage 座標系是一個半徑 [buttonRadius]、圓心在 `(screen.width - 60, 60)`
/// 的圓。判定流程：
/// 1. 在圓內以 [sampleStep] 為間距均勻取樣若干點
/// 2. 對每個樣本呼叫 [hitTest]，任一回 true 即視為「重疊」要隱藏
///
/// 用「採樣 + 任意形狀 hitTest」是為了在拼片很小、形狀不規則時也正確判斷
/// 「實際多邊形與按鈕重疊」而非僅 AABB 粗略比較。
///
/// 呼叫端只負責提供一個能對任意 stage-global 點答「是否命中『會擋按鈕』的
/// 內容物」的 callback；判定本身不知道內容物是拼圖塊還是 sprite。
bool shouldHideCloseButton({
	required Size screenSize,
	required bool Function(Offset point) hitTest,
	double buttonRadius = 48,
	double sampleStep = 8,
}) {
	final Offset center = Offset(screenSize.width - 60, 60);
	final double r2 = buttonRadius * buttonRadius;
	for (double dy = -buttonRadius; dy <= buttonRadius; dy += sampleStep) {
		for (double dx = -buttonRadius; dx <= buttonRadius; dx += sampleStep) {
			if (dx * dx + dy * dy > r2) continue;
			if (hitTest(center + Offset(dx, dy))) return true;
		}
	}
	return false;
}
