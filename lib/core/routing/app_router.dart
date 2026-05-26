import "package:flutter/material.dart";

import "../../features/home/presentation/home_page.dart";
import "../../features/parent/presentation/gallery_detail_page.dart";
import "../../features/parent/presentation/gallery_page.dart";
import "../../features/parent/presentation/image_crop_page.dart";
import "../../features/parent/presentation/parent_home_page.dart";
import "../../features/puzzle/presentation/puzzle_page.dart";
import "../../features/puzzle/presentation/puzzle_setup_page.dart";

/// App 路由名稱常數
class AppRoutes {
	AppRoutes._();

	static const String home = "/";
	static const String puzzleSetup = "/puzzle/setup";
	static const String puzzle = "/puzzle";
	static const String parentHome = "/parent";
	static const String parentGallery = "/parent/gallery";
	static const String parentGalleryDetail = "/parent/gallery/detail";
	static const String parentSettings = "/parent/settings";
	static const String parentImageCrop = "/parent/gallery/crop";
}

/// 路由表
class AppRouter {
	AppRouter._();

	static final Map<String, WidgetBuilder> routes = <String, WidgetBuilder>{
		AppRoutes.home: (BuildContext context) => const HomePage(),
		AppRoutes.puzzleSetup: (BuildContext context) => const PuzzleSetupPage(),
		AppRoutes.puzzle: (BuildContext context) => const PuzzlePage(),
		AppRoutes.parentHome: (BuildContext context) => const ParentHomePage(),
		AppRoutes.parentGallery: (BuildContext context) => const GalleryPage(),
		AppRoutes.parentGalleryDetail: (BuildContext context) =>
				const GalleryDetailPage(),
		AppRoutes.parentImageCrop: (BuildContext context) => const ImageCropPage(),
	};

	/// 未知路由 fallback
	static Route<dynamic> onUnknownRoute(RouteSettings settings) {
		return MaterialPageRoute<void>(
			settings: settings,
			builder: (BuildContext context) => Scaffold(
				appBar: AppBar(title: const Text("找不到頁面")),
				body: Center(child: Text("未知路由：${settings.name}")),
			),
		);
	}
}
