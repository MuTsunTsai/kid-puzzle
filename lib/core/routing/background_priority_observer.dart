import "package:flutter/material.dart";

import "../network/background_asset_cache.dart";
import "app_router.dart";

/// 全域 [NavigatorObserver]：依當下 top route 名稱決定 [BackgroundAssetCache]
/// 的下載優先模式。
///
/// 規則（見 docs / CLAUDE.md「背景下載優先策略」）：
/// - 「圖庫管理」+「多片拼圖」相關頁面 → puzzle 優先
/// - 「素材管理」+ 多片拼圖以外的遊戲模式 → sprite 優先
/// - 其餘（首頁、家長頁本身、未知）→ no preference
class BackgroundPriorityRouteObserver
		extends NavigatorObserver {
	BackgroundPriorityRouteObserver(this._cache);

	final BackgroundAssetCache _cache;

	@override
	void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
		_applyFor(route);
	}

	@override
	void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
		if (newRoute != null) _applyFor(newRoute);
	}

	@override
	void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
		// Pop 完、previousRoute 重新成為 top
		if (previousRoute != null) _applyFor(previousRoute);
	}

	void _applyFor(Route<dynamic> route) {
		final String? name = route.settings.name;
		_cache.setPriority(_priorityFor(name));
	}

	static DownloadPriority _priorityFor(String? name) {
		if (name == null) return DownloadPriority.none;
		switch (name) {
			case AppRoutes.puzzle:
			case AppRoutes.puzzleSetup:
			case AppRoutes.parentGallery:
			case AppRoutes.parentGalleryDetail:
			case AppRoutes.parentImageCrop:
				return DownloadPriority.puzzle;
			case AppRoutes.insetPuzzle:
			case AppRoutes.insetPuzzleSetup:
			case AppRoutes.parentSprites:
			case AppRoutes.parentSpritesDetail:
				return DownloadPriority.sprite;
			default:
				return DownloadPriority.none;
		}
	}
}
