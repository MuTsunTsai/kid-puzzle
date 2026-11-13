import "package:flutter_test/flutter_test.dart";
import "package:kid_puzzle/features/counting/domain/adaptive_quality.dart";

/// 用固定幀率跑 [seconds] 秒，回傳降級了幾次。
int run(AdaptiveQuality q, double fps, double seconds) {
	int drops = 0;
	for (double t = 0; t < seconds; t += 1 / fps) {
		if (q.addFrame(1 / fps)) drops++;
	}
	return drops;
}

void main() {
	test("夠快就不降", () {
		final AdaptiveQuality q = AdaptiveQuality(maxLevel: 4);
		expect(run(q, 60, 30), 0);
		expect(q.level, 0);
	});

	test("太慢就一級一級降，降到底為止", () {
		final AdaptiveQuality q = AdaptiveQuality(maxLevel: 3);
		run(q, 20, 60);
		expect(q.level, 3);
	});

	test("每次降級後先等一下才再量", () {
		final AdaptiveQuality q = AdaptiveQuality(maxLevel: 4, settle: 1.5, window: 2);
		// 一開始沒有 settle：量滿 2 秒降一級
		expect(run(q, 20, 2.1), 1);
		// 接著 1.5 秒 settle + 2 秒量測：3 秒內不會再降
		expect(run(q, 20, 3), 0);
		expect(run(q, 20, 0.6), 1);
	});

	test("restart 之後的卡頓不算", () {
		final AdaptiveQuality q = AdaptiveQuality(maxLevel: 4, settle: 1.5)..restart();
		expect(run(q, 10, 1.4), 0);
		expect(run(q, 60, 10), 0);
		expect(q.level, 0);
	});

	test("單幀超長（切背景）不算", () {
		final AdaptiveQuality q = AdaptiveQuality(maxLevel: 4);
		for (int i = 0; i < 20; i++) {
			expect(q.addFrame(5), isFalse);
		}
		expect(q.level, 0);
	});
}
