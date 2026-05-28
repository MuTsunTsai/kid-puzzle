import "package:flutter/material.dart";

import "../../../../core/constants/app_dimens.dart";
import "../../../../shared/widgets/click_sound.dart";
import "../../../../shared/widgets/long_press_progress_button.dart";

/// 齒輪按鈕：需長按滿 [AppDimens.gearLongPressSeconds] 秒才觸發。
/// 視覺與互動邏輯共用 [LongPressProgressButton]。
///
/// [bigKidMode] = true 時改為「tap 立即觸發」（不需長按），給「大朋友模式」用。
class GearButton extends StatelessWidget {
	const GearButton({
		super.key,
		required this.onLongPressComplete,
		this.bigKidMode = false,
	});

	final VoidCallback onLongPressComplete;
	final bool bigKidMode;

	@override
	Widget build(BuildContext context) {
		return LongPressProgressButton(
			seconds: bigKidMode ? 0 : AppDimens.gearLongPressSeconds,
			onComplete: ClickSound.wrap(context, onLongPressComplete)!,
			child: const Icon(
				Icons.settings,
				color: Colors.white,
				size: 32,
			),
		);
	}
}
