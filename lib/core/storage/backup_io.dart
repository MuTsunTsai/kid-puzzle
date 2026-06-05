// 備份檔案的「存檔」抽象。
//
// 各平台行為：
// - Android / iOS / desktop：用 file_picker.saveFile 拿到 path → 寫入
// - Web：file_picker.saveFile 不直接寫檔，這裡走 Blob + <a download> 觸發
//   瀏覽器下載
//
// 「讀檔」直接走 file_picker.pickFiles 即可（各平台行為一致、會回 bytes 或
// path），不需要這層抽象。

import "dart:typed_data";

import "backup_io_stub.dart"
		if (dart.library.js_interop) "backup_io_web.dart";

/// 把 bytes 存成檔案。
///
/// 各平台行為：
/// - Web：觸發瀏覽器下載 `suggestedFileName`，回傳 `true`（無從得知是否真的存了）
/// - 其他：彈系統存檔對話框讓使用者選位置；使用者取消回傳 `false`，成功 `true`
Future<bool> saveBackupFile({
	required String suggestedFileName,
	required Uint8List bytes,
}) => saveBackupFileImpl(
		suggestedFileName: suggestedFileName,
		bytes: bytes,
	);
