import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:kid_puzzle/features/counting/domain/counting_round.dart";
import "package:kid_puzzle/features/counting/domain/counting_species.dart";
import "package:kid_puzzle/features/counting/presentation/counting_voice_loader.dart";

void main() {
	final CountingSpecies fox = kCountingSpecies.firstWhere((CountingSpecies s) => s.id == "fox");
	final CountingSpecies pig = kCountingSpecies.firstWhere((CountingSpecies s) => s.id == "pig");
	final CountingSpecies bear = kCountingSpecies.firstWhere((CountingSpecies s) => s.id == "bear");

	test("一關的語音依用到的先後：開場白 → 點錯 → 過關", () {
		final CountingRoster r = CountingRoster(
			target: fox,
			targetCount: 3,
			distractors: <(CountingSpecies, int)>[(pig, 2), (bear, 1)],
		);
		expect(CountingVoiceLoader.voicesOf(r), <String>[
			"assets/audio/voice/counting/how_many_fox.mp3",
			"assets/audio/voice/counting/repeated.mp3",
			"assets/audio/voice/counting/wrong_pig.mp3",
			"assets/audio/voice/counting/wrong_bear.mp3",
			"assets/audio/voice/counting/correct_3.mp3",
		]);
	});

	test("超過錄音範圍的數字沒有過關語音", () {
		final CountingRoster r = CountingRoster(
			target: fox,
			targetCount: kMaxCorrectVoice + 1,
			distractors: const <(CountingSpecies, int)>[],
		);
		expect(CountingVoiceLoader.voicesOf(r), <String>[
			"assets/audio/voice/counting/how_many_fox.mp3",
			"assets/audio/voice/counting/repeated.mp3",
		]);
	});

	test("其餘語音：所有動物 + 只到設定範圍內的過關語音", () {
		final List<String> v = CountingVoiceLoader.remainingVoices(2, 5);
		expect(v.where((String a) => a.contains("/how_many_")).length, kCountingSpecies.length);
		expect(v.where((String a) => a.contains("/wrong_")).length, kCountingSpecies.length);
		expect(v.where((String a) => a.contains("/correct_")).toList(), <String>[
			for (int n = 2; n <= 5; n++) "assets/audio/voice/counting/correct_$n.mp3",
		]);
	});

	test("每種動物的語音檔都存在", () {
		for (final CountingSpecies s in kCountingSpecies) {
			for (final String a in <String>[howManyVoice(s), wrongVoice(s)]) {
				expect(_exists(a), isTrue, reason: a);
			}
		}
		expect(_exists(repeatedVoice), isTrue);
		for (int n = 1; n <= kMaxCorrectVoice; n++) {
			expect(_exists(correctVoice(n)), isTrue, reason: "correct_$n");
		}
	});
}

bool _exists(String asset) => File(asset).existsSync();
