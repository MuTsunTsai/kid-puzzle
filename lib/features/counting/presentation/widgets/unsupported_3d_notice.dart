import "package:flutter/foundation.dart" show kIsWeb;
import "package:flutter/material.dart";

import "../../../../core/constants/ui_strings.dart";

/// 不支援 3D 時的提示，給家長看：瀏覽器（iOS 16 的 Safari 等），或 App 跑在沒有 Impeller 的
/// 裝置（Android 10 以下等）。不建立場景（flutter_scene 會直接拋錯、整頁灰掉或空白）。
class Unsupported3dNotice extends StatelessWidget {
	const Unsupported3dNotice({super.key});

	@override
	Widget build(BuildContext context) {
		return Center(
			child: Container(
				constraints: const BoxConstraints(maxWidth: 480),
				margin: const EdgeInsets.all(24),
				padding: const EdgeInsets.all(28),
				decoration: BoxDecoration(
					color: Colors.white,
					borderRadius: BorderRadius.circular(24),
					boxShadow: const <BoxShadow>[BoxShadow(color: Color(0x22000000), blurRadius: 16)],
				),
				child: Column(
					mainAxisSize: MainAxisSize.min,
					children: <Widget>[
						const Icon(Icons.system_update, size: 48, color: Color(0xFF6D4C41)),
						const SizedBox(height: 12),
						const Text(
							CountingStrings.unsupportedTitle,
							style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF5D4037)),
						),
						const SizedBox(height: 8),
						Text(
							kIsWeb ? CountingStrings.unsupportedBody : CountingStrings.unsupportedBodyApp,
							textAlign: TextAlign.center,
							style: const TextStyle(fontSize: 16, height: 1.5, color: Color(0xFF6D4C41)),
						),
					],
				),
			),
		);
	}
}
