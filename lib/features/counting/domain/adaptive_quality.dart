/// 依實際幀率自動降低畫質（只降不升，避免來回切換）。
///
/// 每一段量 [window] 秒的平均幀率，低於 [targetFps] 就降一級。剛開始、剛換關或剛換畫質時
/// 先等 [settle] 秒再量（載入、編譯 shader 的卡頓不算）。單幀超過 [maxFrameTime] 秒的也不算
/// （切到背景、系統暫停等），不然一次卡頓就會被當成整台很慢。
class AdaptiveQuality {
	AdaptiveQuality({
		required this.maxLevel,
		this.level = 0,
		this.targetFps = 30,
		this.window = 2.0,
		this.settle = 1.5,
		this.maxFrameTime = 0.5,
	});

	/// 最低畫質的等級。
	final int maxLevel;

	/// 目前的等級（0 = 最高畫質）。
	int level;

	final double targetFps;
	final double window;
	final double settle;
	final double maxFrameTime;

	double _settleLeft = 0;
	double _time = 0;
	int _frames = 0;

	/// 先不要量（換關、換畫質之後）。
	void restart() {
		_settleLeft = settle;
		_time = 0;
		_frames = 0;
	}

	/// 記一幀（[dt] 秒）。降級時回傳 true。
	bool addFrame(double dt) {
		if (level >= maxLevel || dt <= 0 || dt > maxFrameTime) return false;
		if (_settleLeft > 0) {
			_settleLeft -= dt;
			return false;
		}
		_time += dt;
		_frames++;
		if (_time < window) return false;
		final double fps = _frames / _time;
		_time = 0;
		_frames = 0;
		if (fps >= targetFps) return false;
		level++;
		restart();
		return true;
	}
}
