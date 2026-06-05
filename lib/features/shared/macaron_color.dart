import "dart:math";

import "package:flutter/material.dart";

/// 產生一個馬卡龍色：色相 0~360 隨機、亮度偏高（~0.85）、彩度中等（~0.45）。
///
/// 用 HSL → Color 轉換（不是 HSV，馬卡龍色感覺更接近 HSL high-lightness）。
Color macaronColor(Random random) {
	final double hue = random.nextDouble() * 360.0;
	final double saturation = 0.40 + random.nextDouble() * 0.15; // 0.40 ~ 0.55
	final double lightness = 0.82 + random.nextDouble() * 0.06; // 0.82 ~ 0.88
	return HSLColor.fromAHSL(1.0, hue, saturation, lightness).toColor();
}
