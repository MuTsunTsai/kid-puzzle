import "dart:async";

import "package:firebase_core/firebase_core.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:hive_ce_flutter/hive_flutter.dart";
import "package:provider/provider.dart";

import "app.dart";
import "core/analytics/analytics_service.dart";
import "core/audio/audio_service.dart";
import "core/audio/voice_service.dart";
import "core/constants/asset_paths.dart";
import "core/constants/feature_flags.dart";
import "core/network/background_asset_cache.dart";
import "core/sprites/sprite_manifest.dart";
import "core/sprites/sprite_registry.dart";
import "core/sprites/sprite_selection.dart";
import "core/storage/gallery_repository.dart";
import "core/storage/settings_repository.dart";
import "core/system/interop.dart";
import "firebase_options.dart";

Future<void> main() async {
	WidgetsFlutterBinding.ensureInitialized();

	// Firebase 初始化（含 Analytics）。失敗不擋啟動 — 應用本身不依賴 Firebase。
	try {
		await Firebase.initializeApp(
			options: DefaultFirebaseOptions.currentPlatform,
		);
		AnalyticsService.instance.init();
	} catch (_) {}

	// Web：禁止 Flutter 換頁堆 history。iOS Safari / PWA 邊緣手勢就無事可做。
	installNoHistoryUrlStrategy();

	// 鎖定為橫向：4:3 圖在橫向體驗較好，幼兒平板/手機橫拿也是常見姿勢
	await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
		DeviceOrientation.landscapeLeft,
		DeviceOrientation.landscapeRight,
	]);

	// 沉浸式全螢幕 + 系統手勢攔截：在 Android 端由 MainActivity.applyImmersive()
	// 處理（含 systemGestureExclusionRects 與 onApplyWindowInsets re-hide）。
	// iOS / 其他平台仍走 Flutter 內建設定。
	await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

	// 音效 / 語音服務：先建立、再 preload / init（缺檔或失敗會靜默）。
	final AudioService audio = AudioService();
	final VoiceService voice = VoiceService();
	await audio.preload();
	await voice.init();

	// Hive 初始化 + 開設定 / 圖庫 box
	await Hive.initFlutter();
	final SettingsRepository settings = await SettingsRepository.open();
	// 把舊版 Set<String> 的 sprite selections 一次性 migrate 成 Map<String, bool>
	// （明確 true / false / 未設定三態），避免「整類取消」被預設規則覆蓋。
	await settings.migrateLegacySpriteSelections();
	final GalleryRepository gallery = await GalleryRepository.open();
	// 把已保存的音效/語音 開關套用到 service
	audio.enabled = settings.audioEnabled;
	voice.enabled = settings.voiceEnabled;

	// Sprite manifest：fire-and-forget 載入。實際進嵌入拼圖時若還沒 ready，
	// 該頁的 _bootstrap 會自己 await registry.load()。
	final SpriteRegistry sprites = SpriteRegistry();
	// 「語音」開關同時控制：(1) VoiceService 的關卡鼓勵語、(2) 嵌入拼圖
	// snap 上去的物件名稱朗讀。兩條都是預錄人聲、語意一致。
	sprites.voiceEnabled = settings.voiceEnabled;
	// kEnableInsetPuzzle = false 時跳過 sprite manifest 載入與背景下載——
	// SpriteRegistry 物件仍會放進 Provider（家長頁「語音」switch 會無條件
	// 寫入 voiceEnabled、保持 wiring 一致），但不載 manifest 也不 prefetch
	// sprite 資源、節省啟動時間與頻寬。
	final Future<void>? spritesLoading = kEnableInsetPuzzle
			? sprites.load().catchError((_) {})
			: null;
	if (spritesLoading != null) unawaited(spritesLoading);

	// Web：啟動內建圖背景下載 worker（其他平台 stub no-op）。
	// fire-and-forget — 不擋啟動，下載狀態靠 ChangeNotifier 通知 UI。
	final BackgroundAssetCache assetCache = BackgroundAssetCache.instance;
	unawaited(
		AssetPaths.loadBuiltinPuzzles().then((List<String> paths) {
			return assetCache.startPuzzleAssets(paths);
		}).catchError((Object _) {}),
	);

	// Sprite manifest 載完後註冊 sprite 資源到背景下載服務。
	// 順序：使用者已選取的類別在前、未選的在後；確保剛開 app 就先 prefetch
	// 玩家最可能進去的類別。
	// kEnableInsetPuzzle = false 時 spritesLoading 為 null、整段略過。
	if (spritesLoading != null) {
		unawaited(spritesLoading.then((_) {
			_registerSpriteAssetsToCache(
				cache: assetCache,
				sprites: sprites,
				settings: settings,
			);
		}).catchError((Object _) {}));
	}

	runApp(
		Provider<AudioService>.value(
			value: audio,
			child: Provider<VoiceService>.value(
				value: voice,
				child: Provider<SettingsRepository>.value(
					value: settings,
					child: Provider<SpriteRegistry>.value(
						value: sprites,
						child: ChangeNotifierProvider<GalleryRepository>.value(
							value: gallery,
							child: ChangeNotifierProvider<BackgroundAssetCache>.value(
								value: assetCache,
								child: const KidPuzzleApp(),
							),
						),
					),
				),
			),
		),
	);
}

/// Sprite manifest 載入完成後呼叫：算出每個類別的 sheet / voice URL（含
/// rev query）+ 排序（已選類別在前），注入背景下載服務。
void _registerSpriteAssetsToCache({
	required BackgroundAssetCache cache,
	required SpriteRegistry sprites,
	required SettingsRepository settings,
}) {
	final List<SpriteCategory> categories = sprites.categories;
	if (categories.isEmpty) return;

	final Map<String, SpriteAssetGroup> assets =
			<String, SpriteAssetGroup>{};
	// Flutter web 把 pubspec asset 放在 `build/web/assets/<token>`，token 又以
	// `assets/` 開頭、所以實際 URL 是雙層 `assets/assets/...`。與
	// rootBundle + sprite_asset_loader_web 行為一致。
	for (final SpriteCategory c in categories) {
		final String sheetFile = c.sheet.file;
		final String sheetRev = c.sheet.rev ?? "";
		final String voiceFile = "audio/sprites/${c.id}.zip";
		final String voiceRev = c.voiceRev ?? "";
		assets[c.id] = SpriteAssetGroup(
			sheetUrl: sheetRev.isEmpty
					? "assets/assets/$sheetFile"
					: "assets/assets/$sheetFile?rev=$sheetRev",
			voiceUrl: voiceRev.isEmpty
					? "assets/assets/$voiceFile"
					: "assets/assets/$voiceFile?rev=$voiceRev",
		);
	}

	final Set<String> resolved = SpriteSelection.resolveSelected(
		stored: settings.spriteSelections,
		categories: categories,
	);
	final List<String> ordered = <String>[
		for (final SpriteCategory c in categories)
			if (resolved.contains(c.id)) c.id,
		for (final SpriteCategory c in categories)
			if (!resolved.contains(c.id)) c.id,
	];

	cache.setSpriteAssets(assets: assets, orderedCategoryIds: ordered);
}
