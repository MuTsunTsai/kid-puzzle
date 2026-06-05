import "dart:ui" as ui;

import "package:flutter/material.dart";
import "package:provider/provider.dart";

import "../../../core/audio/audio_service.dart";
import "../../../core/constants/app_colors.dart";
import "../../../core/constants/ui_strings.dart";
import "../../../core/sprites/sprite_manifest.dart";
import "../../../core/sprites/sprite_registry.dart";
import "../../../shared/widgets/click_sound.dart";

/// 素材詳情頁：列出某分類所有物件 grid、點擊播語音。
///
/// route arguments：分類 id（String）。
class SpritesDetailPage extends StatefulWidget {
	const SpritesDetailPage({super.key});

	@override
	State<SpritesDetailPage> createState() => _SpritesDetailPageState();
}

class _SpritesDetailPageState extends State<SpritesDetailPage> {
	String? _categoryId;
	bool _bootstrapped = false;

	@override
	void didChangeDependencies() {
		super.didChangeDependencies();
		if (_bootstrapped) return;
		_bootstrapped = true;
		final Object? args = ModalRoute.of(context)?.settings.arguments;
		_categoryId = args is String ? args : null;
		final SpriteRegistry reg = context.read<SpriteRegistry>();
		final SpriteCategory? cat = _categoryId == null
				? null
				: reg.categoryById(_categoryId!);
		if (cat != null) {
			// 預載 sheet bitmap + voice zip，給 grid 立刻畫 + 立刻播。
			// 用 unawaited + try/catch 確保任一邊失敗也會 setState（避免
			// 卡 spinner 不變圖），同時把錯誤吐到 console 便於 debug。
			() async {
				try {
					await reg.preloadCategory(cat);
				} catch (e, st) {
					debugPrint("preloadCategory(${cat.id}) failed: $e\n$st");
				}
				if (mounted) setState(() {});
			}();
		}
	}

	void _onTapItem(SpriteRegistry reg, SpriteCategory cat, SpriteItem item) {
		if (reg.hasNameVoice(item)) {
			reg.playName(item);
		} else {
			// 沒設語音 → 播 snap 音效作回饋
			try {
				context.read<AudioService>().play(SfxKind.snap);
			} catch (_) {}
		}
	}

	@override
	Widget build(BuildContext context) {
		final SpriteRegistry reg = context.read<SpriteRegistry>();
		final SpriteCategory? cat = _categoryId == null
				? null
				: reg.categoryById(_categoryId!);
		return Scaffold(
			appBar: AppBar(
				title: Text(cat?.name ?? ParentStrings.spritesDetailTitle),
				backgroundColor: AppColors.primary,
				foregroundColor: Colors.white,
			),
			body: cat == null
					? const Center(child: Text("找不到此分類"))
					: _buildBody(cat, reg),
		);
	}

	Widget _buildBody(SpriteCategory cat, SpriteRegistry reg) {
		final List<SpriteSubcategory> subs =
				cat.subcategories ?? const <SpriteSubcategory>[];
		// 無子分類：扁平 grid（沿用原行為）
		if (subs.isEmpty) {
			return GridView.builder(
				padding: const EdgeInsets.all(8),
				gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
					maxCrossAxisExtent: 120,
					mainAxisSpacing: 8,
					crossAxisSpacing: 8,
					childAspectRatio: 0.85,
				),
				itemCount: cat.items.length,
				itemBuilder: (BuildContext ctx, int i) =>
						_tileFor(cat, cat.items[i], reg),
			);
		}

		// 有子分類：每個子分類一個 section（小標題 + grid）。
		// 不屬於任何子分類的物件放最後的「其它」section（若有）。
		final Map<String, SpriteItem> byId = <String, SpriteItem>{
			for (final SpriteItem it in cat.items) it.id: it,
		};
		final Set<String> claimed = <String>{};
		final List<({String title, List<SpriteItem> items})> sections =
				<({String title, List<SpriteItem> items})>[];
		for (final SpriteSubcategory s in subs) {
			final List<SpriteItem> items = <SpriteItem>[];
			for (final String id in s.itemIds) {
				final SpriteItem? it = byId[id];
				if (it != null) {
					items.add(it);
					claimed.add(id);
				}
			}
			if (items.isNotEmpty) sections.add((title: s.name, items: items));
		}
		final List<SpriteItem> others = <SpriteItem>[
			for (final SpriteItem it in cat.items)
				if (!claimed.contains(it.id)) it,
		];
		if (others.isNotEmpty) {
			sections.add((title: "其它", items: others));
		}

