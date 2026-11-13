import "dart:math";

import "package:vector_math/vector_math.dart";

/// 移動方向以 +Z 為前方：yaw = 0 時面向 +Z。地面座標 (x, z) 用 [Vector2] 的 (x, y) 表示。
Vector2 forwardOf(double yaw) => Vector2(sin(yaw), cos(yaw));

/// 把角度差包到 (-π, π]。
double wrapAngle(double angle) {
	double a = angle;
	while (a > pi) {
		a -= 2 * pi;
	}
	while (a <= -pi) {
		a += 2 * pi;
	}
	return a;
}

/// 一隻動物的閒晃狀態（不含模型與動畫；頁面每幀讀 [pos]、[yaw]、[walkWeight] 套到模型上）。
class WanderAgent {
	WanderAgent({
		required this.pos,
		required this.yaw,
		required this.walkSpeed,
		required this.turnRate,
		required this.stepDuration,
		required this.clearance,
		this.timer = 0,
	});

	/// 目前位置（地面 x, z）與朝向。
	Vector2 pos;
	double yaw;

	/// 不打滑的走路速度（世界單位 / 秒）：腳掌速度 × 縮放 × 動畫播放倍率。
	final double walkSpeed;

	/// 轉身速度（弧度 / 秒）。
	final double turnRate;

	/// 走一步要幾秒（半個 Walk 動畫循環，已除以播放倍率）。
	final double stepDuration;

	/// 中心最小距離（依縮放）。
	final double clearance;

	/// 走路動畫權重（0 = 站著、1 = 走路），往 [walking] 的目標值漸變。
	double walkWeight = 0;

	/// true = 正在走向 [target]；false = 站著，[timer] 歸零後出發。
	bool walking = false;
	Vector2? target;
	double timer;
}

/// 圓形地面上一群動物的閒晃行為：每隻站一下、走一兩步，不出界、彼此保持距離。
///
/// - 站著：倒數結束後走 1～2 步，方向優先挑接近目前面向的（少轉身），目的地要通過
///   [isFreeSpot]；找不到就繼續站著、過一下再試。
/// - 走路：邊轉向邊前進；面向偏離目標越多走得越慢（原地轉身時幾乎不動），自然形成弧線。
///   到達、或下一步會出界 / 撞到別人（[isStepBlocked]）就停下，不會原地踏步。
/// - 站 / 走兩段動畫的權重在 [blendTime] 內漸變，移動速度也乘上走路權重，起步與停下都有緩衝。
class WanderField {
	WanderField({required this.agents, required this.bound, Random? random, this.blendTime = 0.35})
			: _random = random ?? Random();

	final List<WanderAgent> agents;

	/// 中心可以到的範圍半徑（地面半徑減掉身體預留量）。
	final double bound;

	/// 站著 ↔ 走路的動畫淡入淡出時間（秒）。
	final double blendTime;

	final Random _random;

	/// 超出可活動的範圍。
	bool outOfBounds(Vector2 p) => p.length > bound;

	/// 兩隻之間要保持的距離：取兩者需求的平均。
	static double gap(WanderAgent a, WanderAgent b) => (a.clearance + b.clearance) / 2;

	/// 點 [p] 能不能當 [self] 的目的地：在範圍內，且離其他動物（現在位置與正要去的目的地）都夠遠。
	bool isFreeSpot(WanderAgent self, Vector2 p) {
		if (outOfBounds(p)) return false;
		for (final WanderAgent o in agents) {
			if (identical(o, self)) continue;
			final double g = gap(self, o);
			if (o.pos.distanceTo(p) < g) return false;
			final Vector2? ot = o.target;
			if (ot != null && ot.distanceTo(p) < g) return false;
		}
		return true;
	}

