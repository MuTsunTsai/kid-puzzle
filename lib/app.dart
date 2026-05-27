import "package:flutter/material.dart";

import "core/constants/app_colors.dart";
import "core/constants/ui_strings.dart";
import "core/routing/app_router.dart";
import "core/routing/route_observer.dart";
import "shared/widgets/font_ready_probe.dart";
import "shared/widgets/rotate_device_overlay.dart";

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
			onGenerateInitialRoutes: (String _) => <Route<dynamic>>[
				MaterialPageRoute<void>(
					settings: const RouteSettings(name: AppRoutes.home),
					builder: AppRouter.routes[AppRoutes.home]!,
				),
			],
			onUnknownRoute: AppRouter.onUnknownRoute,
			// 全域 RouteObserver：讓各頁面用 RouteAware 監聽「自己再次成為 top route」
			// 事件（didPopNext），用於從子頁面 pop 回來時重新檢查教學狀態等。
			navigatorObservers: <NavigatorObserver>[appRouteObserver],
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
