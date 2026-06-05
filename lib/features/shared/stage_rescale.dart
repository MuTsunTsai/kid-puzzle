import "dart:ui" as ui;

import "package:flutter/widgets.dart";

/// 「視窗 / canvas 尺寸改變時自動讓 controller 重算 stage」的共用樣板。
///
/// 用法：State class `with StageRescaleMixin<MyPage>`，實作 [currentStageSize]
/// 與 [applyRescale]，在 build 內把 child 包進 [LayoutBuilder]、於 builder
/// 第一行呼叫 [maybeRescaleForSize]：
///
/// ```dart
/// @override
/// Widget build(BuildContext context) {
///   return LayoutBuilder(
///     builder: (context, constraints) {
///       maybeRescaleForSize(Size(constraints.maxWidth, constraints.maxHeight));
///       return ...;
///     },
///   );
/// }
/// ```
///
/// 內部會：
/// 1. 比對新舊尺寸；差異 < 0.5 px 直接 no-op
/// 2. 用 post-frame callback 推遲 mutate controller，避免 layout pass 內動 state
/// 3. callback 內再比一次（前一幀已處理過就不重複做）
///
/// 子類只需處理「拿到新 Size 後怎麼把 controller 內部幾何全部按比例重算」。
mixin StageRescaleMixin<T extends StatefulWidget> on State<T> {
	/// 目前 controller 內記錄的 stage 尺寸。null 表示 controller 還沒就緒
	/// （此 mixin 在 null 時會 no-op）。
	ui.Size? get currentStageSize;

	/// 真正套用 rescale：把 controller 內所有與尺寸有關的幾何重算到 [newSize]。
	void applyRescale(ui.Size newSize);

	/// 視窗 / canvas 尺寸改變時呼叫。
	void maybeRescaleForSize(Size newSize) {
		if (newSize.width <= 0 || newSize.height <= 0) return;
		final ui.Size? cur = currentStageSize;
		if (cur == null) return;
		if ((cur.width - newSize.width).abs() < 0.5 &&
				(cur.height - newSize.height).abs() < 0.5) {
			return;
		}
		WidgetsBinding.instance.addPostFrameCallback((_) {
			if (!mounted) return;
			final ui.Size? again = currentStageSize;
			if (again == null) return;
			if ((again.width - newSize.width).abs() < 0.5 &&
					(again.height - newSize.height).abs() < 0.5) {
				return;
			}
			applyRescale(newSize);
		});
	}
}
