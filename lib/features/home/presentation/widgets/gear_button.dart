import "package:flutter/material.dart";

import "../../../../core/constants/app_dimens.dart";
import "../../../../shared/widgets/long_press_progress_button.dart";

/// 齒輪按鈕：需長按滿 [AppDimens.gearLongPressSeconds] 秒才觸發。
/// 視覺與互動邏輯共用 [LongPressProgressButton]。
class GearButton extends StatelessWidget {
	const GearButton({
		super.key,
		required this.onLongPressComplete,
	});

	final VoidCallback onLongPressComplete;

	@override
	Widget build(BuildContext context) {
		return LongPressProgressButton(
			seconds: AppDimens.gearLongPressSeconds,
			onComplete: onLongPressComplete,
			child: const Icon(
				Icons.settings,
				color: Colors.white,
				size: 32,
			),
		);
	}
}
