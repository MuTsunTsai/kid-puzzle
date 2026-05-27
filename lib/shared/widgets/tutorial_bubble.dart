import "package:flutter/material.dart";

/// 教學氣泡卡：白底圓角陰影、上下輕微飄動引導視線。
///
/// 自己用 TextPainter 量高度再固定 SizedBox，避開 showcaseview 5.0.x 用
/// dry layout size 做 tightFor 最終 layout 時、Text 高度被算成單行而裁字。
/// 字型 ready 前不要顯示（[FontReadyProbe] 已處理）— 否則 TextPainter
/// 對中文字會量到 fallback tofu 寬度而 layout 失效。
///
/// 飄動動畫由自身的 AnimationController 跑、AnimatedBuilder 只重建外層
/// Transform、內層用 RepaintBoundary 保護氣泡內容只 raster 一次。
class TutorialBubble extends StatefulWidget {
	const TutorialBubble({
		super.key,
		required this.text,
		this.leading,
		this.leadingWidth = 0,
		this.leadingGap = 16,
		this.width = 300,
		this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
		this.textStyle = const TextStyle(
			fontSize: 16,
			color: Colors.black87,
			height: 1.5,
		),
		this.textAlign = TextAlign.start,
		this.borderRadius = 12,
		this.shadowBlur = 12,
		this.slideDistance = 6,
		this.slidePeriod = const Duration(milliseconds: 2400),
		this.onTap,
	});

	final String text;

	/// 文字左側的可選 widget（例如圖示）。
	final Widget? leading;

	/// [leading] 的寬度。需明確指定，內部 TextPainter 才能正確算文字 maxWidth。
	final double leadingWidth;

	/// [leading] 與文字之間的間距。
	final double leadingGap;

	final double width;
	final EdgeInsets padding;
	final TextStyle textStyle;
	final TextAlign textAlign;
	final double borderRadius;
	final double shadowBlur;

	/// 上下飄動振幅（px）。0 等於關掉飄動。
	final double slideDistance;
	final Duration slidePeriod;

	/// 點氣泡本身時的 callback。用 [Listener] 接 pointer-down（不參與 gesture
	/// arena），避開套件外層 GestureDetector(onTap: null) 攔截事件導致桌機 click
	/// 無反應的問題。null 時氣泡不接事件。
	final VoidCallback? onTap;

	/// 量出氣泡實際渲染高度（含 padding），跟 build 時一致。
	///
	/// 給呼叫端在 layout 前需要知道氣泡高度的場景用（例如算 [Transform.translate]
	/// 的 offset 把氣泡視覺往上偏自身一半高度）。
	static double computeHeight(
		BuildContext context, {
		required String text,
		required double width,
		EdgeInsets padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
		TextStyle textStyle = const TextStyle(
			fontSize: 16,
			color: Colors.black87,
			height: 1.5,
		),
		TextAlign textAlign = TextAlign.start,
		double leadingWidth = 0,
		double leadingGap = 16,
		bool hasLeading = false,
	}) {
		final double reserve = hasLeading ? leadingWidth + leadingGap : 0;
		final TextPainter painter = TextPainter(
			text: TextSpan(text: text, style: textStyle),
			textDirection: TextDirection.ltr,
			textScaler: MediaQuery.textScalerOf(context),
			textAlign: textAlign,
		)..layout(maxWidth: width - padding.horizontal - reserve);
		return painter.height + padding.vertical;
	}

	@override
	State<TutorialBubble> createState() => _TutorialBubbleState();
}

class _TutorialBubbleState extends State<TutorialBubble>
		with SingleTickerProviderStateMixin {
	late final AnimationController _controller;
	late final Animation<double> _animation;

	@override
	void initState() {
		super.initState();
		_controller = AnimationController(
			vsync: this,
			duration: widget.slidePeriod,
		);
		if (widget.slideDistance > 0) {
			_controller.repeat(reverse: true);
		}
		_animation = CurvedAnimation(
			parent: _controller,
			curve: Curves.easeInOut,
		);
	}

	@override
	void dispose() {
		_controller.dispose();
		super.dispose();
	}

	@override
	Widget build(BuildContext context) {
		// 有 leading 時：text 可用寬 = bubble 內距寬 - leading 寬 - leading 間距
		final double leadingReserve = widget.leading == null
				? 0
				: widget.leadingWidth + widget.leadingGap;
		final double textMaxWidth =
				widget.width - widget.padding.horizontal - leadingReserve;

		final TextPainter painter = TextPainter(
			text: TextSpan(text: widget.text, style: widget.textStyle),
			textDirection: TextDirection.ltr,
			textScaler: MediaQuery.textScalerOf(context),
			textAlign: widget.textAlign,
		)..layout(maxWidth: textMaxWidth);

		// 卡片高度取 text 與 leading 兩者之中較高者；leading 高度由它自己決定
		// （由呼叫端用 SizedBox 之類包好），這裡不強制。但常見情況是圖示比文字高，
		// padding 留好 → 用 IntrinsicHeight 包 Row 讓兩邊垂直置中。
		final double textHeight = painter.height + widget.padding.vertical;

		Widget content = Text(
			widget.text,
			style: widget.textStyle,
			textAlign: widget.textAlign,
		);
		if (widget.leading != null) {
			content = Row(
				mainAxisSize: MainAxisSize.min,
				crossAxisAlignment: CrossAxisAlignment.center,
				children: <Widget>[
					SizedBox(width: widget.leadingWidth, child: widget.leading),
					SizedBox(width: widget.leadingGap),
					Expanded(child: content),
				],
			);
		}

		// 內層氣泡卡片：放在 RepaintBoundary 內，飄動時不會重畫。
		// 不寫死 height（讓 leading 比 text 高時也能撐開）；但給 minHeight 保底。
		Widget card = RepaintBoundary(
			child: ConstrainedBox(
				constraints: BoxConstraints(
					minWidth: widget.width,
					maxWidth: widget.width,
					minHeight: textHeight,
				),
				child: DecoratedBox(
					decoration: BoxDecoration(
						color: Colors.white,
						borderRadius: BorderRadius.circular(widget.borderRadius),
						boxShadow: <BoxShadow>[
							BoxShadow(
								color: Colors.black.withValues(alpha: 0.2),
								blurRadius: widget.shadowBlur,
								offset: const Offset(0, 4),
							),
						],
					),
					child: Padding(
						padding: widget.padding,
						child: content,
					),
				),
			),
		);

		// 點擊推進：用 GestureDetector.onTap 而非 Listener.onPointerDown。
		// 原因：web 上 requestFullscreen 等 API 要求 "user gesture"，但 pointer-down
		// 不算（只有 click / touchend 算）。GestureDetector 內部 tap recognizer 等
		// release 才觸發 onTap、剛好對應瀏覽器 click event，在 user gesture context 內。
		// 套件外層的 GestureDetector(onTap: null) 不註冊 tap recognizer、不會搶 arena。
		if (widget.onTap != null) {
			card = MouseRegion(
				cursor: SystemMouseCursors.click,
				child: GestureDetector(
					behavior: HitTestBehavior.opaque,
					onTap: widget.onTap,
					child: card,
				),
			);
		}

		if (widget.slideDistance <= 0) return card;

		return AnimatedBuilder(
			animation: _animation,
			builder: (BuildContext _, Widget? child) => Transform.translate(
				// 動畫值 0..1 對應「向下 slideDistance」到「向上 slideDistance」
				offset:
						Offset(0, (_animation.value - 0.5) * 2 * -widget.slideDistance),
				child: child,
			),
			child: card,
		);
	}
}
