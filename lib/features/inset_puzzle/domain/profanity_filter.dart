import "dart:ui";

import "../../../core/sprites/sprite_manifest.dart";

/// 嵌入拼圖的「不雅單字」偵測。
///
/// 問題：英文字母類別把字母 sprite 散落在 board 上、物理收斂後可能巧合形成
/// 「FUCK」「SHIT」之類的橫排組合，幼兒看到不雅。
///
/// 偵測策略：對每片算 piece center、依 y 軸分群成橫排、每排內按 x 排序、
/// 找出「連續且 x 間距合理」的子序列、把 displayName 串成字串、查黑名單。
///
/// 註解上的設計選擇：
/// - 只查 forward（左→右）。reverse（KCUF）對幼兒不會被自然讀出、不檢查。
/// - 黑名單刻意保守、僅含主流髒字 + 3-letter / 爭議詞（依使用者偏好）。
///
/// 觸發頻率（實測）：把 12 個字母**排成一列**（最悲觀情境、實際遊戲是
/// 4×3 網格、每排只 3~4 個字母、機率低 1~2 個數量級）餵進偵測：
/// - 26 大寫無放回抽 12：1000 次中觸發 5 次（0.5%）
/// - 52 大小寫無放回抽 12：1000 次中觸發 6 次（0.6%）
/// 真實遊戲估計 < 0.2%。retry 上限 8 次連續全部命中的機率 ≈ 10^-18、
/// 永遠不會撞到 fallback、可放心保留 retry 機制。
class ProfanityFilter {
	const ProfanityFilter._();

	/// 黑名單（已 lower-case；偵測時把候選字串轉小寫再比對）。
	///
	/// 來源：手挑自
	/// https://github.com/coffee-and-fun/google-profanity-words（Google 自家
	/// 用的保守版本）。過濾條件：
	/// - 純 a-z（去掉網路俚語拼法 fcuk / phuck、縮寫 lmfao / bbw 等）
	/// - 長度 3~5（更長的字幾乎不可能在 12 片內偶然形成）
	/// - 真實的英文單字（去 fukwit / cyalis / dvda 這類）
	/// - 種族 / 仇恨字眼也納入（孩子不該看到、即便是巧合）
	///
	/// 沒有 substring 衝突問題：3 字的 ass 會把 "asses" 也 catch、所以不需要
	/// 重複加。
	static const Set<String> _blacklist = <String>{
		// 3-letter
		"ass", "cum", "fag", "gay", "hoe", "jap", "jiz", "nob",
		"pis", "poo", "sex", "tit", "vag",
		// 4-letter（最大宗、最容易在橫排中形成）
		"anal", "anus", "arse", "butt", "clit", "cock", "coon", "crap",
		"cunt", "damn", "dick", "dike", "dink", "fart", "feck", "fuck",
		"gook", "hell", "homo", "jerk", "jism", "kike",	"kock", "kunt",
		"lust", "milf", "muff", "nazi", "nude", "orgy", "paki", "puss",
		"quim", "rape", "scat", "shag", "shit", "slut", "smut", "spic",
		"suck", "turd", "twat", "wang", "wank",
		// 5-letter
		"bitch", "boobs", "booty", "dildo", "nigga", "prick", "queef",
		"queer", "tramp", "whore",
	};

	/// 同一橫排的 y 軸容差（以 tile 為單位的比例）。
	/// 中心 y 差距 ≤ tile × 此值 → 視為同排。
	static const double _rowToleranceFactor = 0.5;

	/// 橫向「相鄰」的 x 軸最大間距（以 tile 為單位的比例）。
	/// 相鄰兩片中心 x 差距 ≤ tile × 此值 → 視為連續。
	/// 1.5 = 相鄰兩片之間最多容許 0.5 tile 的空隙。
	static const double _adjacencyFactor = 1.5;

	/// 偵測 [centers] / [items] 配對下是否出現不雅排列。
	///
	/// [centers[i]] 與 [items[i]] 一一對應。`tile` 是每片的邊長（pixel）。
	///
	/// 回傳 `true` 表示**有**不雅排列、呼叫端應重抽 / 重 layout。
	static bool detect({
		required List<Offset> centers,
		required List<SpriteItem> items,
		required double tile,
	}) {
		if (centers.length != items.length || centers.length < 2) return false;
		if (tile <= 0) return false;

		// 1. 取「顯示文字 = 單一字母」的 item index（其他類別物件名稱常是中文
		//    / 整個單字、不會構成英文連續排列、直接略過）。
		final List<int> letterIdx = <int>[];
		for (int i = 0; i < items.length; i++) {
			final String name = _displayName(items[i]);
			if (name.length == 1 && _isAsciiLetter(name.codeUnitAt(0))) {
				letterIdx.add(i);
			}
		}
		if (letterIdx.length < 3) return false; // 黑名單最短 3 字

		// 2. 依 y 分群成橫排。用 simple greedy：對 y 排序、相鄰 y 差 ≤ 容差就
		//    歸同一排。
		final double yTol = tile * _rowToleranceFactor;
		final List<int> byY = List<int>.of(letterIdx)
			..sort((int a, int b) => centers[a].dy.compareTo(centers[b].dy));
		final List<List<int>> rows = <List<int>>[];
		for (final int i in byY) {
			if (rows.isNotEmpty &&
					(centers[i].dy - centers[rows.last.last].dy).abs() <= yTol) {
				rows.last.add(i);
			} else {
				rows.add(<int>[i]);
			}
		}

		// 3. 每排內按 x 排序、找連續且相鄰間距 ≤ tile × _adjacencyFactor
		//    的子序列、把 displayName 串接、檢查黑名單。
		final double xMaxGap = tile * _adjacencyFactor;
		for (final List<int> row in rows) {
			if (row.length < 3) continue;
			row.sort((int a, int b) => centers[a].dx.compareTo(centers[b].dx));
			final StringBuffer run = StringBuffer();
			run.write(_displayName(items[row.first]).toLowerCase());
			for (int k = 1; k < row.length; k++) {
				final double gap =
						(centers[row[k]].dx - centers[row[k - 1]].dx).abs();
				if (gap <= xMaxGap) {
					run.write(_displayName(items[row[k]]).toLowerCase());
				} else {
					// 中斷：先檢查目前 run、再從新字母重起一段
					if (_containsBlacklisted(run.toString())) return true;
					run
						..clear()
						..write(_displayName(items[row[k]]).toLowerCase());
				}
			}
			if (_containsBlacklisted(run.toString())) return true;
		}
		return false;
	}

	static String _displayName(SpriteItem item) => item.name;

	static bool _isAsciiLetter(int c) =>
			(c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);

	static bool _containsBlacklisted(String s) {
		if (s.length < 3) return false;
		for (final String w in _blacklist) {
			if (s.contains(w)) return true;
		}
		return false;
	}
}
