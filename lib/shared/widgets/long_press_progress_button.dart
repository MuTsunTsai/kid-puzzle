import "dart:async";

import "package:flutter/gestures.dart";
import "package:flutter/material.dart";

/// 長按進度條按鈕：手指按下時周圍出現環形進度條、持續滿 [seconds] 秒才觸發
/// [onComplete]；中途放開或取消會以加速 reverse（1/3 速）縮回。
///
/// 設計目的：避免幼兒誤觸有破壞性的操作（離開拼圖 / 進入家長頁等）。
///
/// 視覺結構：[SizedBox(size)] 內 [Stack] 疊「進度環 + 你給的 child」。
/// child 一般是個 [Icon]。child 大小由 caller 自己控制（用 Icon.size）。
class LongPressProgressButton extends StatefulWidget {
	const LongPressProgressButton({
		super.key,
		required this.seconds,
		required this.onComplete,
		required this.child,
		this.size = 96.0,
		this.progressStrokeWidth = 4.0,
		this.progressColor,
		this.touchSlop = 30.0,
	});

	/// 必須按多久才觸發 [onComplete]。
	final int seconds;

	/// 達到 [seconds] 秒後觸發的 callback。
	final VoidCallback onComplete;

	/// 中央顯示的內容（一般是 [Icon]）。
	final Widget child;

	/// 整個按鈕（含外圍進度環）佔的方形大小。
	final double size;

	/// 進度環線寬。
	final double progressStrokeWidth;

	/// 進度環顏色；null 則用 `Colors.white.withValues(alpha: 0.8)`。
	final Color? progressColor;

	/// touch slop（觸控移動容忍範圍）。預設 30 px，比 Flutter 內建 18 px 鬆，
	/// 配合幼兒長按時手指微微移動。
	final double touchSlop;

	@override
	State<LongPressProgressButton> createState() =>
			_LongPressProgressButtonState();
}

class _LongPressProgressButtonState extends State<LongPressProgressButton>
		with SingleTickerProviderStateMixin {
	Timer? _timer;
	late AnimationController _progressController;

	@override
	void initState() {
		super.initState();
		_progressController = AnimationController(
			vsync: this,
			duration: Duration(seconds: widget.seconds),
			// reverse 用 1/3 時間：放開時快速縮回，不會等很久才消失。
			reverseDuration: Duration(
				milliseconds: widget.seconds * 1000 ~/ 3,
			),
		);
	}

	@override
	void didUpdateWidget(covariant LongPressProgressButton oldWidget) {
		super.didUpdateWidget(oldWidget);
		if (oldWidget.seconds != widget.seconds) {
			_progressController.duration = Duration(seconds: widget.seconds);
			_progressController.reverseDuration = Duration(
				milliseconds: widget.seconds * 1000 ~/ 3,
			);
		}
	}

	@override
	void dispose() {
		_timer?.cancel();
		_progressController.dispose();
		super.dispose();
	}

	void _startPress() {
		_progressController.forward(from: 0.0);
		_timer = Timer(
			Duration(seconds: widget.seconds),
			widget.onComplete,
		);
	}

	void _cancelPress() {
		_timer?.cancel();
		_timer = null;
		_progressController.reverse();
	}

	@override
	Widget build(BuildContext context) {
		final Color color = widget.progressColor ??
				Colors.white.withValues(alpha: 0.8);
		// 用 RawGestureDetector 自訂 touch slop：預設 18 px 對幼兒長按時手指微移
		// 會被視為「取消」中斷進度。
		return RawGestureDetector(
			gestures: <Type, GestureRecognizerFactory<GestureRecognizer>>{
				TapGestureRecognizer:
						GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
					() => TapGestureRecognizer(),
					(TapGestureRecognizer instance) {
						instance.onTapDown = (_) => _startPress();
						instance.onTapUp = (_) => _cancelPress();
						instance.onTapCancel = _cancelPress;
						instance.gestureSettings = DeviceGestureSettings(
							touchSlop: widget.touchSlop,
						);
					},
				),
			},
			child: SizedBox(
				width: widget.size,
				height: widget.size,
				child: Stack(
					alignment: Alignment.center,
					children: <Widget>[
						AnimatedBuilder(
							animation: _progressController,
							builder: (BuildContext context, Widget? _) {
								return SizedBox.expand(
									child: CircularProgressIndicator(
										value: _progressController.value,
										strokeWidth: widget.progressStrokeWidth,
										color: color,
										backgroundColor: Colors.transparent,
									),
								);
							},
						),
						widget.child,
					],
				),
			),
		);
	}
}
