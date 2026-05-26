import "package:flutter/material.dart";

/// 全 App 共用色票。
class AppColors {
	// 私有建構子，禁止實體化
	AppColors._();

	/// 主色：明亮天藍，給小朋友親切感
	static const Color primary = Color(0xFF4FC3F7);

	/// 強調色：橘黃，用於按鈕高亮、慶祝動畫
	static const Color accent = Color(0xFFFFB74D);

	/// 拼圖盤背景（淡米色）
	static const Color boardBackground = Color(0xFFFFF8E1);

	/// 拼圖塊散落區的背景（淡綠）
	static const Color pieceArea = Color(0xFFE8F5E9);

	/// 拼圖塊外圍描邊
	static const Color pieceBorder = Color(0xFF424242);

	/// 切割線提示（虛線）顏色
	static const Color cutLineHint = Color(0x66424242);

	/// 過關慶祝背景遮罩
	static const Color celebrationMask = Color(0x80000000);
}
