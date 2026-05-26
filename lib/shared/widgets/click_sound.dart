import "package:flutter/widgets.dart";
import "package:provider/provider.dart";

import "../../core/audio/audio_service.dart";

/// 把按鈕的 `onPressed` callback 包一層、先播 [SfxKind.click] 再呼叫原 callback。
///
/// 用法（所有 `ElevatedButton` / `IconButton` / `TextButton` 等 Material 按鈕通用）：
/// ```dart
/// ElevatedButton(
///   onPressed: ClickSound.wrap(context, _doSomething),
///   ...
/// )
/// ```
///
/// 若 [onPressed] 為 null（disabled），回傳 null、保持按鈕的 disabled 樣式。
/// 不在乎是否成功播 — provider 找不到時靜默忽略。
class ClickSound {
	ClickSound._();

	/// 將 [onPressed] 包一層：先播 click 再執行原邏輯。null 直通 null。
	static VoidCallback? wrap(BuildContext context, VoidCallback? onPressed) {
		if (onPressed == null) return null;
		return () {
			try {
				context.read<AudioService>().play(SfxKind.click);
			} catch (_) {
				// 在不提供 AudioService 的場景（測試）忽略
			}
			onPressed();
		};
	}
}
