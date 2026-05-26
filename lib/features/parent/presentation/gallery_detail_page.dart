import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:image_picker/image_picker.dart";
import "package:provider/provider.dart";

import "../../../core/constants/app_colors.dart";
import "../../../core/routing/app_router.dart";
import "../../../core/storage/gallery_repository.dart";
import "../../../shared/models/gallery_set.dart";
import "../../../shared/widgets/click_sound.dart";
import "image_crop_page.dart";

/// 圖庫詳細頁：顯示單一套裡的所有圖，可新增（自訂套）、批次刪除（自訂套）。
///
/// 進入時 `arguments` 必須是 `String`（set id）。
/// - 內建套：純瀏覽，AppBar 右上不顯示任何編輯按鈕、長按也不啟用選取模式。
/// - 自訂套：右上 ＋ 鈕（→ image_picker + 自製 ImageCropPage 4:3 裁切）；
///   長按進入選取模式，可批次刪除（會跳確認對話框）。
class GalleryDetailPage extends StatefulWidget {
	const GalleryDetailPage({super.key});

	@override
	State<GalleryDetailPage> createState() => _GalleryDetailPageState();
}

class _GalleryDetailPageState extends State<GalleryDetailPage> {
	String? _setId;
	final Set<String> _selected = <String>{};
	bool get _inSelectionMode => _selected.isNotEmpty;

	@override
	void didChangeDependencies() {
		super.didChangeDependencies();
		_setId ??= ModalRoute.of(context)?.settings.arguments as String?;
	}

	@override
	Widget build(BuildContext context) {
		final String? id = _setId;
		if (id == null) {
			return Scaffold(
				appBar: AppBar(title: const Text("圖庫")),
				body: const Center(child: Text("未指定圖庫 id")),
			);
		}
		return Consumer<GalleryRepository>(
			builder: (BuildContext context, GalleryRepository repo, _) {
				final GallerySet? set = repo.findById(id);
				if (set == null) {
					return Scaffold(
						appBar: AppBar(title: const Text("圖庫")),
						body: const Center(child: Text("找不到此圖庫")),
					);
				}
				// 用 keys（內建：assets 路徑；自訂：imageId）統一索引選取狀態。
				final List<String> keys = set.builtin
						? set.assetPaths
						: set.imageIds;
				_selected.removeWhere((String k) => !keys.contains(k));
				return _buildScaffold(context, set, keys);
			},
		);
	}

	Widget _buildScaffold(
		BuildContext context,
		GallerySet set,
		List<String> keys,
	) {
		final bool editable = !set.builtin;
		return Scaffold(
			appBar: AppBar(
				leading: _inSelectionMode
						? IconButton(
								icon: const Icon(Icons.close),
								onPressed: ClickSound.wrap(
									context,
									() => setState(_selected.clear),
								),
							)
						: null,
				title: Text(
					_inSelectionMode
							? "已選取 ${_selected.length}"
							: set.name,
				),
				backgroundColor: AppColors.primary,
				foregroundColor: Colors.white,
				actions: <Widget>[
					if (editable && _inSelectionMode)
						IconButton(
							icon: const Icon(Icons.delete),
							tooltip: "刪除已選取",
							onPressed: ClickSound.wrap(
								context,
								() => _confirmDeleteSelected(context, set.id),
							),
						),
					if (editable && !_inSelectionMode)
						IconButton(
							icon: const Icon(Icons.add_a_photo),
							tooltip: "新增圖片",
							onPressed: ClickSound.wrap(
								context,
								() => _onAddImages(context, set.id),
							),
						),
				],
			),
			body: keys.isEmpty
					? Center(
							child: Column(
								mainAxisSize: MainAxisSize.min,
								children: <Widget>[
									const Icon(
										Icons.image_outlined,
										size: 64,
										color: Colors.black26,
									),
									const SizedBox(height: 12),
									Text(
										editable ? "還沒有圖片，點右上＋新增" : "此圖庫沒有圖片",
										style: const TextStyle(color: Colors.black54),
									),
								],
							),
						)
					: GridView.builder(
							padding: const EdgeInsets.all(8),
							gridDelegate:
									const SliverGridDelegateWithFixedCrossAxisCount(
								crossAxisCount: 4,
								crossAxisSpacing: 8,
								mainAxisSpacing: 8,
								childAspectRatio: 4 / 3,
							),
							itemCount: keys.length,
							itemBuilder: (BuildContext ctx, int i) {
								final String key = keys[i];
								final bool isSelected = _selected.contains(key);
								return _Thumbnail(
									tokenKey: key,
									builtin: set.builtin,
									selected: isSelected,
									selectionMode: _inSelectionMode,
									onTap: () {
										if (editable && _inSelectionMode) {
											setState(() {
												if (isSelected) {
													_selected.remove(key);
												} else {
													_selected.add(key);
												}
											});
											return;
										}
										// 非選取模式（含內建套）→ 開大圖預覽
										_showPreview(context, keys, i, set.builtin);
									},
									onLongPress: () {
										if (!editable) return;
										setState(() {
											if (isSelected) {
												_selected.remove(key);
											} else {
												_selected.add(key);
											}
										});
									},
								);
							},
						),
		);
	}

