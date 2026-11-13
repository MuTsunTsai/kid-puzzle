import "dart:math";

import "package:flutter_test/flutter_test.dart";
import "package:kid_puzzle/features/counting/domain/counting_round.dart";
import "package:kid_puzzle/features/counting/domain/counting_species.dart";

void main() {
	group("CountingRound（點完自動過關）", () {
		test("依序數到最後一隻就過關", () {
			final CountingRound r = CountingRound(targetCount: 3, mode: CountingAnswerMode.autoComplete);
			final CountingTapResult a = r.tap(10, isTarget: true);
			expect(a, isA<CountingTapCounted>().having((CountingTapCounted c) => c.number, "number", 1));
			expect((a as CountingTapCounted).isLast, isFalse);
			r.tap(11, isTarget: true);
			final CountingTapResult c = r.tap(12, isTarget: true);
			expect((c as CountingTapCounted).number, 3);
			expect(c.isLast, isTrue);
			expect(r.phase, CountingPhase.completed);
			expect(r.numberOf(11), 2);
		});

		test("重複點同一隻不會多算", () {
			final CountingRound r = CountingRound(targetCount: 2, mode: CountingAnswerMode.autoComplete);
			r.tap(1, isTarget: true);
			final CountingTapResult again = r.tap(1, isTarget: true);
			expect(again, isA<CountingTapRepeated>().having((CountingTapRepeated x) => x.number, "number", 1));
			expect(r.counted, 1);
			expect(r.repeatTaps, 1);
			expect(r.phase, CountingPhase.counting);
		});

		test("點錯種類只記次數", () {
			final CountingRound r = CountingRound(targetCount: 2, mode: CountingAnswerMode.autoComplete);
			expect(r.tap(5, isTarget: false), isA<CountingTapWrongSpecies>());
			expect(r.wrongSpeciesTaps, 1);
			expect(r.counted, 0);
		});

		test("過關後點擊一律忽略", () {
			final CountingRound r = CountingRound(targetCount: 1, mode: CountingAnswerMode.autoComplete);
			r.tap(1, isTarget: true);
			expect(r.tap(2, isTarget: false), isA<CountingTapIgnored>());
			expect(r.wrongSpeciesTaps, 0);
			expect(r.answer(1), CountingAnswerResult.ignored);
		});
	});

	group("CountingRound（點完再選數字）", () {
		test("全部點完進入作答，選對才過關", () {
			final CountingRound r =
					CountingRound(targetCount: 3, mode: CountingAnswerMode.chooseNumber, random: Random(1));
			expect(r.answer(3), CountingAnswerResult.ignored);
			r.tap(1, isTarget: true);
			r.tap(2, isTarget: true);
			r.tap(3, isTarget: true);
			expect(r.phase, CountingPhase.answering);
			expect(r.choices, contains(3));
			expect(r.tap(4, isTarget: true), isA<CountingTapIgnored>());
			final int wrong = r.choices.firstWhere((int v) => v != 3);
			expect(r.answer(wrong), CountingAnswerResult.wrong);
			expect(r.wrongAnswers, 1);
			expect(r.phase, CountingPhase.answering);
			expect(r.answer(3), CountingAnswerResult.correct);
			expect(r.phase, CountingPhase.completed);
		});
	});

	group("answerChoices", () {
		test("包含答案、彼此不同、由小到大、都 ≥ 1", () {
			for (int seed = 0; seed < 200; seed++) {
				final Random rnd = Random(seed);
				for (int correct = 1; correct <= 8; correct++) {
					final List<int> c = CountingRound.answerChoices(correct, rnd);
					expect(c.length, 3);
					expect(c.toSet().length, 3);
					expect(c, contains(correct));
					expect(c.every((int v) => v >= 1), isTrue);
					expect(c, orderedEquals(<int>[...c]..sort()));
				}
			}
		});

		test("答案在下限附近時往上補", () {
			final List<int> c = CountingRound.answerChoices(1, Random(3), count: 4, spread: 1);
			expect(c, <int>[1, 2, 3, 4]);
		});
	});

	group("CountingRoster.random", () {
		test("題目與其他動物的數量都在範圍內、其他動物不會是題目動物", () {
			final Set<int> seenTarget = <int>{};
			final Set<int> seenOthers = <int>{};
			for (int seed = 0; seed < 500; seed++) {
				final CountingRoster r =
						CountingRoster.random(Random(seed), minTarget: 2, maxTarget: 5, minOthers: 1, maxOthers: 4);
				expect(r.targetCount, inInclusiveRange(2, 5));
				seenTarget.add(r.targetCount);
				final int others = r.distractors.fold(0, (int s, (CountingSpecies, int) e) => s + e.$2);
				expect(others, inInclusiveRange(1, 4));
				seenOthers.add(others);
				final List<CountingSpecies> kinds = r.distractors.map(((CountingSpecies, int) e) => e.$1).toList();
				expect(kinds.toSet().length, kinds.length, reason: "同一種要合併成一筆");
				expect(kinds.contains(r.target), isFalse);
				expect(r.total, r.targetCount + others);
				expect(r.entries.first.$1, same(r.target));
			}
			expect(seenTarget, <int>{2, 3, 4, 5});
			expect(seenOthers, <int>{1, 2, 3, 4});
		});

		test("指定題目動物時照用，其他動物不會是牠", () {
			final CountingSpecies t = kCountingSpecies[3];
			for (int seed = 0; seed < 50; seed++) {
				final CountingRoster r = CountingRoster.random(Random(seed), target: t, minOthers: 5, maxOthers: 10);
				expect(r.target, same(t));
				expect(r.distractors.every(((CountingSpecies, int) e) => !identical(e.$1, t)), isTrue);
			}
		});

		test("其他動物 0 隻", () {
			final CountingRoster r = CountingRoster.random(Random(1), minTarget: 1, maxTarget: 1, minOthers: 0, maxOthers: 0);
			expect(r.targetCount, 1);
			expect(r.distractors, isEmpty);
			expect(r.total, 1);
		});
	});

	test("動物種類表：代號不重複、縮放範圍合理", () {
		expect(kCountingSpecies.map((CountingSpecies s) => s.id).toSet().length, kCountingSpecies.length);
		for (final CountingSpecies s in kCountingSpecies) {
			expect(s.maxScale, greaterThanOrEqualTo(s.minScale));
			expect(s.modelPath, startsWith("assets/models/"));
		}
	});
}
