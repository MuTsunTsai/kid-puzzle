import "package:flutter/material.dart";

/// 選數字作答：一排大圓形數字按鈕。
class AnswerChoices extends StatelessWidget {
	const AnswerChoices({super.key, required this.choices, required this.onChoose});

	final List<int> choices;
	final ValueChanged<int> onChoose;

	@override
	Widget build(BuildContext context) {
		return Row(
			mainAxisSize: MainAxisSize.min,
			children: <Widget>[
				for (final int n in choices)
					Padding(
						padding: const EdgeInsets.symmetric(horizontal: 10),
						// 按下的瞬間就算（Listener.onPointerDown）：按鈕的 onPressed 要放開才觸發，
						// 手指滑動一點就取消，幼兒常常按了沒反應。按鈕本身只負責外觀與水波紋
						child: Listener(
							onPointerDown: (_) => onChoose(n),
							child: SizedBox(
								width: 84,
								height: 84,
								child: FilledButton(
									style: FilledButton.styleFrom(
										shape: const CircleBorder(),
										padding: EdgeInsets.zero,
										backgroundColor: const Color(0xFFFFB74D),
										foregroundColor: const Color(0xFF5D4037),
										elevation: 4,
									),
									onPressed: () {},
									child: Text("$n", style: const TextStyle(fontSize: 40, fontWeight: FontWeight.bold)),
								),
							),
						),
					),
			],
		);
	}
}
