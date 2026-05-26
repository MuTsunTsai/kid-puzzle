import "package:flutter/foundation.dart";
import "package:hive_ce/hive.dart";
import "package:uuid/uuid.dart";

import "../../shared/models/gallery_set.dart";
import "../constants/asset_paths.dart";

/// 圖庫倉庫：管理「圖庫套組」清單與內含圖檔。
///
/// **儲存策略（跨平台統一，不依賴 dart:io / path_provider）**
/// - Hive box `gallery`：自訂套 metadata list + 內建套的 enabled 狀態。
/// - Hive box `gallery_images`：自訂套的圖片 bytes（key = UUID, value = Uint8List）。
/// - 內建套：圖以 assets 路徑表示，runtime 由 [AssetPaths.loadBuiltinPuzzles]
///   掃出來，**不**進 Hive。
///
/// 對 UI 來說整體就是「不可變的 sets 清單」 + 「依 id 拿 bytes」；
/// 變更走 [ChangeNotifier] 通知。
class GalleryRepository extends ChangeNotifier {
	GalleryRepository._(this._metaBox, this._imagesBox, this._sets);

	final Box<Object?> _metaBox;
	final Box<Uint8List> _imagesBox;
	List<GallerySet> _sets;

	static const String _metaBoxName = "gallery";
	static const String _imagesBoxName = "gallery_images";
	static const String _kUserSets = "userSets";
	static const String _kBuiltinEnabled = "builtinEnabled";

	static const Uuid _uuid = Uuid();

	/// app 啟動時呼叫一次。
	static Future<GalleryRepository> open() async {
		final Box<Object?> meta = await Hive.openBox<Object?>(_metaBoxName);
		final Box<Uint8List> images =
				await Hive.openBox<Uint8List>(_imagesBoxName);

		// 內建套
		final List<String> builtinPaths = await AssetPaths.loadBuiltinPuzzles();
		final bool builtinEnabled = (meta.get(_kBuiltinEnabled) as bool?) ?? true;
		final GallerySet builtin = GallerySet(
			id: GallerySet.builtinId,
			name: GallerySet.builtinName,
			enabled: builtinEnabled,
			builtin: true,
			assetPaths: builtinPaths,
			imageIds: const <String>[],
		);

		// 自訂套
		final List<dynamic> rawUserSets =
				(meta.get(_kUserSets) as List<dynamic>?) ?? <dynamic>[];
		final List<GallerySet> userSets = rawUserSets
				.map((dynamic raw) =>
						GallerySet.fromJson(raw as Map<dynamic, dynamic>))
				.toList();

		// 過濾掉 imageIds 中已經在 images box 找不到 bytes 的（避免顯示空圖）。
		// 同時收集要清掉的 orphan image ids。
		final Set<String> referencedIds = <String>{};
		final List<GallerySet> cleanedUserSets = <GallerySet>[];
		for (final GallerySet s in userSets) {
			final List<String> existing = s.imageIds
					.where((String id) => images.containsKey(id))
					.toList();
			referencedIds.addAll(existing);
			cleanedUserSets.add(s.copyWith(imageIds: existing));
		}

		// 清 orphan：images box 裡有、但沒有任何 set 引用的 bytes。
		final List<String> orphans = images.keys
				.cast<String>()
				.where((String k) => !referencedIds.contains(k))
				.toList();
		if (orphans.isNotEmpty) {
			await images.deleteAll(orphans);
		}

		final List<GallerySet> sets = <GallerySet>[builtin, ...cleanedUserSets];
		final GalleryRepository repo = GalleryRepository._(meta, images, sets);

		// 若 cleanup 修改了任何 set 的 imageIds，把結果寫回。
		final bool changed = cleanedUserSets.length != userSets.length ||
				cleanedUserSets.any((GallerySet s) {
					final GallerySet original = userSets.firstWhere(
						(GallerySet u) => u.id == s.id,
						orElse: () => s,
					);
					return s.imageIds.length != original.imageIds.length;
				});
		if (changed) {
			await repo._persistUserSets();
		}
		return repo;
	}

	/// 不可變視圖：內建套永遠在第一個。
	List<GallerySet> get sets => List<GallerySet>.unmodifiable(_sets);

	/// 取單一套（找不到回 null）。
	GallerySet? findById(String id) {
		for (final GallerySet s in _sets) {
			if (s.id == id) return s;
		}
		return null;
	}

