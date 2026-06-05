// 「鎖定畫面」設定選項的共用零件。
//
// 兩個遊戲模式的 setup 頁都會用到、且行為一致：
// - 只在 Android 顯示（web / iOS / desktop 無對應系統 API）
// - 進入遊戲時呼叫 [SystemGuard.enable]、離開時 [SystemGuard.disable]
// - 設定值共用 SettingsRepository.screenLockEnabled

import "package:flutter/foundation.dart";
import "package:flutter/material.dart";

import "../../core/system/system_guard.dart";

/// 此平台是否該顯示「鎖定畫面」設定。
/// 只在原生 Android 顯示（web 即便跑在 Android Chrome 上也回 false）。
bool get showScreenLockOption =>
		!kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// 若啟用「鎖定畫面」、就嘗試 enable [SystemGuard]（app pinning）。
/// 非 Android / 未啟用都 no-op。fire-and-forget 失敗不擋遊戲流程。
Future<void> maybeEnableScreenLock(bool screenLockEnabled) async {
	if (!screenLockEnabled) return;
	await SystemGuard.enable();
}

/// 離開遊戲頁時呼叫；非 Android / 未啟用都 no-op。
Future<void> disableScreenLockGuard() => SystemGuard.disable();

/// 白底卡片內的一行 checkbox + label，跟多片拼圖玩法選項同樣風格。
///
/// **不含**外層白卡——呼叫端要自己包 [Material]（通常是多個 row 共用一張卡）。
class OptionCheckRow extends StatelessWidget {
	const OptionCheckRow({
		super.key,
		required this.label,
		required this.value,
		required this.onChanged,
	});

	final String label;
	final bool value;
	final ValueChanged<bool> onChanged;

	@override
	Widget build(BuildContext context) {
		return InkWell(
			borderRadius: BorderRadius.circular(8),
			onTap: () => onChanged(!value),
			child: Padding(
				padding: const EdgeInsets.fromLTRB(0, 4, 8, 4),
				child: Row(
					mainAxisSize: MainAxisSize.min,
					children: <Widget>[
						Checkbox(
							value: value,
							onChanged: (bool? v) => onChanged(v ?? false),
						),
						const SizedBox(width: 4),
						Text(
							label,
							style: const TextStyle(
								fontSize: 18,
								fontWeight: FontWeight.w600,
								color: Colors.black87,
							),
						),
					],
				),
			),
		);
	}
}

