import "dart:async";

import "package:flutter/material.dart";
import "package:provider/provider.dart";
import "package:showcaseview/showcaseview.dart";

import "../../../core/constants/app_colors.dart";
import "../../../core/constants/ui_strings.dart";
import "../../../core/routing/app_router.dart";
import "../../../core/routing/route_observer.dart";
import "../../../core/storage/settings_repository.dart";
import "../../../core/system/interop.dart";
import "../../../shared/widgets/centered_showcase_bubble.dart";
import "../../../shared/widgets/click_sound.dart";
import "../../../shared/widgets/font_ready_signal.dart";
import "../../../shared/widgets/tutorial_bubble.dart";
// 家長鎖暫時停用、保留 import 以便日後恢復（見 _enterParent）。
// ignore: unused_import
import "../../../shared/widgets/parental_lock_dialog.dart";
import "widgets/gear_button.dart";

/// 首頁：大「開始」按鈕、右上長按齒輪進家長區。
///
/// 首次進入時自動播放教學流程（依序高亮「開始拼圖」按鈕、齒輪按鈕）。
/// 每次更新教學內容把 [_homeTutorialVersion] +1，讓所有舊使用者重新看一次。
class HomePage extends StatefulWidget {
	const HomePage({super.key});

	/// 首頁教學「當前版本」。更新教學內容時 bump 此值，舊使用者會重看一次。
	static const int _homeTutorialVersion = 1;