	/// 啟用中的所有「圖 token」清單，供 puzzle_page 取用。
	///
	/// 內建套用 assets 路徑（"assets/..."），自訂套用 `imageId:` 前綴 + UUID。
	/// 載入端依 prefix 分流：assets → `rootBundle`、imageId → [readImageBytes]。
	List<String> enabledImageTokens() {
		final List<String> out = <String>[];
		for (final GallerySet s in _sets) {
			if (!s.enabled) continue;
			if (s.builtin) {
				out.addAll(s.assetPaths);
			} else {
				out.addAll(s.imageIds.map((String id) => "imageId:$id"));
			}
		}
		return out;
	}

	/// 依 imageId 取自訂圖 bytes。
	Uint8List? readImageBytes(String imageId) => _imagesBox.get(imageId);

	/// 切換指定套的啟用狀態。
	Future<void> setEnabled(String id, bool enabled) async {
		_sets = _sets
				.map((GallerySet s) => s.id == id ? s.copyWith(enabled: enabled) : s)
				.toList();
		if (id == GallerySet.builtinId) {
			await _metaBox.put(_kBuiltinEnabled, enabled);
		} else {
			await _persistUserSets();
		}
		notifyListeners();
	}

	/// 新增一個自訂套（空圖、預設啟用）。回傳新建立的 set。
	Future<GallerySet> createUserSet(String name) async {
		final GallerySet newSet = GallerySet(
			id: _uuid.v4(),
			name: name.trim().isEmpty ? "自訂圖庫" : name.trim(),
			enabled: true,
			builtin: false,
			assetPaths: const <String>[],
			imageIds: const <String>[],
		);
		_sets = <GallerySet>[..._sets, newSet];
		await _persistUserSets();
		notifyListeners();
		return newSet;
	}

	/// 改自訂套名稱。
	Future<void> renameUserSet(String id, String name) async {
		final String trimmed = name.trim();
		if (trimmed.isEmpty) return;
		_sets = _sets.map((GallerySet s) {
			if (s.id == id && !s.builtin) return s.copyWith(name: trimmed);
			return s;
		}).toList();
		await _persistUserSets();
		notifyListeners();
	}

	/// 刪除自訂套（連同所有圖 bytes）。
	Future<void> deleteUserSet(String id) async {
		final GallerySet? target = findById(id);
		if (target == null || target.builtin) return;
		// 先刪 images box 裡的 bytes
		if (target.imageIds.isNotEmpty) {
			await _imagesBox.deleteAll(target.imageIds);
		}
		_sets = _sets.where((GallerySet s) => s.id != id).toList();
		await _persistUserSets();
		notifyListeners();
	}

	/// 把已裁切的 JPEG bytes 寫進 images box，並登錄到該套。
	///
	/// 回傳新建立的 imageId。
	Future<String> addImageToSet(String setId, Uint8List jpegBytes) async {
		final GallerySet? target = findById(setId);
		if (target == null || target.builtin) {
			throw StateError("無法新增圖到內建/不存在的圖庫：$setId");
		}
		final String imageId = _uuid.v4();
		await _imagesBox.put(imageId, jpegBytes);
		_sets = _sets.map((GallerySet s) {
			if (s.id == setId) {
				return s.copyWith(
					imageIds: <String>[...s.imageIds, imageId],
				);
			}
			return s;
		}).toList();
		await _persistUserSets();
		notifyListeners();
		return imageId;
	}

	/// 從自訂套刪除一張或多張圖（bytes + metadata 紀錄）。
	Future<void> removeImagesFromSet(
		String setId,
		Iterable<String> imageIds,
	) async {
		final GallerySet? target = findById(setId);
		if (target == null || target.builtin) return;
		final Set<String> toRemove = imageIds.toSet();
		await _imagesBox.deleteAll(toRemove);
		_sets = _sets.map((GallerySet s) {
			if (s.id == setId) {
				return s.copyWith(
					imageIds:
							s.imageIds.where((String id) => !toRemove.contains(id)).toList(),
				);
			}
			return s;
		}).toList();
		await _persistUserSets();
		notifyListeners();
	}

	Future<void> _persistUserSets() async {
		final List<Map<String, Object?>> raw = _sets
				.where((GallerySet s) => !s.builtin)
				.map((GallerySet s) => s.toJson())
				.toList();
		try {
			await _metaBox.put(_kUserSets, raw);
		} catch (e) {
			debugPrint("GalleryRepository._persistUserSets failed: $e");
		}
	}
}
