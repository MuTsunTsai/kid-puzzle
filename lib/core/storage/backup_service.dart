import "dart:convert";
import "dart:typed_data";

import "package:archive/archive.dart";
import "package:flutter/foundation.dart";

import "gallery_repository.dart";
import "settings_repository.dart";

/// 備份檔的封裝格式：store-mode zip，副檔名 .kpb（kid-puzzle-backup）。
///
/// 結構：
/// ```
/// archive root/
/// ├── manifest.json   ← 所有 metadata（settings dump + gallery meta）
/// └── images/<uuid>.jpg  ← 自訂圖原始 JPEG bytes，不重新編碼、不 base64
/// ```
///
/// 選 zip 的理由：
/// - 真二進位、檔案大小 ≈ 原 bytes 總和
/// - 跨平台、使用者好奇時可直接用任意 zip 工具開來看
/// - 已有 archive 套件、不必新增依賴
/// - store mode：JPEG 已壓過再壓沒意義；解壓快且穩
class BackupService {
	BackupService._();

	/// 備份檔內部 schema 版本。讀檔時比對 [_supportedVersions]。
	/// 修改時、要保證向後相容（或寫 migration）。
	static const int kFormatVersion = 1;
	static const Set<int> _supportedVersions = <int>{1};

	/// manifest 在 zip 內的固定 entry 名。
	static const String _manifestEntry = "manifest.json";

	/// 圖片在 zip 內的資料夾。
	static const String _imagesDir = "images";

	/// zip entry 的固定修改時間（DOS date 不支援 < 1980，選整數年）。
	/// 用固定時間避免「同樣內容備份兩次、bytes 不同」造成困擾。
	static final DateTime _zipFixedDate = DateTime.utc(2000, 1, 1);

	/// 把當前 settings + gallery 打包成 .kpb bytes。
	///
	/// [appVersion] 純粹寫進 manifest 供 debug / future migration 參考，
	/// 讀取端不會檢查。
	static Future<Uint8List> exportBackup({
		required SettingsRepository settings,
		required GalleryRepository gallery,
		required String appVersion,
	}) async {
		final Map<String, Object?> settingsDump = settings.exportAll();
		final Map<String, Object?> galleryMeta = gallery.exportMeta();

		// 蒐集所有要寫進 zip 的圖 bytes（依各套 imageIds 順序）
		final List<Map<String, Object?>> userSets =
				(galleryMeta["userSets"] as List<dynamic>?)
								?.cast<Map<String, Object?>>() ??
						<Map<String, Object?>>[];
		final List<({String id, Uint8List bytes})> imagesToWrite =
				<({String id, Uint8List bytes})>[];
		final Set<String> writtenIds = <String>{};
		for (final Map<String, Object?> set in userSets) {
			final List<dynamic> ids =
					(set["imageIds"] as List<dynamic>?) ?? const <dynamic>[];
			for (final dynamic idRaw in ids) {
				if (idRaw is! String) continue;
				if (!writtenIds.add(idRaw)) continue; // 跨套共享 id 理論上不會、保險
				final Uint8List? bytes = gallery.exportImageBytes(idRaw);
				if (bytes == null) continue;
				imagesToWrite.add((id: idRaw, bytes: bytes));
			}
		}

		final Map<String, Object?> manifest = <String, Object?>{
			"format": "kid-puzzle-backup",
			"version": kFormatVersion,
			"exportedAt": DateTime.now().toUtc().toIso8601String(),
			"appVersion": appVersion,
			"settings": settingsDump,
			"gallery": galleryMeta,
		};
		final Uint8List manifestBytes =
				Uint8List.fromList(utf8.encode(jsonEncode(manifest)));

		final Archive archive = Archive();
		archive.addFile(_makeStoreFile(_manifestEntry, manifestBytes));
		for (final ({String id, Uint8List bytes}) e in imagesToWrite) {
			archive.addFile(_makeStoreFile("$_imagesDir/${e.id}.jpg", e.bytes));
		}

		// ZipEncoder 預設用 DEFLATE；我們對每個檔個別指定 STORE，
		// 整體 encode 仍然走 ZipEncoder 的標準輸出。
		final List<int> encoded =
				ZipEncoder().encode(archive, level: DeflateLevel.none);
		return Uint8List.fromList(encoded);
	}

	static ArchiveFile _makeStoreFile(String name, Uint8List bytes) {
		final ArchiveFile f = ArchiveFile(name, bytes.length, bytes);
		f.compression = CompressionType.none;
		// 固定修改時間：給 manifest 寫一致；個別圖 entry 也同一時間
		f.lastModTime = _toMsDosTime(_zipFixedDate);
		return f;
	}

	/// 把 DateTime 轉成 MS-DOS time 格式（archive 4.x 用這個欄位）。
	static int _toMsDosTime(DateTime dt) {
		final int year = dt.year.clamp(1980, 2107);
		final int datePart =
				((year - 1980) << 9) | (dt.month << 5) | dt.day;
		final int timePart = (dt.hour << 11) | (dt.minute << 5) | (dt.second ~/ 2);
		return (datePart << 16) | timePart;
	}

