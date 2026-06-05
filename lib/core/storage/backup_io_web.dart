// Web 平台實作：用 Blob + <a download> 觸發瀏覽器下載。
//
// 不走 file_picker.saveFile：web 版本回傳的 path 是空字串、且不會自動觸發
// 下載；必須自己組 Blob + URL.createObjectURL + anchor.click。

import "dart:js_interop";
import "dart:typed_data";

import "package:web/web.dart" as web;

Future<bool> saveBackupFileImpl({
	required String suggestedFileName,
	required Uint8List bytes,
}) async {
	// Blob 接 JSArray<BlobPart>；用 toJS 把 Uint8List 轉成 JSAny。
	final JSArray<web.BlobPart> parts =
			<JSAny>[bytes.toJS].toJS;
	final web.Blob blob = web.Blob(
		parts,
		web.BlobPropertyBag(type: "application/octet-stream"),
	);
	final String url = web.URL.createObjectURL(blob);
	final web.HTMLAnchorElement anchor =
			web.document.createElement("a") as web.HTMLAnchorElement;
	anchor.href = url;
	anchor.download = suggestedFileName;
	anchor.style.display = "none";
	web.document.body?.append(anchor);
	anchor.click();
	anchor.remove();
	// revokeObjectURL 太早呼叫某些瀏覽器會中斷下載 — 延遲一些再 revoke。
	Future<void>.delayed(const Duration(seconds: 30), () {
		web.URL.revokeObjectURL(url);
	});
	return true;
}
