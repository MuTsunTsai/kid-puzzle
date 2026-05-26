import "package:flutter/material.dart";

import "core/constants/app_colors.dart";
import "core/routing/app_router.dart";

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
			),
			initialRoute: AppRoutes.home,
			routes: AppRouter.routes,
			onUnknownRoute: AppRouter.onUnknownRoute,
		);
	}
}
