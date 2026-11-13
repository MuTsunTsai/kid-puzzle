/// 出場位置的遮擋檢查：避免題目動物一開始就被前面的大動物擋住。
///
/// 每隻動物在畫面上近似成一個橢圓（模型外框投影到畫面的範圍內切的橢圓；Q 版動物大致
/// 是圓滾滾的，比外框矩形貼近實際輪廓）。題目動物的「可見比例」= 橢圓內的取樣點中，
/// 沒有落在「離攝影機更近、而且不同種」的動物橢圓裡的比例：被同類擋住不算（點哪一隻
/// 都一樣是在數牠們）。
class ScreenProxy {
	const ScreenProxy({
		required this.cx,
		required this.cy,
		required this.rx,
		required this.ry,
		required this.depth,
		required this.kind,
	});

	/// 畫面上的橢圓中心與半徑（任意一致的單位，例如以畫面高為 1）。
	final double cx;
	final double cy;
	final double rx;
	final double ry;

	/// 離攝影機的距離（越小越前面）。
	final double depth;

	/// 種類（同種不互相計入遮擋）。
	final Object kind;

	bool contains(double x, double y) {
		if (rx <= 0 || ry <= 0) return false;
		final double dx = (x - cx) / rx;
		final double dy = (y - cy) / ry;
		return dx * dx + dy * dy <= 1;
	}
}

/// [target] 沒有被 [others] 中更前面、不同種的動物蓋住的比例（0～1）。
/// 在橢圓外接矩形取 [grid] × [grid] 個點，只算落在橢圓內的。
double visibleFraction(ScreenProxy target, Iterable<ScreenProxy> others, {int grid = 12}) {
	final List<ScreenProxy> front = <ScreenProxy>[
		for (final ScreenProxy o in others)
			if (!identical(o, target) && o.kind != target.kind && o.depth < target.depth) o,
	];
	if (front.isEmpty) return 1;
	int inside = 0;
	int visible = 0;
	for (int i = 0; i < grid; i++) {
		final double x = target.cx + target.rx * (2 * (i + 0.5) / grid - 1);
		for (int j = 0; j < grid; j++) {
			final double y = target.cy + target.ry * (2 * (j + 0.5) / grid - 1);
			if (!target.contains(x, y)) continue;
			inside++;
			if (!front.any((ScreenProxy o) => o.contains(x, y))) visible++;
		}
	}
	return inside == 0 ? 1 : visible / inside;
}

/// 所有 [isTarget] 的動物裡，可見比例最低的那隻的比例（沒有題目動物回傳 1）。
double minTargetVisibility(List<ScreenProxy> proxies, bool Function(int i) isTarget) {
	double worst = 1;
	for (int i = 0; i < proxies.length; i++) {
		if (!isTarget(i)) continue;
		final double v = visibleFraction(proxies[i], proxies);
		if (v < worst) worst = v;
	}
	return worst;
}