	Future<void> _onAddImages(BuildContext context, String setId) async {
		try {
			// 1. picker 選原圖
			final ImagePicker picker = ImagePicker();
			debugPrint("[gallery] pickImage start");
			final XFile? picked =
					await picker.pickImage(source: ImageSource.gallery);
			debugPrint("[gallery] pickImage returned: ${picked?.path}");
			if (picked == null) return;
			if (!context.mounted) return;

			// 2. 讀 bytes
			final Uint8List sourceBytes = await picked.readAsBytes();
			debugPrint("[gallery] read ${sourceBytes.length} bytes");
			if (!context.mounted) return;

			// 3. 進自製裁切頁。裁切頁回傳壓縮好的 JPEG bytes（4:3、長邊 ≤ 1600）。
			// 不走 named route，因為 routes map 註冊的是 MaterialPageRoute<dynamic>,
			// 無法強轉到 MaterialPageRoute<Uint8List?> — 直接 push 一個正確泛型的 route。
			final Uint8List? cropped =
					await Navigator.of(context).push<Uint8List>(
				MaterialPageRoute<Uint8List>(
					builder: (_) => const ImageCropPage(),
					settings: RouteSettings(
						name: AppRoutes.parentImageCrop,
						arguments:
								ImageCropArguments(sourceBytes: sourceBytes),
					),
				),
			);
			debugPrint("[gallery] crop returned: ${cropped?.length} bytes");
			if (cropped == null) return;
			if (!context.mounted) return;

			// 4. 存進 repo
			await context.read<GalleryRepository>().addImageToSet(setId, cropped);
		} catch (e, st) {
			debugPrint("[gallery] _onAddImages failed: $e\n$st");
			if (context.mounted) {
				ScaffoldMessenger.of(context).showSnackBar(
					SnackBar(content: Text("匯入失敗：$e")),
				);
			}
		}
	}

	/// 全螢幕大圖預覽。
	///
	/// - 用 [PageView] 顯示整套圖，可左右滑切換
	/// - 兩側 chevron：頁面非首/尾時顯示，點擊也可切換
	/// - 點圖外背景關閉
	/// - 每張圖用 [InteractiveViewer] 包住、支援雙指縮放
	void _showPreview(
		BuildContext context,
		List<String> keys,
		int initialIndex,
		bool builtin,
	) {
		showDialog<void>(
			context: context,
			barrierColor: Colors.black87,
			builder: (BuildContext ctx) => _PreviewDialog(
				keys: keys,
				initialIndex: initialIndex,
				builtin: builtin,
				gallery: context.read<GalleryRepository>(),
			),
		);
	}

	Future<void> _confirmDeleteSelected(
		BuildContext context,
		String setId,
	) async {
		final int n = _selected.length;
		final bool ok = await showDialog<bool>(
					context: context,
					builder: (BuildContext ctx) => AlertDialog(
						title: const Text("刪除已選取？"),
						content: Text("確定要刪除 $n 張圖片嗎？此操作無法復原。"),
						actions: <Widget>[
							TextButton(
								onPressed: ClickSound.wrap(
									ctx,
									() => Navigator.of(ctx).pop(false),
								),
								child: const Text("取消"),
							),
							ElevatedButton(
								onPressed: ClickSound.wrap(
									ctx,
									() => Navigator.of(ctx).pop(true),
								),
								style: ElevatedButton.styleFrom(
									backgroundColor: Colors.red,
									foregroundColor: Colors.white,
								),
								child: const Text("刪除"),
							),
						],
					),
				) ??
				false;
		if (!ok) return;
		if (!context.mounted) return;
		final List<String> toRemove = _selected.toList();
		setState(_selected.clear);
		await context.read<GalleryRepository>().removeImagesFromSet(
					setId,
					toRemove,
				);
	}
}

/// 大圖預覽 dialog：PageView 切換、兩側 chevron、可縮放、點背景關閉。
class _PreviewDialog extends StatefulWidget {
	const _PreviewDialog({
		required this.keys,
		required this.initialIndex,
		required this.builtin,
		required this.gallery,
	});

	final List<String> keys;
	final int initialIndex;
	final bool builtin;
	final GalleryRepository gallery;

	@override
	State<_PreviewDialog> createState() => _PreviewDialogState();
}

class _PreviewDialogState extends State<_PreviewDialog> {
	late final PageController _controller;
	late int _currentIndex;

	@override
	void initState() {
		super.initState();
		_currentIndex = widget.initialIndex;
		_controller = PageController(initialPage: widget.initialIndex);
	}

	@override
	void dispose() {
		_controller.dispose();
		super.dispose();
	}

