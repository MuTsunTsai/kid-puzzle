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
import "core/network/builtin_image_cache.dart";
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
	final GalleryRepository gallery = await GalleryRepository.open();
	// 把已保存的音效/語音 開關套用到 service
	audio.enabled = settings.audioEnabled;
	voice.enabled = settings.ttsEnabled;

	// Web：啟動內建圖背景下載 worker（其他平台 stub no-op）。
	// fire-and-forget — 不擋啟動，下載狀態靠 ChangeNotifier 通知 UI。
	final BuiltinImageCache imageCache = BuiltinImageCache.instance;
	unawaited(
		AssetPaths.loadBuiltinPuzzles().then((List<String> paths) {
			return imageCache.start(paths);
		}).catchError((_) {}),
	);

	runApp(
		Provider<AudioService>.value(
			value: audio,
			child: Provider<VoiceService>.value(
				value: voice,
				child: Provider<SettingsRepository>.value(
					value: settings,
					child: ChangeNotifierProvider<GalleryRepository>.value(
						value: gallery,
						child: ChangeNotifierProvider<BuiltinImageCache>.value(
							value: imageCache,
							child: const KidPuzzleApp(),
						),
					),
				),
			),
		),
	);
}
