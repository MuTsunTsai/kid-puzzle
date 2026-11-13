import "package:flutter_test/flutter_test.dart";
import "package:kid_puzzle/features/counting/domain/occlusion.dart";

ScreenProxy proxy(double cx, double cy, double r, double depth, String kind) =>
		ScreenProxy(cx: cx, cy: cy, rx: r, ry: r, depth: depth, kind: kind);

void main() {
	test("沒有東西擋住：全部看得到", () {
		final ScreenProxy t = proxy(0, 0, 1, 10, "fox");
		expect(visibleFraction(t, <ScreenProxy>[t, proxy(5, 0, 1, 5, "bear")]), 1);
	});

	test("前面的大動物整個蓋住：看不到", () {
		final ScreenProxy t = proxy(0, 0, 1, 10, "fox");
		expect(visibleFraction(t, <ScreenProxy>[proxy(0, 0, 3, 5, "bear")]), 0);
	});

	test("在後面的動物不算遮擋", () {
		final ScreenProxy t = proxy(0, 0, 1, 10, "fox");
		expect(visibleFraction(t, <ScreenProxy>[proxy(0, 0, 3, 15, "bear")]), 1);
	});

	test("被同類擋住不算", () {
		final ScreenProxy t = proxy(0, 0, 1, 10, "fox");
		expect(visibleFraction(t, <ScreenProxy>[proxy(0, 0, 3, 5, "fox")]), 1);
	});

	test("蓋住一半左右", () {
		final ScreenProxy t = proxy(0, 0, 1, 10, "fox");
		// 中心在右邊很遠的大圓，左緣剛好切過 t 的中線
		final double v = visibleFraction(t, <ScreenProxy>[proxy(100, 0, 100, 5, "bear")], grid: 40);
		expect(v, closeTo(0.5, 0.05));
	});

	test("只看題目動物、取最差的那隻", () {
		final List<ScreenProxy> all = <ScreenProxy>[
			proxy(0, 0, 1, 10, "fox"),
			proxy(10, 0, 1, 10, "fox"),
			proxy(10, 0, 3, 5, "bear"),
		];
		expect(minTargetVisibility(all, (int i) => all[i].kind == "fox"), 0);
		// 熊本身被擋住不影響（不是題目）
		expect(minTargetVisibility(all, (int i) => i == 0), 1);
	});
}
