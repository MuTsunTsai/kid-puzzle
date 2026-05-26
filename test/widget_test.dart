import "package:flutter_test/flutter_test.dart";
import "package:kid_puzzle/app.dart";

void main() {
	testWidgets("首頁能正常顯示「開始拼圖」按鈕與標題", (WidgetTester tester) async {
		await tester.pumpWidget(const KidPuzzleApp());
		await tester.pumpAndSettle();

		expect(find.text("開始拼圖"), findsOneWidget);
		expect(find.text("幼兒益智遊戲"), findsOneWidget);
	});
}