	@override
	State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with RouteAware {
	final GlobalKey _welcomeKey = GlobalKey();
	final GlobalKey _pwaHintKey = GlobalKey();
	final GlobalKey _startKey = GlobalKey();
	final GlobalKey _gearKey = GlobalKey();
	late final ShowcaseView _showcase;

	/// PWA 安裝引導文案；null 表示不顯示（非 web 或已 standalone）。
	/// `_maybeStartTutorial` 啟動時固定一次，避免步驟陣列在中途變動。
	String? _pwaHint;

	@override
	void initState() {
		super.initState();
		// 全域關掉套件的上下飄動動畫：實作每幀 markNeedsPaint 整個 tooltip
		// 子樹，連 RepaintBoundary 都擋不住、在 web 上重繪文字 + shadow 很重。
		// 改由 TutorialBubble / CenteredShowcaseBubble 自行做動畫（有 RB 保護）。
		_showcase = ShowcaseView.register(
			scope: "home",
			disableMovingAnimation: true,
		);
		// 等第一幀畫完才能取得各 widget 的實際 rect、再啟動教學
		WidgetsBinding.instance.addPostFrameCallback((_) => _maybeStartTutorial());
	}

	@override
	void didChangeDependencies() {
		super.didChangeDependencies();
		// 訂閱 RouteObserver：當從家長頁 pop 回來時觸發 didPopNext，
		// 重新檢查教學版本（家長頁有「重新觀看教學」按鈕會清掉版本紀錄）。
		final ModalRoute<void>? route = ModalRoute.of(context);
		if (route != null) {
			appRouteObserver.subscribe(this, route);
		}
	}

	@override
	void dispose() {
		appRouteObserver.unsubscribe(this);
		_showcase.unregister();
		super.dispose();
	}

	@override
	void didPopNext() {
		// 從子頁面 pop 回首頁：教學版本可能被重設，重跑一次檢查。
		_maybeStartTutorial();
	}

	Future<void> _maybeStartTutorial() async {
		if (!mounted) return;
		final SettingsRepository repo = context.read<SettingsRepository>();
		final int seen = repo.tutorialVersionSeen("home");
		if (seen >= HomePage._homeTutorialVersion) return;
		// Web：等 FontReadyProbe 量到中文字寬度正常才啟動，避免 TextPainter
		// 與 RenderBox 量到 fallback tofu 寬度導致氣泡 layout / target rect 失準。
		await waitForFontsReady();
		if (!mounted) return;

		// 依平台/瀏覽器決定是否插入 PWA 安裝引導步驟（welcome 之後）。
		// interop 只回 "safari" / "generic" / null 標籤，文案在本檔對應。
		final String? kind = pwaInstallHint();
		final String? hint = switch (kind) {
			"safari" => HomeStrings.pwaHintSafari,
			"generic" => HomeStrings.pwaHintGeneric,
			_ => null,
		};
		setState(() => _pwaHint = hint);

		final List<GlobalKey> steps = <GlobalKey>[
			_welcomeKey,
			if (hint != null) _pwaHintKey,
			_startKey,
			_gearKey,
		];
		_showcase.startShowCase(steps);
		// 不等使用者真的看完，直接記為「已看過」— 避免使用者中途離開又每次都被
		// 強塞同一輪教學。要重看請從家長區提供入口（後續實作）。
		unawaited(
				repo.setTutorialVersionSeen("home", HomePage._homeTutorialVersion));
	}

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
								child: Showcase.withWidget(
									key: _gearKey,
									targetShapeBorder: const CircleBorder(),
									container: TutorialBubble(
										text: HomeStrings.gearTutorial,
										onTap: _showcase.next,
									),
									child: GearButton(
										onLongPressComplete: () => _enterParent(context),
										bigKidMode:
												context.read<SettingsRepository>().bigKidMode,
									),
								),
							),
							// 中央：兩個模式按鈕（嵌入拼圖 / 多片拼圖），左右並排。
							// 教學氣泡仍掛在「多片拼圖」這顆上，沿用既有 startTutorial 文案
							// （首版教學只介紹多片拼圖；嵌入拼圖之後再加 step）。
							Center(
								child: Row(
									mainAxisSize: MainAxisSize.min,
									children: <Widget>[
										_StartButton(
											label: HomeStrings.startInsetPuzzle,
											onPressed: () async {
												await requestFullscreenLandscape();
												if (!context.mounted) return;
												unawaited(Navigator.of(context)
														.pushNamed(AppRoutes.insetPuzzleSetup));
											},
										),
										const SizedBox(width: 24),
										Showcase.withWidget(
											key: _startKey,
											container: TutorialBubble(
												text: HomeStrings.startTutorial,
												onTap: _showcase.next,
											),
											child: _StartButton(
												label: HomeStrings.startMultiPuzzle,
												onPressed: () async {
													await requestFullscreenLandscape();
													if (!context.mounted) return;
													unawaited(Navigator.of(context)
															.pushNamed(AppRoutes.puzzleSetup));
												},
											),
										),
									],
								),
							),
							// 底部標題
							const Positioned(
								bottom: 24,
								left: 0,
								right: 0,
								child: Center(
									child: Text(
										HomeStrings.appTitle,
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
							// 教學流程第一步：歡迎訊息純氣泡
							CenteredShowcaseBubble(
								showcaseKey: _welcomeKey,
								message: HomeStrings.welcomeMessage,
								// 點任意處：先請求全螢幕橫向（user gesture context 內），
								// 再推進到下一步教學。
								onTap: () {
									requestFullscreenLandscape();
									_showcase.next();
								},
							),
							// 教學第二步（僅 web 且非 standalone）：PWA 安裝引導純氣泡。
							// _pwaHint == null 時 _maybeStartTutorial 不會把這個 key
							// 加進 steps，CenteredShowcaseBubble 雖仍掛在 tree 上但不會
							// 被觸發；message 給空字串避免 build 期 layout 計算。
							CenteredShowcaseBubble(
								showcaseKey: _pwaHintKey,
								message: _pwaHint ?? "",
								onTap: _showcase.next,
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
	const _StartButton({required this.label, required this.onPressed});

	final String label;
	final VoidCallback onPressed;

	@override
	Widget build(BuildContext context) {
		return ElevatedButton(
			onPressed: ClickSound.wrap(context, onPressed),
			style: ElevatedButton.styleFrom(
				backgroundColor: Colors.white,
				foregroundColor: AppColors.primary,
				padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
				shape: RoundedRectangleBorder(
					borderRadius: BorderRadius.circular(48),
				),
				elevation: 8,
			),
			child: Text(
				label,
				style: const TextStyle(
					fontSize: 28,
					fontWeight: FontWeight.bold,
				),
			),
		);
	}
}