		return CustomScrollView(
			slivers: <Widget>[
				for (final ({String title, List<SpriteItem> items}) sec in sections) ...<Widget>[
					SliverToBoxAdapter(child: _SectionHeader(text: sec.title)),
					SliverPadding(
						padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
						sliver: SliverGrid(
							gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
								maxCrossAxisExtent: 120,
								mainAxisSpacing: 8,
								crossAxisSpacing: 8,
								childAspectRatio: 0.85,
							),
							delegate: SliverChildBuilderDelegate(
								(BuildContext ctx, int i) => _tileFor(cat, sec.items[i], reg),
								childCount: sec.items.length,
							),
						),
					),
				],
			],
		);
	}

	Widget _tileFor(SpriteCategory cat, SpriteItem item, SpriteRegistry reg) {
		return _SpriteTile(
			category: cat,
			item: item,
			registry: reg,
			onTap: ClickSound.wrap(
				context,
				() => _onTapItem(reg, cat, item),
			),
		);
	}
}

class _SectionHeader extends StatelessWidget {
	const _SectionHeader({required this.text});

	final String text;

	@override
	Widget build(BuildContext context) {
		return Padding(
			padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
			child: Text(
				text,
				style: const TextStyle(
					fontSize: 14,
					fontWeight: FontWeight.bold,
					color: AppColors.primary,
				),
			),
		);
	}
}

class _SpriteTile extends StatelessWidget {
	const _SpriteTile({
		required this.category,
		required this.item,
		required this.registry,
		required this.onTap,
	});

	final SpriteCategory category;
	final SpriteItem item;
	final SpriteRegistry registry;
	final VoidCallback? onTap;

	@override
	Widget build(BuildContext context) {
		final SpriteSheet sheet = category.sheet;
		final ({int sheet, int row, int col})? g = category.gridOf(item);
		final ui.Image? img = registry.atlas.cachedImage(sheet.file);
		final bool hasVoice = registry.hasNameVoice(item);
		return Material(
			color: Colors.white,
			borderRadius: BorderRadius.circular(8),
			elevation: 1,
			child: InkWell(
				borderRadius: BorderRadius.circular(8),
				onTap: onTap,
				child: Column(
					children: <Widget>[
						Expanded(
							child: Padding(
								padding: const EdgeInsets.all(6),
								child: img == null || g == null
										? const Center(child: SizedBox(
												width: 16, height: 16,
												child: CircularProgressIndicator(strokeWidth: 2),
											))
										: CustomPaint(
												painter: _SpritePainter(
													image: img,
													srcRect: ui.Rect.fromLTWH(
														g.col * sheet.tile.toDouble(),
														g.row * sheet.tile.toDouble(),
														sheet.tile.toDouble(),
														sheet.tile.toDouble(),
													),
												),
												child: const SizedBox.expand(),
											),
							),
						),
						Padding(
							padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
							child: Row(
								mainAxisAlignment: MainAxisAlignment.center,
								children: <Widget>[
									Flexible(
										child: Text(
											item.name,
											style: const TextStyle(fontSize: 12),
											overflow: TextOverflow.ellipsis,
										),
									),
									if (hasVoice) ...<Widget>[
										const SizedBox(width: 4),
										Icon(Icons.volume_up,
												size: 12, color: Colors.grey.shade600),
									],
								],
							),
						),
					],
				),
			),
		);
	}
}

class _SpritePainter extends CustomPainter {
	_SpritePainter({required this.image, required this.srcRect});
	final ui.Image image;
	final ui.Rect srcRect;

	@override
	void paint(Canvas canvas, Size size) {
		final double side = size.shortestSide;
		final ui.Rect dst = ui.Rect.fromCenter(
			center: ui.Offset(size.width / 2, size.height / 2),
			width: side,
			height: side,
		);
		canvas.drawImageRect(
			image, srcRect, dst,
			Paint()..filterQuality = FilterQuality.medium,
		);
	}

	@override
	bool shouldRepaint(covariant _SpritePainter old) =>
			old.image != image || old.srcRect != srcRect;
}