	/// 從 [from] 走到 [to] 這一小步會不會撞到東西。已經太近時只擋「越走越近」的方向，
	/// 不然會卡死在原地。
	bool isStepBlocked(WanderAgent self, Vector2 from, Vector2 to) {
		if (outOfBounds(to)) return true;
		for (final WanderAgent o in agents) {
			if (identical(o, self)) continue;
			final double dTo = o.pos.distanceTo(to);
			if (dTo < gap(self, o) && dTo < o.pos.distanceTo(from)) return true;
		}
		return false;
	}

	/// 停下來、站 2～6 秒。
	void stopWalking(WanderAgent a) {
		a.walking = false;
		a.target = null;
		a.timer = 2 + _random.nextDouble() * 4;
	}

	/// 所有動物前進 [dt] 秒。
	void update(double dt) {
		for (final WanderAgent a in agents) {
			_updateOne(a, dt);
		}
	}

	void _updateOne(WanderAgent a, double dt) {
		if (!a.walking) {
			a.timer -= dt;
			if (a.timer <= 0) {
				final int steps = 1 + _random.nextInt(2);
				final double dist = a.walkSpeed * steps * a.stepDuration;
				Vector2? chosen;
				for (int i = 0; i < 30 && chosen == null; i++) {
					// 前 15 次只在面向 ±60° 內挑，之後放寬到任意方向
					final double spread = i < 15 ? pi / 3 : pi;
					final double ang = a.yaw + (_random.nextDouble() * 2 - 1) * spread;
					final Vector2 c = a.pos + forwardOf(ang) * dist;
					if (isFreeSpot(a, c)) chosen = c;
				}
				if (chosen == null) {
					// 四周都走不了：再站一下
					a.timer = 1 + _random.nextDouble() * 2;
				} else {
					a.target = chosen;
					a.walking = true;
				}
			}
		}

		// 轉向目標；facing = 面向目標的程度（cos 偏差，背對時為 0）
		double facing = 0;
		final Vector2? target = a.target;
		if (a.walking && target != null) {
			final Vector2 to = target - a.pos;
			if (to.length < 0.04) {
				stopWalking(a);
			} else {
				final double diff = wrapAngle(atan2(to.x, to.y) - a.yaw);
				final double maxTurn = a.turnRate * dt;
				final double turn = diff.clamp(-maxTurn, maxTurn);
				a.yaw += turn;
				facing = max(0, cos(diff - turn));
			}
		}

		// 動畫權重漸變
		final double goal = a.walking ? 1 : 0;
		final double step = dt / blendTime;
		a.walkWeight = a.walkWeight < goal ? min(goal, a.walkWeight + step) : max(goal, a.walkWeight - step);

		// 前進：速度 × 走路權重 × 面向程度。停下後走路動畫還在淡出（腳還在踩），
		// 身體也跟著減速往前滑一小段，不然最後一步是原地踏步
		final double move = a.walkSpeed * a.walkWeight * (a.walking ? facing : 1.0) * dt;
		if (move > 0) {
			final Vector2 next = a.pos + forwardOf(a.yaw) * move;
			if (isStepBlocked(a, a.pos, next)) {
				stopWalking(a);
			} else {
				a.pos = next;
			}
		}
	}
}

/// 在半徑 [radius] 的圓內抽 [n] 個彼此距離 ≥ [spacing] 的點（拒絕取樣）。
/// 運氣差抽不滿時整批重來；真的擠不下才逐步放寬距離。
List<Vector2> pickSpots(int n, Random random, {required double radius, required double spacing}) {
	double s = spacing;
	while (true) {
		for (int attempt = 0; attempt < 50; attempt++) {
			final List<Vector2> out = <Vector2>[];
			for (int guard = 0; guard < 500 && out.length < n; guard++) {
				// 圓內均勻分布（半徑取平方根）
				final double r = radius * sqrt(random.nextDouble());
				final double a = 2 * pi * random.nextDouble();
				final Vector2 p = Vector2(r * cos(a), r * sin(a));
				if (out.every((Vector2 q) => q.distanceTo(p) >= s)) out.add(p);
			}
			if (out.length == n) return out;
		}
		s *= 0.95;
	}
}
