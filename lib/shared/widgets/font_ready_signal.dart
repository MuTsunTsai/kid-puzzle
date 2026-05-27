import "dart:async";

import "../../core/system/interop.dart";

/// 字型已渲染的同步點。
///
/// [FontReadyProbe] 量到合理寬度時呼叫 [notifyFontsReady]；
/// 任何想等字型就緒才行動的程式碼（例如教學系統）`await waitForFontsReady()`。
///
/// 純 Dart Completer，不繞 DOM event；但 [notifyFontsReady] 額外會
/// dispatch `flutter-fonts-ready` 給 index.html 的 spinner 隱藏邏輯。

Completer<void>? _completer;

Future<void> waitForFontsReady() {
	_completer ??= Completer<void>();
	return _completer!.future;
}

void notifyFontsReady() {
	_completer ??= Completer<void>();
	if (!_completer!.isCompleted) {
		_completer!.complete();
	}
	dispatchFontsReadyEvent();
}
