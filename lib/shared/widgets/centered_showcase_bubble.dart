import "package:flutter/material.dart";
import "package:showcaseview/showcaseview.dart";

import "tutorial_bubble.dart";

/// 教學流程中的「純說明氣泡」步驟：不指向任何 widget、只在畫面中央顯示一段
/// 比較大的文字氣泡。可以與其他 [Showcase] 共用同一個 startShowCase 序列。
///
/// 用法：把它放在 widget tree 中任意位置（通常是 Scaffold 內、不影響 layout
/// 的角落），給它一個 [GlobalKey]，並把該 key 加進 `startShowCase([...])`。
///
/// 實作細節：
/// - target 是放在畫面中央的 1×1 透明點（套件需要 anchor 才能 layout 氣泡）。
/// - 氣泡的 container 撐成全螢幕高度（[SizedBox] + [OverflowBox] 居中對齊），
///   讓氣泡視覺位置直接落在畫面正中央 — 不靠 Transform/FractionalTranslation
///   做位移，避免 hit-test bounds 與 paint 位置錯位導致桌機 click 失效。
/// - 配合黑色 75% 不透明的全螢幕背景，視覺等同「畫面中央純氣泡」。
class CenteredShowcaseBubble extends StatelessWidget {
	const CenteredShowcaseBubble({
		super.key,
		required this.showcaseKey,
		required this.message,
		this.onTap,
	});

	/// 要加進 `startShowCase([...])` 的 key。
	final GlobalKey showcaseKey;

	/// 氣泡內顯示的訊息。
	final String message;

	/// 使用者點氣泡或背景任意處時的 callback；觸發後套件會自動推進到下一步。
	///
	/// 在 user gesture handler 同步階段觸發 — 可在這裡呼叫 web 需要 user gesture
	/// 才能執行的 API（如 requestFullscreen / orientation.lock）。
	final VoidCallback? onTap;

	@override
	Widget build(BuildContext context) {
		// anchor 放在畫面正中央，配 tooltipPosition: bottom + gap 0 →
		// 套件會把氣泡 paint 在 anchor 正下方。氣泡自己用 OverflowBox + SizedBox
		// 撐成全螢幕高度後再置中對齊，視覺上回到畫面正中央。
		return Align(
			alignment: Alignment.center,
			child: Showcase.withWidget(
				key: showcaseKey,
				container: _CenteredBubbleWrapper(message: message, onTap: onTap),
				overlayColor: Colors.black,
				overlayOpacity: 0.75,
				// 背景 barrier tap 也走同一個 callback；套件本身在執行完 onBarrierClick
				// 後會自動 next，所以這裡不要再呼叫 ShowcaseView.next。
				onBarrierClick: onTap,
				tooltipPosition: TooltipPosition.bottom,
				targetTooltipGap: 0,
				// target 是 1×1 透明點；視覺上看不見、被氣泡卡片蓋住。
				child: const SizedBox(width: 1, height: 1),
			),
		);
	}
}

/// 包 [TutorialBubble] 並接點擊事件。用 [SizedBox] 撐成全螢幕高、[OverflowBox]
/// 限制 child 大小為氣泡實際 size，OverflowBox 預設居中對齊 → 氣泡自然落在
/// 畫面正中央，且整個全螢幕 box 都是有效的 hit-test 範圍。
class _CenteredBubbleWrapper extends StatelessWidget {
	const _CenteredBubbleWrapper({required this.message, this.onTap});

	final String message;
	final VoidCallback? onTap;

	static const double _bubbleWidth = 480;
	static const EdgeInsets _bubblePadding =
			EdgeInsets.symmetric(horizontal: 24, vertical: 20);
	static const TextStyle _bubbleTextStyle = TextStyle(
		fontSize: 18,
		color: Colors.black87,
		height: 1.6,
	);
	static const double _iconSize = 80;
	static const double _iconGap = 20;

	@override
	Widget build(BuildContext context) {
		// 先用 TutorialBubble.computeHeight 量出氣泡實際高度，把氣泡用
		// Transform.translate 往上偏「半個高度」— 視覺中心剛好落在 anchor 上、
		// 達成置中。Transform.translate 只動 paint 位置，hit-test bounds 維持
		// 在 parent 範圍內（不會像 FractionalTranslation 那樣被 parent bounds 拒絕）。
		final double height = TutorialBubble.computeHeight(
			context,
			text: message,
			width: _bubbleWidth,
			padding: _bubblePadding,
			textStyle: _bubbleTextStyle,
			textAlign: TextAlign.left,
			leadingWidth: _iconSize,
			leadingGap: _iconGap,
			hasLeading: true,
		);
		// 用 SizedBox 撐成全螢幕高度、OverflowBox 把 child 限制到實際氣泡 size、
		// 預設居中對齊 → 氣泡視覺位置直接落在畫面正中央。比 Transform.translate
		// 好的地方：paint 位置 = hit-test 位置 = MouseRegion hover 區，桌機 click
		// 與 cursor 行為完全一致；parent paint bounds 認得整個 SizedBox 範圍。
		// SizedBox 把 wrapper 撐成全螢幕高 + 父層給的寬，OverflowBox 把氣泡限制
		// 在實際 size 並居中。SizedBox 內氣泡上下方還是 wrapper 範圍，這部份的
		// 點擊應該等同 barrier 點擊（推進到下一步），所以在外層用 GestureDetector
		// 兜底。用 GestureDetector 而非 Listener：onTap 在瀏覽器 click event 觸發、
		// 算 user gesture，requestFullscreen 才不會被拒絕（pointerdown 不算 gesture）。
		return GestureDetector(
			behavior: HitTestBehavior.translucent,
			onTap: onTap,
			child: SizedBox(
				height: MediaQuery.of(context).size.height,
				child: OverflowBox(
					minWidth: 0,
					maxWidth: _bubbleWidth,
					minHeight: 0,
					maxHeight: height,
					child: TutorialBubble(
						text: message,
						leading: ClipRRect(
							borderRadius: BorderRadius.circular(12),
							child: Image.asset(
								"assets/images/ui/app_icon.png",
								width: _iconSize,
								height: _iconSize,
								fit: BoxFit.cover,
							),
						),
						leadingWidth: _iconSize,
						leadingGap: _iconGap,
						width: _bubbleWidth,
						padding: _bubblePadding,
						textStyle: _bubbleTextStyle,
						textAlign: TextAlign.left,
						borderRadius: 16,
						shadowBlur: 16,
						onTap: onTap,
					),
				),
			),
		);
	}
}
