import "dart:math";

import "counting_species.dart";

/// 作答方式（家長頁切換）。
enum CountingAnswerMode {
	/// 每點一隻題目動物就唸出累計數字，全部點完自動過關。
	autoComplete,

	/// 點的時候只做記號、不唸數字；全部點完後從幾個數字裡選答案，選對才過關。
	chooseNumber,
}

/// 關卡進行到哪裡。
enum CountingPhase {
	/// 還有題目動物沒點到。
	counting,

	/// 題目動物都點過了，等待選數字（只有 [CountingAnswerMode.chooseNumber]）。
	answering,

	/// 過關。
	completed,
}

/// 一關的動物名單：題目動物幾隻、干擾動物各幾隻。
class CountingRoster {
	const CountingRoster({required this.target, required this.targetCount, required this.distractors});

	final CountingSpecies target;
	final int targetCount;

	/// 干擾動物（都不是 [target]）與各自的數量。
	final List<(CountingSpecies, int)> distractors;

	/// 依出場順序的完整名單（題目動物在前）。
	List<(CountingSpecies, int)> get entries => <(CountingSpecies, int)>[(target, targetCount), ...distractors];

	int get total => entries.fold(0, (int s, (CountingSpecies, int) e) => s + e.$2);

	/// 隨機出題：從 [pool] 抽一種題目動物 [minTarget]～[maxTarget] 隻，
	/// 其他動物共 [minOthers]～[maxOthers] 隻，每隻隨機挑一種（可重複、不會是題目動物）。
	/// [target]：指定題目動物（呼叫端用 CooldownPicker 抽，最近出過的不會馬上再出）；
	/// 不給就從 [pool] 均勻抽。
	static CountingRoster random(
		Random random, {
		CountingSpecies? target,
		List<CountingSpecies> pool = kCountingSpecies,
		int minTarget = 1,
		int maxTarget = 7,
		int minOthers = 0,
		int maxOthers = 3,
	}) {
		assert(pool.length >= 2, "動物種類不夠出題");
		assert(minTarget >= 1 && maxTarget >= minTarget);
		assert(minOthers >= 0 && maxOthers >= minOthers);
		final CountingSpecies t = target ?? pool[random.nextInt(pool.length)];
		final List<CountingSpecies> others = pool.where((CountingSpecies s) => !identical(s, t)).toList();
		final int targetCount = minTarget + random.nextInt(maxTarget - minTarget + 1);
		final int otherCount = minOthers + random.nextInt(maxOthers - minOthers + 1);
		// 依抽到的先後保持順序（Map 的插入順序），同一種合併成一筆
		final Map<CountingSpecies, int> counts = <CountingSpecies, int>{};
		for (int i = 0; i < otherCount; i++) {
			final CountingSpecies s = others[random.nextInt(others.length)];
			counts[s] = (counts[s] ?? 0) + 1;
		}
		return CountingRoster(
			target: t,
			targetCount: targetCount,
			distractors: <(CountingSpecies, int)>[
				for (final MapEntry<CountingSpecies, int> e in counts.entries) (e.key, e.value),
			],
		);
	}
}

/// [CountingRound.tap] 的結果。
sealed class CountingTapResult {
	const CountingTapResult();
}

/// 點擊被忽略（不在數數階段，例如已經過關或正在選數字）。
class CountingTapIgnored extends CountingTapResult {
	const CountingTapIgnored();
}

/// 數到一隻新的題目動物。[number] = 第幾隻（1 起算）；[isLast] = 題目動物都數完了。
class CountingTapCounted extends CountingTapResult {
	const CountingTapCounted(this.number, {required this.isLast});
	final int number;
	final bool isLast;
}

/// 這隻題目動物已經數過了。
class CountingTapRepeated extends CountingTapResult {
	const CountingTapRepeated(this.number);

	/// 牠當初是第幾隻。
	final int number;
}

/// 點到的不是題目動物。
class CountingTapWrongSpecies extends CountingTapResult {
	const CountingTapWrongSpecies();
}

/// [CountingRound.answer] 的結果。
enum CountingAnswerResult {
	/// 不在作答階段。
	ignored,
	correct,
	wrong,
}

/// 一關數數看的狀態機（不含任何 3D / UI / 計時）。
///
/// 動物以 [int] 代號識別（由頁面指定，例如在場上的索引）；頁面負責判斷點到哪一隻、
/// 是不是題目動物，這裡只管數到第幾隻、何時過關，並累計 Analytics 用的次數。
class CountingRound {
	CountingRound({required this.targetCount, required this.mode, Random? random})
			: assert(targetCount >= 1),
				_random = random ?? Random();

	/// 題目動物的數量（也就是正確答案）。
	final int targetCount;
	final CountingAnswerMode mode;
	final Random _random;

	CountingPhase _phase = CountingPhase.counting;
	CountingPhase get phase => _phase;

	/// 動物代號 → 第幾隻（1 起算）。
	final Map<int, int> _numbers = <int, int>{};

	/// 已經數了幾隻。
	int get counted => _numbers.length;

	/// 這隻是第幾隻；還沒數過回傳 null。
	int? numberOf(int animalId) => _numbers[animalId];

	/// 選數字階段的選項（由小到大）；進入 [CountingPhase.answering] 時決定，之後不變。
	List<int> get choices => _choices;
	List<int> _choices = const <int>[];

	/// 點錯動物的次數。
	int wrongSpeciesTaps = 0;

	/// 點到已經數過的動物的次數。
	int repeatTaps = 0;

	/// 選錯數字的次數。
	int wrongAnswers = 0;

	CountingTapResult tap(int animalId, {required bool isTarget}) {
		if (_phase != CountingPhase.counting) return const CountingTapIgnored();
		if (!isTarget) {
			wrongSpeciesTaps++;
			return const CountingTapWrongSpecies();
		}
		final int? n = _numbers[animalId];
		if (n != null) {
			repeatTaps++;
			return CountingTapRepeated(n);
		}
		final int number = _numbers.length + 1;
		_numbers[animalId] = number;
		final bool isLast = number == targetCount;
		if (isLast) {
			if (mode == CountingAnswerMode.autoComplete) {
				_phase = CountingPhase.completed;
			} else {
				_phase = CountingPhase.answering;
				_choices = answerChoices(targetCount, _random);
			}
		}
		return CountingTapCounted(number, isLast: isLast);
	}

	CountingAnswerResult answer(int value) {
		if (_phase != CountingPhase.answering) return CountingAnswerResult.ignored;
		if (value == targetCount) {
			_phase = CountingPhase.completed;
			return CountingAnswerResult.correct;
		}
		wrongAnswers++;
		return CountingAnswerResult.wrong;
	}

	/// 選數字的選項：正確答案加上 [count] - 1 個不同的干擾數字，都 ≥ [minValue]，
	/// 由小到大排列。干擾數字取在答案附近（±[spread] 以內），太接近 [minValue]
	/// 擠不下時往上補。
	static List<int> answerChoices(int correct, Random random, {int count = 3, int minValue = 1, int spread = 2}) {
		assert(count >= 1 && correct >= minValue);
		final Set<int> out = <int>{correct};
		final List<int> near = <int>[
			for (int v = max(minValue, correct - spread); v <= correct + spread; v++)
				if (v != correct) v,
		]..shuffle(random);
		for (final int v in near) {
			if (out.length >= count) break;
			out.add(v);
		}
		// 範圍內不夠（spread 很小時）：從答案往上補
		for (int v = correct + spread + 1; out.length < count; v++) {
			out.add(v);
		}
		return out.toList()..sort();
	}
}
