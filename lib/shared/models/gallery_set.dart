/// 圖庫套組資料模型。
///
/// 整個 App 的圖庫以「套」為單位管理；每套包含若干張圖、可啟用/停用。
///
/// - **內建套（builtin）**：[id] 固定為 [GallerySet.builtinId]、不可刪、不可改名、
///   不可新增/刪除圖；但可以切換 [enabled]。圖以 assets 路徑表示，存在
///   [assetPaths]，由 `AssetPaths.loadBuiltinPuzzles()` runtime 掃出。
/// - **自訂套（user）**：使用者新增；可改名、刪整套、新增/刪除圖。每張圖
///   只記錄一個 UUID（存在 [imageIds]），實際 bytes 存在獨立 Hive box
///   `gallery_images`，由 [GalleryRepository] 讀寫。這樣 web/Android/iOS
///   都用同一份儲存格式，不需要 path_provider。
class GallerySet {
	const GallerySet({
		required this.id,
		required this.name,
		required this.enabled,
		required this.builtin,
		required this.assetPaths,
		required this.imageIds,
	});

	/// 內建套的固定 id。
	static const String builtinId = "builtin";

	/// 內建套的顯示名稱。
	static const String builtinName = "動物圖鑑";

	final String id;
	final String name;
	final bool enabled;
	final bool builtin;

	/// 內建套：assets 路徑（"assets/images/puzzles/xxx.jpg"）。
	final List<String> assetPaths;

	/// 自訂套：圖片 UUID 清單；對應的 bytes 在 `gallery_images` box 裡。
	final List<String> imageIds;

	/// 「這套有多少張圖」的統一視圖。
	int get imageCount => builtin ? assetPaths.length : imageIds.length;

	GallerySet copyWith({
		String? name,
		bool? enabled,
		List<String>? assetPaths,
		List<String>? imageIds,
	}) {
		return GallerySet(
			id: id,
			name: name ?? this.name,
			enabled: enabled ?? this.enabled,
			builtin: builtin,
			assetPaths: assetPaths ?? this.assetPaths,
			imageIds: imageIds ?? this.imageIds,
		);
	}

	/// 自訂套 → Hive 儲存用的 map（內建套不存）。
	Map<String, Object?> toJson() {
		assert(!builtin, "builtin set should not be serialized");
		return <String, Object?>{
			"id": id,
			"name": name,
			"enabled": enabled,
			"imageIds": imageIds,
		};
	}

	/// 從 Hive 還原一個自訂套。
	static GallerySet fromJson(Map<dynamic, dynamic> json) {
		return GallerySet(
			id: json["id"] as String,
			name: json["name"] as String,
			enabled: (json["enabled"] as bool?) ?? true,
			builtin: false,
			assetPaths: const <String>[],
			imageIds: (json["imageIds"] as List<dynamic>?)
							?.map((dynamic e) => e as String)
							.toList() ??
					<String>[],
		);
	}
}