	void _goPrev() {
		if (_currentIndex <= 0) return;
		_controller.previousPage(
			duration: const Duration(milliseconds: 250),
			curve: Curves.easeOut,
		);
	}

	void _goNext() {
		if (_currentIndex >= widget.keys.length - 1) return;
		_controller.nextPage(
			duration: const Duration(milliseconds: 250),
			curve: Curves.easeOut,
		);
	}

	Widget _buildImage(String tokenKey) {
		if (widget.builtin) {
			return Image.asset(tokenKey, fit: BoxFit.contain);
		}
		final Uint8List? bytes = widget.gallery.readImageBytes(tokenKey);
		if (bytes == null) return const SizedBox.shrink();
		return Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true);
	}

	@override
	Widget build(BuildContext context) {
		final bool hasPrev = _currentIndex > 0;
		final bool hasNext = _currentIndex < widget.keys.length - 1;
		return Stack(
			children: <Widget>[
				// PageView：左右滑切換。每頁是一張置中顯示的圖。
				// 關閉操作交給右上角 X 鈕，UI 職責清楚。
				Positioned.fill(
					child: PageView.builder(
						controller: _controller,
						itemCount: widget.keys.length,
						onPageChanged: (int i) => setState(() => _currentIndex = i),
						itemBuilder: (BuildContext ctx, int i) {
							return Center(child: _buildImage(widget.keys[i]));
						},
					),
				),
				// 右上角關閉鈕
				Positioned(
					top: 12,
					right: 12,
					child: Material(
						color: Colors.black54,
						shape: const CircleBorder(),
						child: InkWell(
							customBorder: const CircleBorder(),
							onTap: ClickSound.wrap(
								context,
								() => Navigator.of(context).pop(),
							),
							child: const Padding(
								padding: EdgeInsets.all(8),
								child: Icon(Icons.close, color: Colors.white, size: 28),
							),
						),
					),
				),
				// 左側 chevron
				if (hasPrev)
					Positioned(
						left: 8,
						top: 0,
						bottom: 0,
						child: Center(
							child: _ChevronButton(
								icon: Icons.chevron_left,
								onPressed: _goPrev,
							),
						),
					),
				// 右側 chevron
				if (hasNext)
					Positioned(
						right: 8,
						top: 0,
						bottom: 0,
						child: Center(
							child: _ChevronButton(
								icon: Icons.chevron_right,
								onPressed: _goNext,
							),
						),
					),
			],
		);
	}
}

class _ChevronButton extends StatelessWidget {
	const _ChevronButton({required this.icon, required this.onPressed});

	final IconData icon;
	final VoidCallback onPressed;

	@override
	Widget build(BuildContext context) {
		return Material(
			color: Colors.black54,
			shape: const CircleBorder(),
			child: InkWell(
				customBorder: const CircleBorder(),
				onTap: ClickSound.wrap(context, onPressed),
				child: Padding(
					padding: const EdgeInsets.all(8),
					child: Icon(icon, color: Colors.white, size: 28),
				),
			),
		);
	}
}

class _Thumbnail extends StatelessWidget {
	const _Thumbnail({
		required this.tokenKey,
		required this.builtin,
		required this.selected,
		required this.selectionMode,
		required this.onTap,
		required this.onLongPress,
	});

	/// 內建：assets 路徑。自訂：imageId。
	final String tokenKey;
	final bool builtin;
	final bool selected;
	final bool selectionMode;
	final VoidCallback onTap;
	final VoidCallback onLongPress;

	@override
	Widget build(BuildContext context) {
		Widget imageWidget;
		if (builtin) {
			imageWidget = Image.asset(tokenKey, fit: BoxFit.cover);
		} else {
			final Uint8List? bytes =
					context.read<GalleryRepository>().readImageBytes(tokenKey);
			imageWidget = bytes == null
					? Container(color: Colors.black12)
					: Image.memory(
							bytes,
							fit: BoxFit.cover,
							gaplessPlayback: true,
						);
		}
		return GestureDetector(
			onTap: ClickSound.wrap(context, onTap),
			onLongPress: onLongPress,
			child: Stack(
				fit: StackFit.expand,
				children: <Widget>[
					ClipRRect(
						borderRadius: BorderRadius.circular(8),
						child: imageWidget,
					),
					if (selectionMode)
						Positioned(
							top: 4,
							left: 4,
							child: Container(
								decoration: BoxDecoration(
									shape: BoxShape.circle,
									color: selected ? AppColors.primary : Colors.white70,
									border: Border.all(color: Colors.white, width: 2),
								),
								width: 24,
								height: 24,
								child: selected
										? const Icon(Icons.check,
												color: Colors.white, size: 16)
										: null,
							),
						),
					if (selected)
						Container(
							decoration: BoxDecoration(
								borderRadius: BorderRadius.circular(8),
								color: AppColors.primary.withValues(alpha: 0.25),
							),
						),
				],
			),
		);
	}
}
