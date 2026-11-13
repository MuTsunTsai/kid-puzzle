import "dart:async";
import "dart:collection";
import "dart:ui" as ui;

import "package:flutter/widgets.dart";
import "package:provider/provider.dart";

import "../../../core/audio/voice_service.dart";
import "../../../core/sprites/sprite_manifest.dart";
import "../../../core/sprites/sprite_registry.dart";
import "../domain/counting_round.dart";
import "../domain/counting_species.dart";

/// 每種動物各自錄製的整句（見 CountingSpecies.id 的說明）。
String howManyVoice(CountingSpecies s) => "assets/audio/voice/counting/how_many_${s.id}.mp3";
String wrongVoice(CountingSpecies s) => "assets/audio/voice/counting/wrong_${s.id}.mp3";

/// 過關語音「答對了！一共有 n 隻！」（n = 1～[kMaxCorrectVoice]，兩段錄音離線接成一個檔，
/// 見 tools/join_voice.py）。
/// 點到已經數過的題目動物：「這隻數過囉！」（所有動物共用）。
const String repeatedVoice = "assets/audio/voice/counting/repeated.mp3";

String correctVoice(int n) => "assets/audio/voice/counting/correct_$n.mp3";
const int kMaxCorrectVoice = 20;

/// 唸數字借用素材的「數字」類別（物件名稱就是 "1"、"2"…）。
const String _numberCategoryId = "number";

/// 練習數數的語音背景載入。
///
/// 網頁版每一句都要下載 + 解碼成 PCM 放在記憶體（45 句約 19 MB），全部載完才開始
/// 會讓第一次進入等很久，所以依「什麼時候會用到」排優先順序，一句一句在背景載：
/// 1. 設定頁一打開：先抽好第一關的題目動物，載它的開場白與數字語音包。
/// 2. 一關開始：這關其他動物的「那是○○喔！」→ 這關答案的過關語音。
/// 3. 同時預先抽好下一關，載下一關要用的。
/// 4. 其餘（其他動物、設定範圍內其他數字的過關語音）排在最後。
/// 用到時還沒載好：開場白 / 過關語音等一下（有上限），點錯就只放音效。
///
/// 設定頁與遊戲頁共用同一個 instance（[of]），載過的不會重載。
class CountingVoiceLoader {
	CountingVoiceLoader._(this._voice, this._registry);

	static CountingVoiceLoader? _instance;

	/// 取得共用的 instance（第一次呼叫時建立）。
	static CountingVoiceLoader of(BuildContext context) =>
			_instance ??= CountingVoiceLoader._(context.read<VoiceService>(), context.read<SpriteRegistry>());

	final VoiceService _voice;
	final SpriteRegistry _registry;

	/// 已開始載的語音 → 載完的 future（載入失敗也算完成，後端會讓該句 no-op）。
	final Map<String, Future<void>> _loads = <String, Future<void>>{};
	final Set<String> _ready = <String>{};

	/// 等著背景載的語音（前面的先載）。
	final Queue<String> _queue = Queue<String>();
	bool _draining = false;

	/// 數字 → 素材「數字」類別裡唸那個數字的物件；數字語音包載好前是空的。
	final Map<int, SpriteItem> numberItems = <int, SpriteItem>{};

	/// 素材「數字」類別的 sheet 圖（過關卡片左邊顯示答案數字）；還沒載到是 null。
	ui.Image? numberSheet;
	Future<void>? _numbers;

	bool isReady(String asset) => _ready.contains(asset);

	/// 立刻載（不排隊），回傳載完的 future。重複呼叫回傳同一個。
	Future<void> ensure(String asset) {
		return _loads[asset] ??= _voice.preloadClip(asset).catchError((Object e) {
			debugPrint("練習數數：語音載入失敗 $asset：$e");
		}).whenComplete(() => _ready.add(asset));
	}

	/// 排進背景載入佇列。[urgent] = 插到最前面（照給的順序）。已載 / 已排的略過
	/// （urgent 時會把已排的往前移）。
	void prefetch(Iterable<String> assets, {bool urgent = false}) {
		final List<String> list = assets.where((String a) => !_loads.containsKey(a)).toList();
		if (urgent) {
			list.forEach(_queue.remove);
			for (final String a in list.reversed) {
				_queue.addFirst(a);
			}
		} else {
			for (final String a in list) {
				if (!_queue.contains(a)) _queue.addLast(a);
			}
		}
		unawaited(_drain());
	}

	/// 一次只載一句：避免同時發一堆請求，跟遊戲本身（3D 模型）搶頻寬。
	Future<void> _drain() async {
		if (_draining) return;
		_draining = true;
		try {
			while (_queue.isNotEmpty) {
				await ensure(_queue.removeFirst());
			}
		} finally {
			_draining = false;
		}
	}

	/// 等 [asset] 載好再播，超過 [limit] 就放棄。回傳有沒有播。
	Future<bool> speakWhenReady(String asset, Duration limit) async {
		if (!isReady(asset)) {
			try {
				await ensure(asset).timeout(limit);
			} on TimeoutException {
				return false;
			}
		}
		_voice.speakClip(asset);
		return true;
	}

	/// 已經載好才播（點錯的「那是○○喔！」：來不及就算了，只有音效）。
	bool speakIfReady(String asset) {
		if (!isReady(asset)) return false;
		_voice.speakClip(asset);
		return true;
	}

	/// 載入素材的數字語音包與數字圖（只做一次）。
	Future<void> loadNumbers() {
		return _numbers ??= () async {
			try {
				if (!_registry.isLoaded) await _registry.load();
				final SpriteCategory? numbers = _registry.categoryById(_numberCategoryId);
				if (numbers == null) return;
				// 數字圖在背景載，不擋語音；沒載到過關卡片就不顯示數字
				unawaited(_registry.atlas.load(numbers.sheet).then((ui.Image img) {
					numberSheet = img;
				}).catchError((Object e) {
					debugPrint("練習數數：數字圖載入失敗：$e");
				}));
				await _registry.preloadVoice(numbers);
				for (final SpriteItem item in numbers.items) {
					final int? n = int.tryParse(item.name);
					if (n != null) numberItems[n] = item;
				}
			} catch (e) {
				debugPrint("練習數數：數字語音載入失敗：$e");
			}
		}();
	}

	/// 一關要用到的語音，依用到的先後：開場白 → 數過了 → 點錯（這關出現的其他動物）→ 過關。
	static List<String> voicesOf(CountingRoster roster) => <String>[
		howManyVoice(roster.target),
		repeatedVoice,
		for (final (CountingSpecies s, _) in roster.distractors) wrongVoice(s),
		if (roster.targetCount <= kMaxCorrectVoice) correctVoice(roster.targetCount),
	];

	/// 最後才載的其餘語音：所有動物的開場白與點錯、設定範圍內的過關語音。
	static List<String> remainingVoices(int targetMin, int targetMax) => <String>[
		for (final CountingSpecies s in kCountingSpecies) ...<String>[howManyVoice(s), wrongVoice(s)],
		for (int n = targetMin; n <= targetMax && n <= kMaxCorrectVoice; n++) correctVoice(n),
	];
}
