import "dart:typed_data";

import "package:file_picker/file_picker.dart";
import "package:flutter/material.dart";
import "package:provider/provider.dart";

import "../../../core/constants/app_colors.dart";
import "../../../core/constants/ui_strings.dart";
import "../../../core/storage/backup_io.dart";
import "../../../core/storage/backup_service.dart";
import "../../../core/storage/gallery_repository.dart";
import "../../../core/storage/settings_repository.dart";
import "../../../shared/models/gallery_set.dart";
import "../../../shared/widgets/click_sound.dart";

/// 設定備份頁：匯出 / 匯入。
///
/// 匯出：把當前 settings + 教學紀錄 + 自訂圖庫打包成單一 .kpb 檔（store-mode
/// zip、內含 `manifest.json` + `images/<uuid>.jpg`）。
///
/// 匯入：選一個 .kpb 檔，若當前有自訂圖庫、會跳 dialog 讓使用者選「覆蓋」
/// 或「新增」模式。
class BackupPage extends StatefulWidget {
	const BackupPage({super.key});

	@override
	State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
	bool _busy = false;

	@override
	Widget build(BuildContext context) {
		return Scaffold(
			appBar: AppBar(
				title: const Text(ParentStrings.backupTitle),
				backgroundColor: AppColors.primary,
				foregroundColor: Colors.white,
			),
			body: Center(
				child: ConstrainedBox(
					constraints: const BoxConstraints(maxWidth: 480),
					child: ListView(
						padding: const EdgeInsets.symmetric(vertical: 8),
						children: <Widget>[
							ListTile(
								leading: const Icon(Icons.file_upload_outlined),
								title: const Text(ParentStrings.backupExport),
								subtitle: const Text(ParentStrings.backupExportSubtitle),
								enabled: !_busy,
								onTap: _busy ? null : ClickSound.wrap(context, _doExport),
							),
							ListTile(
								leading: const Icon(Icons.file_download_outlined),
								title: const Text(ParentStrings.backupImport),
								subtitle: const Text(ParentStrings.backupImportSubtitle),
								enabled: !_busy,
								onTap: _busy ? null : ClickSound.wrap(context, _doImport),
							),
							if (_busy)
								const Padding(
									padding: EdgeInsets.all(16),
									child: Center(child: CircularProgressIndicator()),
								),
						],
					),
				),
			),
		);
	}

	Future<void> _doExport() async {
		final SettingsRepository settings = context.read<SettingsRepository>();
		final GalleryRepository gallery = context.read<GalleryRepository>();
		setState(() => _busy = true);
		try {
			final Uint8List bytes = await BackupService.exportBackup(
				settings: settings,
				gallery: gallery,
				// 寫死當前版本字串；之後改在 main 注入更好但目前夠用。
				appVersion: "0.2.2+6",
			);
			final DateTime now = DateTime.now();
			final String stamp = "${now.year.toString().padLeft(4, '0')}"
					"${now.month.toString().padLeft(2, '0')}"
					"${now.day.toString().padLeft(2, '0')}-"
					"${now.hour.toString().padLeft(2, '0')}"
					"${now.minute.toString().padLeft(2, '0')}";
			final String filename = "kid-puzzle-backup-$stamp.kpb";
			final bool ok = await saveBackupFile(
				suggestedFileName: filename,
				bytes: bytes,
			);
			if (!mounted) return;
			_showSnack(ok ? ParentStrings.backupExportDone : ParentStrings.backupCancelled);
		} catch (e) {
			if (!mounted) return;
			_showSnack("${ParentStrings.backupExportFailed}$e");
		} finally {
			if (mounted) setState(() => _busy = false);
		}
	}

	Future<void> _doImport() async {
		final SettingsRepository settings = context.read<SettingsRepository>();
		final GalleryRepository gallery = context.read<GalleryRepository>();

		// 用 FileType.any 而非 custom + allowedExtensions：Android 的 SAF 對
		// .kpb 這類未註冊副檔名沒有對應 MIME type、會把它一律變灰不可選；改成
		// any 後使用者可任選、我們在拿到 bytes 後再自行驗證內容是不是合法
		// backup（BackupService.readBackup 失敗會丟 FormatException）。
		final FilePickerResult? picked = await FilePicker.platform.pickFiles(
			type: FileType.any,
			withData: true,
		);
		if (picked == null || picked.files.isEmpty) return;
		final PlatformFile file = picked.files.first;
		final Uint8List? bytes = file.bytes;
		if (bytes == null) {
			if (!mounted) return;
			_showSnack(ParentStrings.backupImportFailedNoBytes);
			return;
		}

		setState(() => _busy = true);
		try {
			final BackupContents contents = await BackupService.readBackup(bytes);

			// 若當前已有自訂圖庫、彈 dialog 讓使用者選模式；否則直接走 replace
			final bool hasUserSets =
					gallery.sets.any((GallerySet s) => !s.builtin);
			final BackupGalleryMode? mode = hasUserSets
					? await _askMode(contents)
					: BackupGalleryMode.replace;
			if (mode == null) {
				if (mounted) _showSnack(ParentStrings.backupCancelled);
				return;
			}

			await BackupService.applyBackup(
				contents: contents,
				galleryMode: mode,
				settings: settings,
				gallery: gallery,
			);
			if (!mounted) return;
			_showSnack(mode == BackupGalleryMode.replace
					? ParentStrings.backupImportDoneReplace
					: ParentStrings.backupImportDoneMerge);
		} on FormatException catch (e) {
			if (!mounted) return;
			_showSnack("${ParentStrings.backupImportFailed}${e.message}");
		} catch (e) {
			if (!mounted) return;
			_showSnack("${ParentStrings.backupImportFailed}$e");
		} finally {
			if (mounted) setState(() => _busy = false);
		}
	}

	Future<BackupGalleryMode?> _askMode(BackupContents contents) async {
		return showDialog<BackupGalleryMode>(
			context: context,
			builder: (BuildContext ctx) => AlertDialog(
				title: const Text(ParentStrings.backupModeTitle),
				content: Text(
					"${ParentStrings.backupModeBodyPrefix}"
					"${contents.userSetCount}${ParentStrings.backupModeBodyMid}"
					"${contents.totalImageCount}${ParentStrings.backupModeBodySuffix}",
				),
				actions: <Widget>[
					TextButton(
						onPressed: ClickSound.wrap(
							ctx,
							() => Navigator.of(ctx).pop(),
						),
						child: const Text(ParentStrings.backupCancel),
					),
					TextButton(
						onPressed: ClickSound.wrap(
							ctx,
							() => Navigator.of(ctx).pop(BackupGalleryMode.merge),
						),
						child: const Text(ParentStrings.backupModeMerge),
					),
					TextButton(
						style: TextButton.styleFrom(foregroundColor: Colors.red),
						onPressed: ClickSound.wrap(
							ctx,
							() => Navigator.of(ctx).pop(BackupGalleryMode.replace),
						),
						child: const Text(ParentStrings.backupModeReplace),
					),
				],
			),
		);
	}

	void _showSnack(String msg) {
		ScaffoldMessenger.of(context).showSnackBar(
			SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
		);
	}
}
