import "package:flutter/foundation.dart";
import "package:flutter/material.dart";

import "../../core/constants/app_colors.dart";
import "../../core/constants/app_dimens.dart";
import "../../shared/widgets/click_sound.dart";
import "../../shared/widgets/long_press_progress_button.dart";

/// 各遊戲頁通用的右上「長按關閉」按鈕。
///
/// 行為：
/// - 長按 [AppDimens.gearLongPressSeconds] 秒觸發 [onClose]
/// - 大朋友模式 ([bigKidMode] = true) 改為輕觸即觸發（seconds = 0）
/// - 拼片靠近時 ([shouldHide] 回 true) 淡出且禁用點擊
///
/// 訂閱機制：傳一個 [ValueListenable]（例如 controller.repaintTick）；每次
/// bump 都會重算 [shouldHide]。傳 null 則固定顯示（過渡期還沒 controller 用）。
///
/// 一般用 `Positioned(top: 12, right: 12, child: BoardCloseButton(...))` 包。
class BoardCloseButton extends StatelessWidget {
	const BoardCloseButton({
		super.key,
		required this.repaint,
		required this.bigKidMode,
		required this.shouldHide,
		required this.onClose,
	});

	/// 由 controller 提供的「更新訊號」；null 時固定顯示。
	final ValueListenable<int>? repaint;
	final bool bigKidMode;

	/// callback 而非 bool：每次 rebuild 都重算，避免 page build 時固定值、
	/// 拼片之後拖開仍卡在 true。
	final ValueGetter<bool> shouldHide;

	final VoidCallback onClose;

	@override
	Widget build(BuildContext context) {
		// 用單一 widget tree 確保 AnimatedOpacity 在過渡 → 遊戲階段切換時不被
		// 丟掉、能正常淡出。null 時用 dummy ValueListenable（永遠不 bump）。
		final ValueListenable<int> listenable = repaint ?? const _NeverNotifier();
		return ValueListenableBuilder<int>(
			valueListenable: listenable,
			builder: (BuildContext context, _, _) {
				final bool hidden = repaint == null ? false : shouldHide();
				return AnimatedOpacity(
					opacity: hidden ? 0.0 : 1.0,
					duration: const Duration(milliseconds: 500),
					child: IgnorePointer(
						ignoring: hidden,
						child: LongPressProgressButton(
							seconds: bigKidMode ? 0 : AppDimens.gearLongPressSeconds,
							onComplete: ClickSound.wrap(context, onClose)!,
							progressColor: AppColors.primary,
							child: Container(
								width: 56,
								height: 56,
								decoration: BoxDecoration(
									shape: BoxShape.circle,
									color: Colors.white.withValues(alpha: 0.9),
								),
								child: const Icon(
									Icons.close,
									color: AppColors.primary,
									size: 28,
								),
							),
						),
					),
				);
			},
		);
	}
}

/// 永不通知的 ValueListenable 占位，給 [BoardCloseButton] 在「無 controller」
/// 階段用 — widget tree shape 保持一致、AnimatedOpacity 不會在切換時被丟掉。
class _NeverNotifier implements ValueListenable<int> {
	const _NeverNotifier();
	@override
	int get value => 0;
	@override
	void addListener(VoidCallback listener) {}
	@override
	void removeListener(VoidCallback listener) {}
}
