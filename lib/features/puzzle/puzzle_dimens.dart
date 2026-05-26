/// 拼圖單元的尺寸 / 行為 / 動畫常數。
///
/// 集中放在 `features/puzzle/` 下、與其他單元（未來可能新增）的常數隔離；
/// 跨單元共用的尺寸（如家長鎖、首頁齒輪長按）放 [AppDimens]。
class PuzzleDimens {
	PuzzleDimens._();

	// === 塊數範圍 ===

	/// 預設拼圖塊數範圍下限。
	static const int defaultMinPieces = 4;

	/// 預設拼圖塊數範圍上限。
	static const int defaultMaxPieces = 9;

	/// 拼圖塊數允許的絕對下限。
	static const int absoluteMinPieces = 2;

	/// 拼圖塊數允許的絕對上限。
	static const int absoluteMaxPieces = 30;

	// === 切割幾何 ===

	/// 拼圖耳「凸出距離」上限：佔凹入那一片短邊的比例。
	///
	/// 防止大邊 + 小片時，凹入端被挖太深、拼塊看起來幾乎斷裂。
	static const double maxTabProtrusionRatio = 0.30;

	// === Snap / 拖曳 ===

	/// 自動 snap 速度閾值（px/sec）。
	///
	/// 拖曳時若瞬時速度低於此值、且 snap 條件已達成，會自動觸發融合 / 鎖定，
	/// 不必等使用者真的放開手指（幼兒比較缺乏「放開以確認」的概念）。
	/// 越小越「需要拼片幾乎停下來」才會自動 snap。
	static const double autoSnapSpeedThreshold = 30.0;

	/// 拼圖塊吸附 / 鎖定容差公式：tolerance = `((w + h) / 2) ^ exponent × ratio`。
	///
	/// 用「次方」而非線性的尺寸→容差關係：幼兒的精細動作能力在大塊與小塊之間
	/// 的差異不是等比；大塊容差要明顯放寬、小塊維持較緊。
	///
	/// 兩個常數一起調整：
	/// - [snapToleranceExponent]：> 1，越大「大塊更寬鬆、小塊更嚴」分化越明顯
	/// - [snapToleranceRatio]：整體尺度。改 exponent 後通常要重新校準這個值
	///
	/// 當前設定（exp=1.5, ratio=0.02）對應：
	/// - avgSide ≈ 200 px 中等塊 → 約 28 px tolerance
	/// - avgSide ≈ 400 px 大塊  → 約 80 px tolerance
	static const double snapToleranceExponent = 1.5;
	static const double snapToleranceRatio = 0.02;

	// === 繪製 ===

	/// 拼圖塊描邊寬度。
	static const double pieceBorderWidth = 2.0;

	/// 切割線提示寬度。
	static const double cutLineWidth = 1.5;

	// === 旋轉模式 ===

	/// 旋轉模式下、grid 切法的角度 step（度）。所有群組旋轉都會 snap 到此值
	/// 的整數倍。
	static const double rotationStepGridDeg = 90.0;

	/// 旋轉模式下、voronoi 切法的角度 step（度）。
	static const double rotationStepVoronoiDeg = 45.0;

	/// 旋轉手勢增益：兩指夾角變化 × 此值 = 套到群組的角度變化。
	/// 大於 1 讓使用者只要小幅度轉手指就能轉很多。
	static const double rotationGestureGain = 2.0;

	/// 旋轉 snap 動畫時長（毫秒）。第二指還按著時、群組從目前角度緩動到
	/// 最近 step 倍數所花的時間。
	static const int rotationSnapMs = 100;

	/// 旋轉模式下、新 pointer 命中拼片時用來消歧「新拖曳 vs 加入旋轉」的距
	/// 離門檻（px）。
	///
	/// 規則：新 pointer 與所有正在拖曳的「第一指」的距離都超過此門檻才能開
	/// 新拖曳；否則視為「最近第一指」的旋轉第二指。命中空白同理：距離某第
	/// 一指 ≤ 此門檻才會被當成它的旋轉第二指、否則忽略。
	///
	/// 此距離是「自然兩指張開」的概念、與拼片尺寸無關。
	static const double rotationProximityPx = 140.0;
}
