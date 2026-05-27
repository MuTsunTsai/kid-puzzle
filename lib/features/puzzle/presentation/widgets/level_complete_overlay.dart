import "package:flutter/material.dart";
import "package:flutter_animate/flutter_animate.dart";

import "../../../../core/constants/ui_strings.dart";

/// 過關慶祝 overlay：在指定區域內顯示半透明遮罩 + 文字提示，點該區域進下一關。
///
/// 為了讓小朋友能看到左邊拼好的完整圖，遮罩與互動範圍**只覆蓋右半的散落區**，
/// 左側拼圖盤保持可見且不接收點擊。
///
/// 動畫：backdrop fade-in + 文字卡 scale-in（elasticOut）+ 主文字 shimmer。
class LevelCompleteOverlay extends StatelessWidget {
	const LevelCompleteOverlay({
		super.key,
		required this.region,
		required this.onContinue,
	});

	/// 遮罩與互動範圍（一般帶入散落區的 [Rect]）。
	final Rect region;

	/// 使用者點擊 [region] 內任意處時觸發（一般用來載入下一關）。
	final VoidCallback onContinue;

	@override
	Widget build(BuildContext context) {
		// 用 Listener 而非 GestureDetector.onTap：幼兒常會多指同時按，
		// TapGestureRecognizer 偵測到第二指就 cancel。Listener 接 pointer-down，
		// 第一個 down 就觸發，多餘 pointer 自然不影響。
		return Positioned.fromRect(
			rect: region,
			child: Listener(
				behavior: HitTestBehavior.opaque,
				onPointerDown: (_) => onContinue(),
				child: Stack(
					children: <Widget>[
						// backdrop：淡入
						Positioned.fill(
							child: ColoredBox(color: Colors.black.withValues(alpha: 0.45))
									.animate()
									.fadeIn(duration: 350.ms, curve: Curves.easeOut),
						),

						// 中央文字卡：彈出
						Center(
							child: Container(
								padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
								decoration: BoxDecoration(
									color: Colors.white,
									borderRadius: BorderRadius.circular(16),
									boxShadow: <BoxShadow>[
										BoxShadow(
											color: Colors.black.withValues(alpha: 0.2),
											blurRadius: 16,
											offset: const Offset(0, 4),
										),
									],
								),
								child: Column(
									mainAxisSize: MainAxisSize.min,
									children: <Widget>[
										const Text(
											PuzzleStrings.levelComplete,
											style: TextStyle(
												fontSize: 36,
												fontWeight: FontWeight.bold,
												color: Color(0xFF1F8A4C),
											),
										).animate(onPlay: (AnimationController c) => c.repeat()).shimmer(
													duration: 1800.ms,
													delay: 600.ms,
													color: Colors.amberAccent,
												),
										const SizedBox(height: 12),
										const Text(
											PuzzleStrings.nextLevel,
											style: TextStyle(
												fontSize: 18,
												color: Colors.black54,
											),
										),
									],
								),
							)
									.animate()
									.fadeIn(duration: 300.ms, curve: Curves.easeOut)
									.scale(
										duration: 600.ms,
										curve: Curves.elasticOut,
										begin: const Offset(0.6, 0.6),
										end: const Offset(1.0, 1.0),
									),
						),
					],
				),
			),
		);
	}
}
