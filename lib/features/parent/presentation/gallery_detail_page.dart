import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:image_picker/image_picker.dart";
import "package:provider/provider.dart";

import "../../../core/constants/app_colors.dart";
import "../../../core/constants/ui_strings.dart";
import "../../../core/network/background_asset_cache.dart";
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
				appBar: AppBar(title: const Text(GalleryDetailStrings.title)),
				body: const Center(child: Text(GalleryDetailStrings.missingId)),
			);
		}
		return Consumer<GalleryRepository>(
			builder: (BuildContext context, GalleryRepository repo, _) {
				final GallerySet? set = repo.findById(id);
				if (set == null) {
					return Scaffold(
						appBar: AppBar(title: const Text(GalleryDetailStrings.title)),
						body: const Center(child: Text(GalleryDetailStrings.notFound)),
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
							? "${GalleryDetailStrings.selected} ${_selected.length}"
							: set.name,
				),
				backgroundColor: AppColors.primary,
				foregroundColor: Colors.white,
				actions: <Widget>[
					if (editable && _inSelectionMode)
						IconButton(
							icon: const Icon(Icons.delete),
							tooltip: GalleryDetailStrings.deleteSelected,
							onPressed: ClickSound.wrap(
								context,
								() => _confirmDeleteSelected(context, set.id),
							),
						),
					if (editable && !_inSelectionMode)
						IconButton(
							icon: const Icon(Icons.add_a_photo),
							tooltip: GalleryDetailStrings.addImage,
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
										editable
												? GalleryDetailStrings.emptyHint
												: GalleryDetailStrings.emptyTitle,
										style: const TextStyle(color: Colors.black54),
									),
								],
							),
						)
					: Consumer<BackgroundAssetCache>(
							builder: (BuildContext ctx, BackgroundAssetCache cache, _) {
								return GridView.builder(
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
										// 內建 + 斷網 + 未下載 → placeholder、不可預覽
										final bool unavailable = set.builtin &&
												!cache.isOnline &&
												!cache.isCached(key);
										return _Thumbnail(
											tokenKey: key,
											builtin: set.builtin,
											selected: isSelected,
											selectionMode: _inSelectionMode,
											unavailable: unavailable,
											onTap: () {
												if (unavailable) return;
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
												_showPreview(context, keys, i, set.builtin, cache);
											},
											onLongPress: () {
												if (unavailable) return;
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
								);
							},
						),
		);
	}

	Future<void> _onAddImages(BuildContext context, String setId) async {
		try {
			// 1. picker：一次選多張
			final ImagePicker picker = ImagePicker();
			debugPrint("[gallery] pickMultiImage start");
			final List<XFile> picked = await picker.pickMultiImage();
			debugPrint("[gallery] pickMultiImage returned ${picked.length} file(s)");
			if (picked.isEmpty) return;
			if (!context.mounted) return;

			final int total = picked.length;
			int saved = 0;
			int skipped = 0;
			bool aborted = false;

			// 2. 對每張依序：讀 bytes → 推進裁切頁 → 看結果
			for (int i = 0; i < picked.length; i++) {
				if (!context.mounted) return;
				final XFile file = picked[i];
				final Uint8List sourceBytes;
				try {
					sourceBytes = await file.readAsBytes();
				} catch (e) {
					debugPrint("[gallery] readAsBytes failed for ${file.path}: $e");
					skipped++;
					continue;
				}
				if (!context.mounted) return;

				final CropPageResult? result =
						await Navigator.of(context).push<CropPageResult>(
					MaterialPageRoute<CropPageResult>(
						builder: (_) => const ImageCropPage(),
						settings: RouteSettings(
							name: AppRoutes.parentImageCrop,
							arguments: ImageCropArguments(
								sourceBytes: sourceBytes,
								batchInfo: total > 1
										? ImageCropBatchInfo(
												indexFromOne: i + 1,
												total: total,
											)
										: null,
							),
						),
					),
				);
				if (!context.mounted) return;
				if (result == null || result.isSkipped) {
					// 系統返回 = 跳過這張、繼續下一張
					skipped++;
					continue;
				}
				if (result.isAborted) {
					// 左下「停止匯入」鈕 → 中止整個流程
					aborted = true;
					break;
				}
				final Uint8List? bytes = result.bytes;
				if (bytes == null) {
					skipped++;
					continue;
				}
				await context.read<GalleryRepository>().addImageToSet(setId, bytes);
				saved++;
			}

			if (!context.mounted) return;
			if (total > 1 || aborted) {
				final String msg = aborted
						? "${GalleryDetailStrings.batchAbortedPrefix}$saved"
								"${GalleryDetailStrings.batchSavedSuffix}"
						: "${GalleryDetailStrings.batchDonePrefix}$saved"
								"${GalleryDetailStrings.batchSavedSuffix}"
								"${skipped > 0 ? "${GalleryDetailStrings.batchSkippedSeparator}$skipped${GalleryDetailStrings.batchSkippedSuffix}" : ""}";
				ScaffoldMessenger.of(context).showSnackBar(
					SnackBar(content: Text(msg)),
				);
			}
		} catch (e, st) {
			debugPrint("[gallery] _onAddImages failed: $e\n$st");
			if (context.mounted) {
				ScaffoldMessenger.of(context).showSnackBar(
					SnackBar(content: Text("${GalleryDetailStrings.importFailed}$e")),
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
		BackgroundAssetCache cache,
	) {
		// 內建套且斷網時，把「未下載」的圖從預覽序列排除（chevron 與 PageView
		// 都不該看到它們）。自訂套不受影響。
		final List<String> visible = builtin && !cache.isOnline
				? <String>[
						for (final String k in keys)
							if (cache.isCached(k)) k,
					]
				: keys;
		if (visible.isEmpty) return; // 理論上呼叫端已擋掉（unavailable 不能點）
		final String origKey = keys[initialIndex];
		final int mappedIndex = visible.indexOf(origKey).clamp(0, visible.length - 1);
		showDialog<void>(
			context: context,
			barrierColor: Colors.black87,
			builder: (BuildContext ctx) => _PreviewDialog(
				keys: visible,
				initialIndex: mappedIndex,
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
						title: const Text(GalleryDetailStrings.deletePrompt),
						content: Text(
							"${GalleryDetailStrings.deleteDesc1}$n"
							"${GalleryDetailStrings.deleteDesc2}",
						),
						actions: <Widget>[
							TextButton(
								onPressed: ClickSound.wrap(
									ctx,
									() => Navigator.of(ctx).pop(false),
								),
								child: const Text(GalleryStrings.cancel),
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
								child: const Text(GalleryDetailStrings.delete),
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
		required this.unavailable,
		required this.onTap,
		required this.onLongPress,
	});

	/// 內建：assets 路徑。自訂：imageId。
	final String tokenKey;
	final bool builtin;
	final bool selected;
	final bool selectionMode;

	/// 內建圖尚未下載完成 + 目前斷網時為 true：顯示 placeholder、tap / longPress
	/// 不作用。自訂圖永遠 false。
	final bool unavailable;

	final VoidCallback onTap;
	final VoidCallback onLongPress;

	@override
	Widget build(BuildContext context) {
		Widget imageWidget;
		if (unavailable) {
			imageWidget = _placeholder();
		} else if (builtin) {
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
			onTap: unavailable ? null : ClickSound.wrap(context, onTap),
			onLongPress: unavailable ? null : onLongPress,
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

	/// 「內建圖尚未下載 + 斷網」的 placeholder：灰底 + cloud_off icon +
	/// 「尚未下載」字樣。
	Widget _placeholder() {
		return Container(
			color: Colors.black12,
			child: Column(
				mainAxisAlignment: MainAxisAlignment.center,
				children: <Widget>[
					const Icon(
						Icons.cloud_off,
						size: 28,
						color: Colors.black38,
					),
					const SizedBox(height: 4),
					Text(
						GalleryDetailStrings.notDownloaded,
						style: const TextStyle(fontSize: 11, color: Colors.black54),
					),
				],
			),
		);
	}
}
