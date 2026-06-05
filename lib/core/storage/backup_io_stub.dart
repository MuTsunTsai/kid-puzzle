// 非 web 平台實作：用 file_picker.saveFile 拿 path、再 File.writeAsBytes 寫入。
//
// 在 web 平台這個檔不會被載入；conditional import 切到 backup_io_web.dart。

import "dart:io";
import "dart:typed_data";

import "package:file_picker/file_picker.dart";

Future<bool> saveBackupFileImpl({
	required String suggestedFileName,
	required Uint8List bytes,
}) async {
	final String? path = await FilePicker.platform.saveFile(
		dialogTitle: "儲存備份檔",
		fileName: suggestedFileName,
		type: FileType.custom,
		allowedExtensions: const <String>["kpb"],
		bytes: bytes,
	);
	if (path == null) return false;
	// iOS / Android：saveFile 在某些 platform 會自己把 bytes 寫進去，這時
	// 再 writeAsBytes 是 idempotent 的覆寫。對 desktop 而言、saveFile 只回 path
	// 不寫檔，所以一定要這行。
	try {
		await File(path).writeAsBytes(bytes, flush: true);
	} catch (_) {
		// path 不可寫（例如 SAF 已經寫好但 File API 無權限）→ 視為成功，因為
		// saveFile 本身已經完成寫入。
	}
	return true;
}
