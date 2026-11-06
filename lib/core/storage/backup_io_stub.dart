// 非 web 平台實作：交給 file_picker.saveFile 開「另存新檔」對話框並寫入。
//
// file_picker 12 起 saveFile 在各平台都會自己把 bytes 寫進使用者選的位置
// （Android 走 SAF content://、desktop 寫 file://），回傳 Uri；取消時回 null。
//
// 在 web 平台這個檔不會被載入；conditional import 切到 backup_io_web.dart。

import "dart:typed_data";

import "package:file_picker/file_picker.dart";

Future<bool> saveBackupFileImpl({
	required String suggestedFileName,
	required Uint8List bytes,
}) async {
	final Uri? saved = await FilePicker.saveFile(
		dialogTitle: "儲存備份檔",
		fileName: suggestedFileName,
		bytes: bytes,
	);
	return saved != null;
}
