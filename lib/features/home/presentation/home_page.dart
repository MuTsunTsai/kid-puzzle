import "package:flutter/material.dart";

import "../../../core/constants/app_colors.dart";
import "../../../core/routing/app_router.dart";
import "../../../core/system/fullscreen_landscape.dart";
import "../../../shared/widgets/click_sound.dart";
// 家長鎖暫時停用、保留 import 以便日後恢復（見 _enterParent）。
// ignore: unused_import
import "../../../shared/widgets/parental_lock_dialog.dart";
import "widgets/gear_button.dart";

/// 首頁：大「開始」按鈕、右上長按齒輪進家長區。
class HomePage extends StatelessWidget {
	const HomePage({super.key});

	@override
	Widget build(BuildContext context) {
		return Scaffold(
			body: Container(
				decoration: const BoxDecoration(
					gradient: LinearGradient(
						begin: Alignment.topLeft,
						end: Alignment.bottomRight,
						colors: <Color>[
							AppColors.primary,
							AppColors.accent,
						],
					),
				),
				child: SafeArea(
					child: Stack(
						children: <Widget>[
							// 右上：家長入口
							Positioned(
								top: 12,
								right: 12,
								child: GearButton(
									onLongPressComplete: () => _enterParent(context),
								),
							),
							// 中央：大「開始」按鈕
							Center(
								child: _StartButton(
									onPressed: () async {
										// Web 手機瀏覽器：在 user gesture handler 內請求全螢幕 + 鎖橫向。
										// 必須在 pushNamed 之前 await，否則 gesture context 已過期、瀏覽器會拒。
										// 非手機 / 非 web 平台一律 no-op。
										await requestFullscreenLandscape();
										if (!context.mounted) return;
										Navigator.of(context).pushNamed(AppRoutes.puzzleSetup);
									},
								),
							),
							// 底部標題
							const Positioned(
								bottom: 24,
								left: 0,
								right: 0,
								child: Center(
									child: Text(
										"幼兒益智遊戲",
										style: TextStyle(
											fontSize: 24,
											color: Colors.white,
											fontWeight: FontWeight.bold,
											shadows: <Shadow>[
												Shadow(
													offset: Offset(1, 1),
													blurRadius: 3,
													color: Colors.black38,
												),
											],
										),
									),
								),
							),
						],
					),
				),
			),
		);
	}

	Future<void> _enterParent(BuildContext context) async {
		final NavigatorState navigator = Navigator.of(context);
		// 家長鎖數字問答暫時停用：直接進家長頁。長按齒輪 [gearLongPressSeconds]
		// 秒這層門檻已足夠擋住幼兒誤觸。未來若要恢復，取消下面兩行的註解、
		// 並移除 navigator 變數宣告下方的 `// ignore` 行即可。
		// final bool passed = await ParentalLockDialog.show(context);
		// if (!passed) return;
		await navigator.pushNamed(AppRoutes.parentHome);
	}
}

class _StartButton extends StatelessWidget {
	const _StartButton({required this.onPressed});

	final VoidCallback onPressed;

	@override
	Widget build(BuildContext context) {
		return ElevatedButton(
			onPressed: ClickSound.wrap(context, onPressed),
			style: ElevatedButton.styleFrom(
				backgroundColor: Colors.white,
				foregroundColor: AppColors.primary,
				padding: const EdgeInsets.symmetric(horizontal: 56, vertical: 24),
				shape: RoundedRectangleBorder(
					borderRadius: BorderRadius.circular(48),
				),
				elevation: 8,
			),
			child: const Text(
				"開始拼圖",
				style: TextStyle(
					fontSize: 32,
					fontWeight: FontWeight.bold,
				),
			),
		);
	}
}
