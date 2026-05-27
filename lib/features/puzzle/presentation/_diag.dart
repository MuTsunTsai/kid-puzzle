// 「過關後當機」診斷用 trace 工具。
//
// release build 也會印（用 print，瀏覽器 console 仍會收到）。
// 復現後查完問題請務必把 [kDiagTrace] 改回 false，避免 production log 噪音。

const bool kDiagTrace = true;

/// Build 標記：用來分辨使用者瀏覽器是不是真的拿到最新的 build。
/// 每次部署前手動 bump（或改成有意義的字串、例如時間戳）。
const String kDiagBuildTag = "diag-v5-skip-simplify";

void diag(String msg) {
	if (!kDiagTrace) return;
	final DateTime t = DateTime.now();
	final String hms =
			"${t.hour.toString().padLeft(2, '0')}:"
			"${t.minute.toString().padLeft(2, '0')}:"
			"${t.second.toString().padLeft(2, '0')}."
			"${t.millisecond.toString().padLeft(3, '0')}";
	// 用 print 而不是 debugPrint：debugPrint 在 web 上會被 throttle，
	// 我們需要保證每行都看得到。
	// ignore: avoid_print
	print("[puzzle-diag $hms] $msg");
}
