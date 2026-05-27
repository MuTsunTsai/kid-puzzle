import "package:flutter/material.dart";
import "package:flutter/scheduler.dart";

import "font_ready_signal.dart";

/// 在子畫面實際內容渲染前播放的「字型偵測 probe」。
///
/// 流程：
/// 1. 先以 [child] 為內容、上方覆蓋一個透明的中文 Text + 隱藏的可量測 Text。
/// 2. 每幀讀取量測 Text 的 RenderBox 寬度，跟「合理閾值」（每字 ≥ 12 px）比較。
/// 3. 達標就視為字型已渲染、呼叫 [notifyFontsReady]、移除 probe，[child] 變為可見。
///
/// 在未達標期間 [child] 完全透明（opacity=0 + IgnorePointer），使用者看不到也
/// 點不到 — 這樣可避免一開始的 XXXX tofu 短暫閃現、也讓教學系統等到字型 OK
/// 才啟動。
class FontReadyProbe extends StatefulWidget {
	const FontReadyProbe({
		super.key,
		required this.child,
		this.probeText = "幼兒益智遊戲開始拼圖",
		this.minPerCharWidth = 12,
	});

	final Widget child;

	/// 用來偵測的中文字串。預設為遊戲內常用字、字數足夠讓寬度差異明顯。
	final String probeText;

	/// 每字「合理寬度」下限。tofu 寬度通常 5~8 px，正常中文字 14~18 px；
	/// 12 px 是兩者中間的安全閾值。
	final double minPerCharWidth;

	@override
	State<FontReadyProbe> createState() => _FontReadyProbeState();
}

class _FontReadyProbeState extends State<FontReadyProbe> {
	final GlobalKey _probeKey = GlobalKey();
	bool _ready = false;

	@override
	void initState() {
		super.initState();
		_scheduleProbe();
	}

	void _scheduleProbe() {
		SchedulerBinding.instance.addPostFrameCallback((_) {
			if (!mounted || _ready) return;
			final RenderBox? box =
					_probeKey.currentContext?.findRenderObject() as RenderBox?;
			if (box != null && box.hasSize) {
				final double perChar = box.size.width / widget.probeText.length;
				if (perChar >= widget.minPerCharWidth) {
					setState(() => _ready = true);
					notifyFontsReady();
					return;
				}
			}
			// 還沒達標、下一幀再試
			_scheduleProbe();
		});
	}

	@override
	Widget build(BuildContext context) {
		return Stack(
			children: <Widget>[
				// 子畫面：未 ready 時完全透明且不接收輸入
				IgnorePointer(
					ignoring: !_ready,
					child: Opacity(
						opacity: _ready ? 1.0 : 0.0,
						child: widget.child,
					),
				),
				// 隱藏的量測 Text — 一定要在 layout tree 內才會被 layout。
				// 用 Offstage 也行但 Offstage 不 layout；改用 Positioned + 0 opacity。
				Positioned(
					left: 0,
					top: 0,
					child: IgnorePointer(
						child: Opacity(
							opacity: 0,
							child: Text(
								widget.probeText,
								key: _probeKey,
								style: const TextStyle(fontSize: 16),
							),
						),
					),
				),
			],
		);
	}
}