	/// 解析 .kpb bytes、回傳 [BackupContents]。
	///
	/// 失敗（檔案不是 zip / 缺 manifest / version 不支援）丟 [FormatException]。
	static Future<BackupContents> readBackup(Uint8List bytes) async {
		final Archive archive;
		try {
			archive = ZipDecoder().decodeBytes(bytes);
		} catch (e) {
			throw const FormatException("無法解析備份檔（不是有效的 zip）");
		}

		ArchiveFile? manifestFile;
		final Map<String, Uint8List> images = <String, Uint8List>{};
		for (final ArchiveFile f in archive.files) {
			if (!f.isFile) continue;
			if (f.name == _manifestEntry) {
				manifestFile = f;
				continue;
			}
			if (f.name.startsWith("$_imagesDir/")) {
				final String tail = f.name.substring(_imagesDir.length + 1);
				// images/<uuid>.jpg → uuid
				final int dot = tail.lastIndexOf(".");
				final String id = dot > 0 ? tail.substring(0, dot) : tail;
				if (id.isEmpty) continue;
				final List<int>? raw = f.content as List<int>?;
				if (raw == null) continue;
				images[id] = Uint8List.fromList(raw);
			}
		}

		if (manifestFile == null) {
			throw const FormatException("備份檔缺 manifest.json");
		}
		final List<int>? manifestRaw = manifestFile.content as List<int>?;
		if (manifestRaw == null) {
			throw const FormatException("備份檔 manifest 讀取失敗");
		}
		final Map<String, Object?> manifest;
		try {
			manifest = jsonDecode(utf8.decode(manifestRaw)) as Map<String, Object?>;
		} catch (e) {
			throw const FormatException("備份檔 manifest 不是合法 JSON");
		}

		final Object? versionRaw = manifest["version"];
		final int version =
				versionRaw is int ? versionRaw : (versionRaw is num ? versionRaw.toInt() : -1);
		if (!_supportedVersions.contains(version)) {
			throw FormatException("不支援的備份檔版本：$version");
		}
		if (manifest["format"] != "kid-puzzle-backup") {
			throw const FormatException("不是本應用程式的備份檔");
		}

		return BackupContents(
			version: version,
			exportedAt: manifest["exportedAt"] as String?,
			appVersion: manifest["appVersion"] as String?,
			settings: _asStringKeyedMap(manifest["settings"]),
			gallery: _asStringKeyedMap(manifest["gallery"]),
			images: images,
		);
	}

	/// 套用備份內容到當前 app state。
	///
	/// [galleryMode]：
	/// - `BackupGalleryMode.replace`：清掉所有自訂套、用備份檔的取代；
	///   同時 settings 整批覆蓋（含 tutorialVersion.*）。
	/// - `BackupGalleryMode.merge`：圖庫依名稱合併（同名追加圖、不同名新增套）；
	///   settings 與教學紀錄維持不變、**不**動。
	static Future<void> applyBackup({
		required BackupContents contents,
		required BackupGalleryMode galleryMode,
		required SettingsRepository settings,
		required GalleryRepository gallery,
	}) async {
		final List<Map<String, Object?>> userSets = _readUserSets(contents.gallery);
		final bool builtinEnabled =
				(contents.gallery["builtinEnabled"] as bool?) ?? true;

		Uint8List? bytesProvider(String id) => contents.images[id];

		switch (galleryMode) {
			case BackupGalleryMode.replace:
				await settings.importAll(contents.settings);
				await gallery.importReplace(
					builtinEnabled: builtinEnabled,
					userSets: userSets,
					imageBytesProvider: bytesProvider,
				);
				break;
			case BackupGalleryMode.merge:
				await gallery.importMerge(
					userSets: userSets,
					imageBytesProvider: bytesProvider,
				);
				break;
		}
	}

	static List<Map<String, Object?>> _readUserSets(Map<String, Object?> gallery) {
		final Object? raw = gallery["userSets"];
		if (raw is! List) return <Map<String, Object?>>[];
		return <Map<String, Object?>>[
			for (final Object? item in raw)
				if (item is Map) _asStringKeyedMap(item),
		];
	}

	static Map<String, Object?> _asStringKeyedMap(Object? raw) {
		if (raw is Map) {
			return <String, Object?>{
				for (final MapEntry<Object?, Object?> e in raw.entries)
					if (e.key is String) e.key as String: e.value,
			};
		}
		return <String, Object?>{};
	}
}

/// 解析後的備份檔內容,供 apply 時使用。
class BackupContents {
	BackupContents({
		required this.version,
		required this.exportedAt,
		required this.appVersion,
		required this.settings,
		required this.gallery,
		required this.images,
	});

	final int version;
	final String? exportedAt;
	final String? appVersion;
	final Map<String, Object?> settings;
	final Map<String, Object?> gallery;
	/// imageId → JPEG bytes。
	final Map<String, Uint8List> images;

	/// 備份檔中的自訂套個數。
	int get userSetCount {
		final Object? raw = gallery["userSets"];
		if (raw is List) return raw.length;
		return 0;
	}

	/// 備份檔中的自訂圖總張數（依 imageIds 累計、不一定 = images.length）。
	int get totalImageCount {
		int n = 0;
		final Object? raw = gallery["userSets"];
		if (raw is! List) return 0;
		for (final Object? s in raw) {
			if (s is! Map) continue;
			final Object? ids = s["imageIds"];
			if (ids is List) n += ids.length;
		}
		return n;
	}
}

/// 匯入「圖庫」時的兩種模式。設定值的處理規則寫在 [BackupService.applyBackup]。
enum BackupGalleryMode {
	/// 覆蓋：自訂圖庫全清掉、用備份檔的取代；設定值也整批覆蓋。
	replace,

	/// 新增（合併）：依名稱匹配把備份檔的圖追加到既有/新建套；
	/// 設定值與教學紀錄不動。
	merge,
}
