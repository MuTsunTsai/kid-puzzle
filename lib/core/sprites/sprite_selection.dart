import "sprite_manifest.dart";

/// Sprite 類別 / 子類別「啟用」狀態判定，全 app 共用。
///
/// 持久化資料 = `Map<String, bool>`：
/// - key 形如 `"<categoryId>"` 或 `"<categoryId>/<subcategoryId>"`
/// - value `true` = 明確選取、`false` = 明確取消、**key 不存在** = 從未處理
///
/// 為什麼用 `Map<String, bool>` 而不是 `Set<String>`：要區分「明確取消」與
/// 「從未設定」兩種狀態。Set 只能表達「key 在 / 不在」 — 整類取消後 set
/// 內等於沒這個 key、與全新使用者無從區分、會被預設規則覆蓋回來。
///
/// 預設規則（**父 / 子分開獨立判定**）：
/// - 父類別未被處理 → 父預設選取
/// - 子類別**全部**未被處理 → 第一個子預設選取、其餘預設不選
///
/// 兩條規則彼此獨立：
/// - 「全新類別」= 父子都未被處理 → 父勾 + 只勾第一個子
/// - 「舊使用者遇到新切分的子分類」= 父已處理（true 或 false）+ 子全未處理 →
///   父維持 stored、子套子預設（第一個勾、其餘不勾）
/// - 「舊使用者只改過部分子分類」= 父未處理 + 子有部分處理過 → 父預設勾、
///   子部分沿用 stored、未處理的維持 false（不要再套「第一個 default」、
///   因為使用者已經明確碰過某些子、套預設會干擾意圖）
class SpriteSelection {
	const SpriteSelection._();

	/// 從 stored map 與 manifest 算出當下實際應顯示 / 可用的選取集合。
	///
	/// 回傳 `Set<String>`：被選取的 keys（父類別 id 與選取的子類別 key）。
	/// 父 / 子各自獨立判 seen / 套預設 — 詳見 class 註解。
	static Set<String> resolveSelected({
		required Map<String, bool> stored,
		required List<SpriteCategory> categories,
	}) {
		final Set<String> result = <String>{};
		for (final SpriteCategory c in categories) {
			final List<SpriteSubcategory> subs =
					c.subcategories ?? const <SpriteSubcategory>[];

			// 父：seen 就沿用、否則預設 true
			final bool parentSeen = stored.containsKey(c.id);
			final bool parentOn = parentSeen ? stored[c.id] == true : true;
			if (parentOn) result.add(c.id);

			// 子：若全部子都未 seen → 套「第一個勾、其餘不勾」預設；
			//     否則有 seen 的沿用 stored、未 seen 的維持 false（不混用預設）
			if (subs.isEmpty) continue;
			final bool anySubSeen = subs.any((SpriteSubcategory s) =>
					stored.containsKey("${c.id}/${s.id}"));
			if (!anySubSeen) {
				result.add("${c.id}/${subs.first.id}");
			} else {
				for (final SpriteSubcategory s in subs) {
					if (stored["${c.id}/${s.id}"] == true) {
						result.add("${c.id}/${s.id}");
					}
				}
			}
		}
		return result;
	}

	/// 給遊戲端用：算出某類別內「實際可用的 itemIds」。
	///
	/// 規則：
	/// - 類別父未選 → 空集合（整類不用）
	/// - 類別父選 + 無子類別 → 該類別所有 items 都可用
	/// - 類別父選 + 有子類別 → 只有「被選取的子類別」內的 items 可用；
	///   一個 item 若不屬於任何選取的子類別則排除
	///
	/// [resolved] 是 [resolveSelected] 的結果。
	static Set<String> usableItemIds(SpriteCategory c, Set<String> resolved) {
		if (!resolved.contains(c.id)) return const <String>{};
		final List<SpriteSubcategory> subs =
				c.subcategories ?? const <SpriteSubcategory>[];
		if (subs.isEmpty) {
			return <String>{for (final SpriteItem it in c.items) it.id};
		}
		final Set<String> ids = <String>{};
		for (final SpriteSubcategory s in subs) {
			if (resolved.contains("${c.id}/${s.id}")) {
				ids.addAll(s.itemIds);
			}
		}
		return ids;
	}
}
