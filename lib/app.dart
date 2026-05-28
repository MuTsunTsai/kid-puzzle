import "package:flutter/material.dart";

import "core/analytics/analytics_service.dart";
import "core/constants/app_colors.dart";
import "core/constants/ui_strings.dart";
import "core/routing/app_router.dart";
import "core/routing/route_observer.dart";
import "core/system/interop.dart";
import "features/puzzle/domain/services/cell_planner.dart";
import "features/puzzle/presentation/puzzle_page.dart";
import "features/puzzle/presentation/puzzle_setup_page.dart";
import "shared/widgets/font_ready_probe.dart";
import "shared/widgets/rotate_device_overlay.dart";

/// 初始 route 堆疊建構。
///
/// 預設只回 home；若 URL query 帶 `?n=X&seed=Y`，多堆一個 puzzle route 並
/// 把 (n, seed) 注入 [setPuzzleDebugFirstLevel]，puzzle 第一關就會固定用該參數
/// + voronoi 跑。返回時自然回到底層 home。
List<Route<dynamic>> _buildInitialRoutes() {
	final List<Route<dynamic>> routes = <Route<dynamic>>[
		MaterialPageRoute<void>(
			settings: const RouteSettings(name: AppRoutes.home),
			builder: AppRouter.routes[AppRoutes.home]!,
		),
	];
	final ({int n, int seed})? debug = readDebugLevelQuery();
	if (debug != null) {
		// 注入後門參數；puzzle_page 第一次進來就會 consume
		setPuzzleDebugFirstLevel(debug);
		routes.add(
			MaterialPageRoute<void>(
				settings: RouteSettings(
					name: AppRoutes.puzzle,
					// PuzzleArguments：強制只給 voronoi、範圍 = debug.n、其餘預設。
					arguments: PuzzleArguments(
						minPieces: debug.n,
						maxPieces: debug.n,
						showHint: true,
						cutModes: <CutMode>{CutMode.voronoi},
						rotationEnabled: false,
						screenLockEnabled: false,
						bigKidMode: false,
					),
				),
				builder: AppRouter.routes[AppRoutes.puzzle]!,
			),
		);
	}
	return routes;
}

/// 根 App Widget：MaterialApp、主題、路由註冊。
class KidPuzzleApp extends StatelessWidget {
	const KidPuzzleApp({super.key});

	@override
	Widget build(BuildContext context) {
		return MaterialApp(
			title: "幼兒益智遊戲",
			debugShowCheckedModeBanner: false,
			theme: ThemeData(
				colorScheme: ColorScheme.fromSeed(
					seedColor: AppColors.primary,
					brightness: Brightness.light,
				),
				useMaterial3: true,
				fontFamily: "Roboto",
				// CupertinoPageTransitionsBuilder 會無條件在 iOS / macOS route 上安裝
				// _CupertinoBackGestureDetector（不檢查 kIsWeb），導致 iOS Safari / PWA
				// 上從左緣往右滑會 pop 路由。全平台統一改用 FadeForwards 殺掉手勢。
				pageTransitionsTheme: const PageTransitionsTheme(
					builders: <TargetPlatform, PageTransitionsBuilder>{
						TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
						TargetPlatform.iOS: FadeForwardsPageTransitionsBuilder(),
						TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
						TargetPlatform.fuchsia: FadeForwardsPageTransitionsBuilder(),
						TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
						TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
					},
				),
			),
			initialRoute: AppRoutes.home,
			routes: AppRouter.routes,
			// Web 重新載入時，瀏覽器 URL hash 可能停在某個內頁（例如 /puzzle/setup）。
			// 直接依 hash 重建畫面會跳過必要的初始化（如 PuzzleArguments），
			// 容易出現未定義狀態。覆寫 onGenerateInitialRoutes 強制只回 home，
			// reload 後一律從首頁進入。
			//
			// Debug 後門：URL query `?n=X&seed=Y` → 堆 home → puzzle 兩個 route，
			// 直接跳進拼圖頁、隨機抽圖、用該 (n, seed) + voronoi 切割。返回時會
			// 回到底層 home。
			onGenerateInitialRoutes: (String _) => _buildInitialRoutes(),
			onUnknownRoute: AppRouter.onUnknownRoute,
			// 全域 NavigatorObserver：
			// - [appRouteObserver]：頁面用 RouteAware 監聽「自己再次成為 top route」
			//   事件（didPopNext），用於從子頁面 pop 回來時重新檢查教學狀態等。
			// - [FirebaseAnalyticsObserver]：自動送 screen_view 事件。未初始化時
			//   為 null，這邊用 whereType 過濾掉。
			navigatorObservers: <NavigatorObserver>[
				appRouteObserver,
				if (AnalyticsService.instance.observer != null)
					AnalyticsService.instance.observer!,
			],
			// 全域 overlay 與字型預熱：
			// - FontReadyProbe 用集中的 [preheatCharSet] 預熱整個 App 的中文 glyph，
			//   ready 前所有 route 都是透明 + IgnorePointer，避免子頁面第一次進去
			//   還看到 fallback / tofu。
			// - RotateDeviceOverlay 在 web 直向時顯示「請打橫」遮罩；其餘平台
			//   pass-through。
			builder: (BuildContext context, Widget? child) {
				return FontReadyProbe(
					probeText: preheatCharSet,
					child: RotateDeviceOverlay(child: child ?? const SizedBox.shrink()),
				);
			},
		);
	}
}
