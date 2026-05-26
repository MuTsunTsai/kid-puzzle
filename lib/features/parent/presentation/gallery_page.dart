import "package:flutter/material.dart";
import "package:provider/provider.dart";

import "../../../core/audio/audio_service.dart";
import "../../../core/constants/app_colors.dart";
import "../../../core/routing/app_router.dart";
import "../../../core/storage/gallery_repository.dart";
import "../../../shared/models/gallery_set.dart";
import "../../../shared/widgets/click_sound.dart";

/// 圖庫列表頁：列出所有「圖庫套」（內建 + 自訂），每套前面有 checkbox。
///
/// - 內建套不可刪、不可改名、進入後也不能新增/刪除圖。
/// - 自訂套可改名、刪除整套、進入後可新增/刪除圖。
/// - 列表底部「＋」按鈕新增自訂套；新增時跳對話框問名稱（預設「自訂圖庫」）。
class GalleryPage extends StatelessWidget {
	const GalleryPage({super.key});

	@override
	Widget build(BuildContext context) {
		return Scaffold(
			appBar: AppBar(
				title: const Text("圖庫管理"),
				backgroundColor: AppColors.primary,
				foregroundColor: Colors.white,
			),
			body: Consumer<GalleryRepository>(
				builder: (BuildContext context, GalleryRepository repo, _) {
					final List<GallerySet> sets = repo.sets;
					return ListView.separated(
						padding: const EdgeInsets.symmetric(vertical: 8),
						itemCount: sets.length,
						separatorBuilder: (BuildContext _, int _) =>
							const Divider(height: 1),
						itemBuilder: (BuildContext ctx, int i) {
							final GallerySet s = sets[i];
							return _GallerySetTile(set: s);
						},
					);
				},
			),
			floatingActionButton: FloatingActionButton.extended(
				onPressed: ClickSound.wrap(context, () => _onCreate(context)),
				icon: const Icon(Icons.add),
				label: const Text("新增圖庫"),
				backgroundColor: AppColors.accent,
				foregroundColor: Colors.white,
			),
		);
	}

	Future<void> _onCreate(BuildContext context) async {
		final String? name = await _askForName(context, initial: "自訂圖庫");
		if (name == null) return;
		if (!context.mounted) return;
		await context.read<GalleryRepository>().createUserSet(name);
	}

	/// 跳出對話框讓使用者輸入名稱。取消回 null。
	///
	/// 把 [TextEditingController] 放進 [_AskNameDialog] 內，讓它的生命週期與
	/// dialog widget 綁在一起，避免「dialog 還在出場動畫、controller 已被
	/// dispose」的競爭情況。
	static Future<String?> _askForName(
		BuildContext context, {
		required String initial,
		String title = "新增圖庫",
	}) async {
		final String? result = await showDialog<String>(
			context: context,
			builder: (BuildContext ctx) =>
					_AskNameDialog(initial: initial, title: title),
		);
		if (result == null) return null;
		final String trimmed = result.trim();
		if (trimmed.isEmpty) return null;
		return trimmed;
	}
}

class _AskNameDialog extends StatefulWidget {
	const _AskNameDialog({required this.initial, required this.title});

	final String initial;
	final String title;

	@override
	State<_AskNameDialog> createState() => _AskNameDialogState();
}

class _AskNameDialogState extends State<_AskNameDialog> {
	late final TextEditingController _ctrl;

	@override
	void initState() {
		super.initState();
		_ctrl = TextEditingController(text: widget.initial)
			..selection = TextSelection(
				baseOffset: 0,
				extentOffset: widget.initial.length,
			);
	}

	@override
	void dispose() {
		_ctrl.dispose();
		super.dispose();
	}

	@override
	Widget build(BuildContext context) {
		return AlertDialog(
			title: Text(widget.title),
			content: TextField(
				controller: _ctrl,
				autofocus: true,
				decoration: const InputDecoration(
					labelText: "圖庫名稱",
					border: OutlineInputBorder(),
				),
				onSubmitted: (String v) => Navigator.of(context).pop(v),
			),
			actions: <Widget>[
				TextButton(
					onPressed: ClickSound.wrap(
						context,
						() => Navigator.of(context).pop(),
					),
					child: const Text("取消"),
				),
				ElevatedButton(
					onPressed: ClickSound.wrap(
						context,
						() => Navigator.of(context).pop(_ctrl.text),
					),
					child: const Text("確定"),
				),
			],
		);
	}
}

class _GallerySetTile extends StatelessWidget {
	const _GallerySetTile({required this.set});

	final GallerySet set;

	@override
	Widget build(BuildContext context) {
		final int n = set.imageCount;
		return ListTile(
			leading: Checkbox(
				value: set.enabled,
				onChanged: (bool? v) {
					try {
						context.read<AudioService>().play(SfxKind.click);
					} catch (_) {}
					context.read<GalleryRepository>().setEnabled(set.id, v ?? false);
				},
			),
			title: Text(
				set.name,
				style: const TextStyle(fontWeight: FontWeight.w600),
			),
			subtitle: Text(
				set.builtin ? "內建．$n 張圖" : "自訂．$n 張圖",
				style: const TextStyle(fontSize: 12, color: Colors.black54),
			),
			trailing: set.builtin
					? const Icon(Icons.chevron_right, color: Colors.black38)
					: PopupMenuButton<String>(
							icon: const Icon(Icons.more_vert),
							onSelected: (String action) {
								try {
									context.read<AudioService>().play(SfxKind.click);
								} catch (_) {}
								_handleAction(context, action);
							},
							itemBuilder: (BuildContext ctx) =>
									<PopupMenuEntry<String>>[
								const PopupMenuItem<String>(
									value: "rename",
									child: ListTile(
										leading: Icon(Icons.edit),
										title: Text("重新命名"),
										contentPadding: EdgeInsets.zero,
									),
								),
								const PopupMenuItem<String>(
									value: "delete",
									child: ListTile(
										leading: Icon(Icons.delete, color: Colors.red),
										title: Text(
											"刪除整套",
											style: TextStyle(color: Colors.red),
										),
										contentPadding: EdgeInsets.zero,
									),
								),
							],
						),
			onTap: ClickSound.wrap(
				context,
				() => Navigator.of(context).pushNamed(
					AppRoutes.parentGalleryDetail,
					arguments: set.id,
				),
			),
		);
	}

	Future<void> _handleAction(BuildContext context, String action) async {
		switch (action) {
			case "rename":
				await _rename(context);
			case "delete":
				await _confirmDelete(context);
		}
	}

	Future<void> _rename(BuildContext context) async {
		final String? newName = await GalleryPage._askForName(
			context,
			initial: set.name,
			title: "重新命名",
		);
		if (newName == null) return;
		if (!context.mounted) return;
		await context.read<GalleryRepository>().renameUserSet(set.id, newName);
	}

	Future<void> _confirmDelete(BuildContext context) async {
		final bool ok = await showDialog<bool>(
					context: context,
					builder: (BuildContext ctx) => AlertDialog(
						title: const Text("刪除整套？"),
						content: Text(
							"確定要刪除「${set.name}」與其中 ${set.imageCount} 張圖嗎？此操作無法復原。",
						),
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
		await context.read<GalleryRepository>().deleteUserSet(set.id);
	}
}
