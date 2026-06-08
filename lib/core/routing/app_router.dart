import "package:flutter/material.dart";

import "../constants/feature_flags.dart";
import "../../features/home/presentation/home_page.dart";
import "../../features/inset_puzzle/presentation/inset_puzzle_page.dart";
import "../../features/inset_puzzle/presentation/inset_puzzle_setup_page.dart";
import "../../features/parent/presentation/backup_page.dart";
import "../../features/parent/presentation/gallery_detail_page.dart";
import "../../features/parent/presentation/gallery_page.dart";
import "../../features/parent/presentation/image_crop_page.dart";
import "../../features/parent/presentation/parent_home_page.dart";
import "../../features/parent/presentation/sprites_detail_page.dart";
import "../../features/parent/presentation/sprites_page.dart";
import "../../features/puzzle/presentation/puzzle_page.dart";
import "../../features/puzzle/presentation/puzzle_setup_page.dart";

/// App 路由名稱常數
class AppRoutes {
	AppRoutes._();

	static const String home = "/";
	static const String puzzleSetup = "/puzzle/setup";
	static const String puzzle = "/puzzle";
	static const String insetPuzzleSetup = "/inset-puzzle/setup";
	static const String insetPuzzle = "/inset-puzzle";
	static const String parentHome = "/parent";
	static const String parentGallery = "/parent/gallery";
	static const String parentGalleryDetail = "/parent/gallery/detail";
	static const String parentSettings = "/parent/settings";
	static const String parentImageCrop = "/parent/gallery/crop";
	static const String parentSprites = "/parent/sprites";
	static const String parentSpritesDetail = "/parent/sprites/detail";
	static const String parentBackup = "/parent/backup";
}

/// 路由表
class AppRouter {
	AppRouter._();

	/// kEnableInsetPuzzle = false 時不註冊 inset / sprites 相關 route，
	/// 任何 hash URL deep link 進去都會落到 [onUnknownRoute]、無法繞過首頁
	/// 隱藏的按鈕進入未準備好的頁面。route 名稱常數仍保留（其他地方還引用）。
	static final Map<String, WidgetBuilder> routes = <String, WidgetBuilder>{
		AppRoutes.home: (BuildContext context) => const HomePage(),
		AppRoutes.puzzleSetup: (BuildContext context) => const PuzzleSetupPage(),
		AppRoutes.puzzle: (BuildContext context) => const PuzzlePage(),
		AppRoutes.parentHome: (BuildContext context) => const ParentHomePage(),
		AppRoutes.parentGallery: (BuildContext context) => const GalleryPage(),
		AppRoutes.parentGalleryDetail: (BuildContext context) =>
				const GalleryDetailPage(),
		AppRoutes.parentImageCrop: (BuildContext context) => const ImageCropPage(),
		AppRoutes.parentBackup: (BuildContext context) => const BackupPage(),
		if (kEnableInsetPuzzle) ...<String, WidgetBuilder>{
			AppRoutes.insetPuzzleSetup: (BuildContext context) =>
					const InsetPuzzleSetupPage(),
			AppRoutes.insetPuzzle: (BuildContext context) => const InsetPuzzlePage(),
			AppRoutes.parentSprites: (BuildContext context) => const SpritesPage(),
			AppRoutes.parentSpritesDetail: (BuildContext context) =>
					const SpritesDetailPage(),
		},
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
