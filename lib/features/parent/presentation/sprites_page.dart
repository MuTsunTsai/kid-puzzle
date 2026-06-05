import "package:flutter/material.dart";
import "package:provider/provider.dart";

import "../../../core/constants/app_colors.dart";
import "../../../core/constants/ui_strings.dart";
import "../../../core/routing/app_router.dart";
import "../../../core/sprites/sprite_manifest.dart";
import "../../../core/sprites/sprite_registry.dart";
import "../../../core/sprites/sprite_selection.dart";
import "../../../core/storage/settings_repository.dart";
import "../../../shared/widgets/click_sound.dart";

/// 素材管理頁：列出全部 sprite 分類，可勾選決定遊戲中要用哪些。
///
/// - 一個分類一個 CheckboxListTile
/// - 有子類別的分類在父類下方顯示縮排子列；父類未勾時子列隱藏
/// - 點分類本體（不是 checkbox）進子頁預覽 / 試聽
class SpritesPage extends StatefulWidget {
	const SpritesPage({super.key});

	@override
	State<SpritesPage> createState() => _SpritesPageState();
}

class _SpritesPageState extends State<SpritesPage> {
	/// 「view state」：當下被勾選的 keys。從 [_stored] + 預設規則展開而來、
	/// 給 build 直接 contains 判斷用。
	late Set<String> _selected;

	/// 「persist state」：使用者**明確設過**的 key → bool 紀錄。
	/// key 不在 map 中 = 從未設定（套預設）；對應 false = 明確取消。
	/// 每次 toggle 都會更新並 persist。
	late Map<String, bool> _stored;

	bool _loaded = false;

	@override
	void didChangeDependencies() {
		super.didChangeDependencies();
		if (_loaded) return;
		_loaded = true;
		final SettingsRepository repo = context.read<SettingsRepository>();
		final SpriteRegistry reg = context.read<SpriteRegistry>();
		_stored = Map<String, bool>.from(repo.spriteSelections);
		_selected = SpriteSelection.resolveSelected(
			stored: _stored,
			categories: reg.categories,
		);
	}

	void _persist() {
		context.read<SettingsRepository>().setSpriteSelections(_stored);
	}

	bool _isCategoryOn(SpriteCategory c) => _selected.contains(c.id);
	bool _isSubOn(SpriteCategory c, SpriteSubcategory s) =>
			_selected.contains("${c.id}/${s.id}");

	void _toggleCategory(SpriteCategory c, bool v) {
		// 父子獨立：toggle 父**不**動子的 stored / view state。
		// 子的勾選記憶在父關閉時保留、父重新打開時直接維持。
		// UI 上「父未勾 → 子隱藏」這條由 build 處理（_isCategoryOn 為 false
		// 時不渲染子 list），所以子留在 _selected 內也不會視覺殘留。
		setState(() {
			_stored[c.id] = v;
			if (v) {
				_selected.add(c.id);
			} else {
				_selected.remove(c.id);
			}
		});
		_persist();
	}

	void _toggleSub(SpriteCategory c, SpriteSubcategory s, bool v) {
		final String key = "${c.id}/${s.id}";
		final List<SpriteSubcategory> subs =
				c.subcategories ?? const <SpriteSubcategory>[];
		setState(() {
			// 固化「目前看到的子選取狀態」到 stored、再 toggle 本次動到的這個。
			//
			// 動機：使用者第一次動某類別下的子時，view state（_selected）裡的
			// 「第一個子勾」是 [SpriteSelection.resolveSelected] 套預設規則（全未
			// seen → 第一個勾）給出來的、並沒有寫進 _stored。若這時直接寫
			// `_stored[key2] = true`，下次 resolve 看到「有 sub 被 seen」就走
			// else 分支「未 seen 維持 false」、原本預設勾的第一個子就消失了。
			//
			// 修法：toggle sub 前先把當下 view state 對該類別**所有子**的選/不選
			// 固化進 _stored，預設規則就不會再被觸發、view state 與 persist state
			// 對齊。
			for (final SpriteSubcategory other in subs) {
				final String otherKey = "${c.id}/${other.id}";
				_stored.putIfAbsent(otherKey, () => _selected.contains(otherKey));
			}
			_stored[key] = v;
			if (v) {
				_selected.add(key);
			} else {
				_selected.remove(key);
			}
		});
		_persist();
	}

	@override
	Widget build(BuildContext context) {
		final SpriteRegistry reg = context.read<SpriteRegistry>();
		final List<SpriteCategory> categories = reg.categories;
		return Scaffold(
			appBar: AppBar(
				title: const Text(ParentStrings.sprites),
				backgroundColor: AppColors.primary,
				foregroundColor: Colors.white,
			),
			body: Center(
				child: ConstrainedBox(
					constraints: const BoxConstraints(maxWidth: 480),
					child: ListView(
						padding: const EdgeInsets.symmetric(vertical: 8),
						children: <Widget>[
							if (_selected.isEmpty)
								Padding(
									padding: const EdgeInsets.all(16),
									child: Text(
										ParentStrings.spritesNoneSelected,
										style: TextStyle(color: Colors.orange.shade900),
									),
								),
							for (final SpriteCategory c in categories) ..._buildCategory(c),
						],
					),
				),
			),
		);
	}

	List<Widget> _buildCategory(SpriteCategory c) {
		final bool on = _isCategoryOn(c);
		final List<SpriteSubcategory> subs =
				c.subcategories ?? const <SpriteSubcategory>[];
		return <Widget>[
			CheckboxListTile(
				value: on,
				onChanged: (bool? v) => _toggleCategory(c, v ?? false),
				title: Text(c.name),
				subtitle: Text(
					subs.isEmpty
							? "${c.items.length} 個物件"
							: "${c.items.length} 個物件 · ${subs.length} 個子類別",
				),
				secondary: IconButton(
					icon: const Icon(Icons.chevron_right),
					onPressed: ClickSound.wrap(context, () {
						Navigator.of(context).pushNamed(
							AppRoutes.parentSpritesDetail,
							arguments: c.id,
						);
					}),
				),
				controlAffinity: ListTileControlAffinity.leading,
			),
			if (on && subs.isNotEmpty)
				for (final SpriteSubcategory s in subs)
					Padding(
						padding: const EdgeInsets.only(left: 32),
						child: CheckboxListTile(
							value: _isSubOn(c, s),
							onChanged: (bool? v) => _toggleSub(c, s, v ?? false),
							title: Text(s.name),
							subtitle: Text("${s.itemIds.length} 個物件"),
							dense: true,
							controlAffinity: ListTileControlAffinity.leading,
						),
					),
			const Divider(height: 1),
		];
	}
}
