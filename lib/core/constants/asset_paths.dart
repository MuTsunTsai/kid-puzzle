import "package:flutter/services.dart" show AssetManifest, AssetBundle, rootBundle;

/// 內建資源路徑集中管理。
class AssetPaths {
	AssetPaths._();

	/// 內建拼圖圖檔目錄（pubspec.yaml 以整個目錄宣告，新增檔案不需改 pubspec）。
	static const String builtinPuzzlesDir = "assets/images/puzzles/";

	/// 可接受的拼圖圖檔副檔名（小寫）。
	static const Set<String> _puzzleExtensions = <String>{".jpg", ".jpeg", ".png", ".webp"};

	/// 動態掃描 [builtinPuzzlesDir] 下的所有圖檔。
	///
	/// 透過 [AssetManifest] 讀取 pubspec 已登錄的資產清單、過濾出此目錄下
	/// 副檔名為 [_puzzleExtensions] 的檔案，依檔名排序。
	///
	/// 新增內建圖只要把檔案放進 `assets/images/puzzles/`、執行 `flutter pub get`
	/// 即可被收錄（pubspec 已以目錄宣告、無需修改）。
	static Future<List<String>> loadBuiltinPuzzles({AssetBundle? bundle}) async {
		final AssetManifest manifest =
				await AssetManifest.loadFromAssetBundle(bundle ?? rootBundle);
		final List<String> paths = manifest
				.listAssets()
				.where((String p) => p.startsWith(builtinPuzzlesDir))
				.where((String p) {
					final int dot = p.lastIndexOf(".");
					if (dot < 0) return false;
					return _puzzleExtensions.contains(p.substring(dot).toLowerCase());
				})
				.toList()
			..sort();
		return paths;
	}

	// 音效檔
	static const String sfxClick = "assets/audio/click.mp3";
	static const String sfxPickup = "assets/audio/pickup.mp3";
	static const String sfxDrop = "assets/audio/drop.mp3";
	static const String sfxSnap = "assets/audio/snap.mp3";
	static const String sfxRotate = "assets/audio/rotate.mp3";
	static const String sfxComplete = "assets/audio/complete.mp3";
	static const String sfxError = "assets/audio/error.mp3";
}
