import "package:flutter/foundation.dart";
import "package:flutter/material.dart";

/// Web 版專用：偵測到畫面為直向時，顯示滿版遮罩提示使用者把裝置打橫。
///
/// 包在 [MaterialApp.builder] 提供的 `child` 外層；非 web 平台 / 橫向時
/// 直接 pass-through，不影響任何輸入。
class RotateDeviceOverlay extends StatelessWidget {
	const RotateDeviceOverlay({super.key, required this.child});

	final Widget child;

	@override
	Widget build(BuildContext context) {
		// 非 web 平台直接 pass-through。Android 上目前是強制橫向、iOS 暫不做。
		if (!kIsWeb) return child;

		final Size size = MediaQuery.sizeOf(context);
		final bool isPortrait = size.height > size.width;
		// 桌面瀏覽器視窗即使「高 > 寬」也未必是「裝置直立」，但對使用體驗一樣不友善
		// （拼圖按 4:3 設計），所以一視同仁顯示提示。
		// 1:1 邊界用 `>=` 還是 `>`：選嚴格 `>`，正方形時 pass-through 給玩家機會玩。

		return Stack(
			children: <Widget>[
				child,
				if (isPortrait)
					const Positioned.fill(
						child: _PortraitBlocker(),
					),
			],
		);
	}
}

class _PortraitBlocker extends StatelessWidget {
	const _PortraitBlocker();

	@override
	Widget build(BuildContext context) {
		// AbsorbPointer 攔截所有手勢，避免遮罩底下的內容被誤觸
		return AbsorbPointer(
			child: ColoredBox(
				color: const Color(0xFFff8a65),
				child: Center(
					child: Padding(
						padding: const EdgeInsets.symmetric(horizontal: 32),
						child: Column(
							mainAxisSize: MainAxisSize.min,
							children: <Widget>[
								// 用 Transform 旋轉手機 icon 製造「請轉成橫向」的提示意象
								Transform.rotate(
									angle: 1.5708, // 90 度
									child: const Icon(
										Icons.stay_current_portrait,
										size: 96,
										color: Colors.white,
									),
								),
								const SizedBox(height: 24),
								const Text(
									"請把裝置打橫",
									style: TextStyle(
										fontSize: 28,
										fontWeight: FontWeight.bold,
										color: Colors.white,
									),
								),
								const SizedBox(height: 8),
								const Text(
									"本遊戲為橫向設計，請旋轉裝置以繼續遊玩。",
									textAlign: TextAlign.center,
									style: TextStyle(
										fontSize: 16,
										color: Colors.white,
									),
								),
							],
						),
					),
				),
			),
		);
	}
}
