/// Sprite 圖庫的 metadata 模型。
///
/// 對應 `assets/data/sprites.json`，由姊妹專案 kid-puzzle-sprite build 出。
/// 整份 manifest 涵蓋所有類別的物件清單與 sheet 規格。
///
/// 結構：
/// - [SpriteManifest]
///   - [SpriteCategory] × N
///     - [SpriteSheet]（每個類別恆為**一張**）
///     - [SpriteItem] × K（物件依 list 順序就決定 sheet 上格子位置）
///
/// 重要 schema 改變（vs 舊版）：
/// - [SpriteItem] 不再帶 `sheet/row/col`：runtime 用該 item 在
///   [SpriteCategory.items] 內的 index 算 grid 位置（`row = i ~/ 6`、
///   `col = i % 6`）
/// - [SpriteCategory] 不再帶 `voiceFile`：語音 zip 路徑由 convention 算
///   （`audio/sprites/<categoryId>.zip`），sprite sheet 路徑同理（從
///   [SpriteSheet.file] 取）
/// - 輸入 JSON 仍是 `sheets: [...]` 陣列以便將來擴充，但 model 在 fromJson
///   時就取 first、對外曝露單一 [SpriteCategory.sheet]
class SpriteManifest {
	const SpriteManifest({
		required this.version,
		required this.categories,
	});

	final int version;
	final List<SpriteCategory> categories;

	static SpriteManifest fromJson(Map<String, dynamic> json) {
		return SpriteManifest(
			version: (json["version"] as num).toInt(),
			categories: (json["categories"] as List<dynamic>)
					.map((dynamic e) =>
							SpriteCategory.fromJson(e as Map<String, dynamic>))
					.toList(),
		);
	}
}

class SpriteCategory {
	const SpriteCategory({
		required this.id,
		required this.name,
		required this.sheet,
		required this.items,
		this.voiceRev,
		this.subcategories,
	});

	/// 類別程式碼，例如 "animals"。也是 sprite sheet webp / 語音 zip 的
	/// 檔名根（`images/sprites/<id>.webp`、`audio/sprites/<id>.zip`）。
	final String id;

	/// 顯示用中文名稱，例如「動物」。
	final String name;

	/// 該類別的 sprite sheet（一律單張）。
	final SpriteSheet sheet;

	final List<SpriteItem> items;

	/// 語音 zip 的版本 hash（由 kid-puzzle-sprite build 期算出）。
	/// 給 web 載入時加 `?rev=<voiceRev>` query 用，行動平台忽略。
	/// 舊 manifest 沒有此欄位時為 null、runtime 自動退回不帶 rev 的載入。
	final String? voiceRev;

	/// 子類別清單（optional）；只是分組視圖、用 [SpriteSubcategory.itemIds]
	/// 引用 [items] 內既有的物件，不重複資料。
	///
	/// 例如「英文字母」可以分成「大寫」「小寫」兩組；單層類別（動物、水果）
	/// 直接 null 即可。
	final List<SpriteSubcategory>? subcategories;

	/// 依 [item] 在 [items] 內的 index 算出它在 sheet 上的格子位置。
	/// 找不到時回傳 null。
	///
	/// sheet 恆為 0（永遠單張）、cols 恆為 6、rows = `ceil(items.length / 6)`。
	({int sheet, int row, int col})? gridOf(SpriteItem item) {
		final int i = items.indexWhere((SpriteItem it) => it.id == item.id);
		if (i < 0) return null;
		return (sheet: 0, row: i ~/ 6, col: i % 6);
	}

	static SpriteCategory fromJson(Map<String, dynamic> json) {
		final List<dynamic>? subs = json["subcategories"] as List<dynamic>?;
		final List<dynamic> sheetsJson = json["sheets"] as List<dynamic>;
		return SpriteCategory(
			id: json["id"] as String,
			name: json["name"] as String,
			sheet: SpriteSheet.fromJson(sheetsJson.first as Map<String, dynamic>),
			items: (json["items"] as List<dynamic>)
					.map((dynamic e) => SpriteItem.fromJson(e as Map<String, dynamic>))
					.toList(),
			voiceRev: json["voiceRev"] as String?,
			subcategories: subs
					?.map((dynamic e) =>
							SpriteSubcategory.fromJson(e as Map<String, dynamic>))
					.toList(),
		);
	}
}

/// 子類別：類別內的分組視圖，用 [itemIds] 引用 [SpriteCategory.items] 內既有
/// 的物件。同一 item 可被多個 subcategory 引用（雖然典型用例不會這樣）。
class SpriteSubcategory {
	const SpriteSubcategory({
		required this.id,
		required this.name,
		required this.itemIds,
	});

	/// 子類別程式碼，例如 "uppercase"。
	final String id;

	/// 顯示用中文名稱，例如「大寫」。
	final String name;

	/// 屬於此子類別的物件 id 清單；對應到 [SpriteCategory.items] 內 [SpriteItem.id]。
	final List<String> itemIds;

	static SpriteSubcategory fromJson(Map<String, dynamic> json) {
		return SpriteSubcategory(
			id: json["id"] as String,
			name: json["name"] as String,
			itemIds: (json["itemIds"] as List<dynamic>)
					.map((dynamic e) => e as String)
					.toList(),
		);
	}
}

class SpriteSheet {
	const SpriteSheet({
		required this.file,
		required this.rows,
		required this.cols,
		required this.tile,
		this.rev,
	});

	/// asset 路徑（相對 assets/ 根），例如 "images/sprites/animals.webp"。
	final String file;

	/// 切割行數（直向格子數）。
	final int rows;

	/// 切割列數（橫向格子數）。預設 6。
	final int cols;

	/// 每格邊長（px）；預設 340（先沿用舊值，未來可在 build 端配置）。
	final int tile;

	/// 該 sheet 檔案的版本 hash（由 kid-puzzle-sprite build 期算出）。
	/// 給 web 載入時加 `?rev=<rev>` query 用，行動平台忽略。
	/// 舊 manifest 沒有此欄位時為 null、runtime 自動退回不帶 rev 的載入。
	final String? rev;

	static SpriteSheet fromJson(Map<String, dynamic> json) {
		return SpriteSheet(
			file: json["file"] as String,
			rows: (json["rows"] as num).toInt(),
			cols: (json["cols"] as num).toInt(),
			tile: (json["tile"] as num).toInt(),
			rev: json["rev"] as String?,
		);
	}
}

class SpriteItem {
	const SpriteItem({
		required this.id,
		required this.name,
	});

	/// 全域唯一 id（不只類別內唯一），方便跨類別遊戲（記憶、連連看）
	/// 用一組 id list 直接取。也是語音 zip 內的 entry 名（`<id>.mp3`）。
	final String id;

	/// 顯示與語音文字內容，例如「貓咪」。
	final String name;

	static SpriteItem fromJson(Map<String, dynamic> json) {
		return SpriteItem(
			id: json["id"] as String,
			name: json["name"] as String,
		);
	}
}
