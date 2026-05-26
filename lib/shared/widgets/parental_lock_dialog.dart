import "dart:math";

import "package:flutter/material.dart";
import "package:provider/provider.dart";

import "../../core/audio/audio_service.dart";
import "../../core/constants/app_colors.dart";
import "../../core/constants/app_dimens.dart";

/// 家長鎖 dialog：問一道兩個 1~9 的加法題，答對才放行。
///
/// 答錯會自動換題；連續錯 [AppDimens.maxParentLockFailures] 次直接關閉 dialog
/// 並回傳 false。答對回傳 true。barrierDismissible=false、無 X 鈕，避免幼兒
/// 直接逃出。
///
/// 用法：
/// ```dart
/// final bool? passed = await ParentalLockDialog.show(context);
/// if (passed == true) { /* 進家長頁 */ }
/// ```
class ParentalLockDialog extends StatefulWidget {
	const ParentalLockDialog({super.key});

	/// Convenience：顯示 dialog 並回傳結果（passed=true / 失敗或取消=false）。
	///
	/// barrierDismissible=true：成人可按背景區域取消（回傳 false）。幼兒不會
	/// 知道這個操作，可依然有效保護家長頁。
	static Future<bool> show(BuildContext context) async {
		final bool? result = await showDialog<bool>(
			context: context,
			barrierDismissible: true,
			builder: (BuildContext ctx) => const ParentalLockDialog(),
		);
		return result ?? false;
	}

	@override
	State<ParentalLockDialog> createState() => _ParentalLockDialogState();
}

class _ParentalLockDialogState extends State<ParentalLockDialog> {
	final Random _random = Random();

	late int _a;
	late int _b;
	late List<int> _choices;
	int _failures = 0;

	@override
	void initState() {
		super.initState();
		_newQuestion();
	}

	void _newQuestion() {
		_a = 1 + _random.nextInt(9);
		_b = 1 + _random.nextInt(9);
		final int correct = _a + _b;
		// 兩個錯誤答案：在 ±1~5 範圍內挑、與正解不同、皆為正整數。
		final Set<int> picked = <int>{correct};
		while (picked.length < 3) {
			final int delta = 1 + _random.nextInt(5);
			final int sign = _random.nextBool() ? 1 : -1;
			final int candidate = correct + sign * delta;
			if (candidate > 0) picked.add(candidate);
		}
		_choices = picked.toList()..shuffle(_random);
	}

	void _onAnswer(BuildContext ctx, int value) {
		final int correct = _a + _b;
		if (value == correct) {
			Navigator.of(ctx).pop(true);
			return;
		}
		// 答錯：播 error 音、累計
		_safePlayError(ctx);
		_failures++;
		if (_failures >= AppDimens.maxParentLockFailures) {
			Navigator.of(ctx).pop(false);
			return;
		}
		setState(_newQuestion);
	}

	void _safePlayError(BuildContext ctx) {
		try {
			ctx.read<AudioService>().play(SfxKind.error);
		} catch (_) {
			// 在不提供 AudioService 的場景（如測試）忽略
		}
	}

	@override
	Widget build(BuildContext context) {
		return Dialog(
				shape: RoundedRectangleBorder(
					borderRadius: BorderRadius.circular(20),
				),
				child: Padding(
					padding: const EdgeInsets.all(28),
					child: Column(
						mainAxisSize: MainAxisSize.min,
						children: <Widget>[
							const Text(
								"請輸入答案",
								style: TextStyle(
									fontSize: 18,
									color: Colors.black54,
								),
							),
							const SizedBox(height: 12),
							Text(
								"$_a + $_b = ?",
								style: const TextStyle(
									fontSize: 36,
									fontWeight: FontWeight.bold,
									color: AppColors.primary,
								),
							),
							const SizedBox(height: 24),
							Wrap(
								spacing: 16,
								runSpacing: 12,
								alignment: WrapAlignment.center,
								children: <Widget>[
									for (final int v in _choices)
										_AnswerButton(
											value: v,
											onPressed: () => _onAnswer(context, v),
										),
								],
							),
							const SizedBox(height: 16),
							Text(
								"答錯次數：$_failures / ${AppDimens.maxParentLockFailures}",
								style: const TextStyle(
									fontSize: 12,
									color: Colors.black45,
								),
							),
						],
					),
				),
			);
	}
}

class _AnswerButton extends StatelessWidget {
	const _AnswerButton({required this.value, required this.onPressed});

	final int value;
	final VoidCallback onPressed;

	@override
	Widget build(BuildContext context) {
		return SizedBox(
			width: 96,
			height: 96,
			child: ElevatedButton(
				onPressed: onPressed,
				style: ElevatedButton.styleFrom(
					backgroundColor: AppColors.accent,
					foregroundColor: Colors.white,
					shape: const CircleBorder(),
					padding: EdgeInsets.zero,
					elevation: 4,
				),
				child: Text(
					"$value",
					style: const TextStyle(
						fontSize: 32,
						fontWeight: FontWeight.bold,
					),
				),
			),
		);
	}
}
