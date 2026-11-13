import "package:flutter/material.dart";

import "../../../../core/constants/ui_strings.dart";

/// 瀏覽器不支援 3D 時（iOS 16 的 Safari 等）的提示，給家長看。不建立場景
/// （flutter_scene 會直接拋錯、整頁灰掉）。
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
				child: const Column(
					mainAxisSize: MainAxisSize.min,
					children: <Widget>[
						Icon(Icons.system_update, size: 48, color: Color(0xFF6D4C41)),
						SizedBox(height: 12),
						Text(
							CountingStrings.unsupportedTitle,
							style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF5D4037)),
						),
						SizedBox(height: 8),
						Text(
							CountingStrings.unsupportedBody,
							textAlign: TextAlign.center,
							style: TextStyle(fontSize: 16, height: 1.5, color: Color(0xFF6D4C41)),
						),
					],
				),
			),
		);
	}
}
