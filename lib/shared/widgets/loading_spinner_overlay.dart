import "package:flutter/material.dart";

/// 全螢幕半透明遮罩 + 中央 spinner。
///
/// 用途：在「下一關載入中」或其他短期 async 動作期間擋住輸入、提供視覺
/// 反饋。呼叫端用 `if (loading) const LoadingSpinnerOverlay()` 條件渲染即可。
class LoadingSpinnerOverlay extends StatelessWidget {
	const LoadingSpinnerOverlay({
		super.key,
		this.barrierOpacity = 0.45,
	});

	final double barrierOpacity;

	@override
	Widget build(BuildContext context) {
		return Positioned.fill(
			child: Container(
				color: Colors.black.withValues(alpha: barrierOpacity),
				child: const Center(child: CircularProgressIndicator()),
			),
		);
	}
}
