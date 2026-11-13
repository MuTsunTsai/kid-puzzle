import "dart:math";

import "package:flutter_test/flutter_test.dart";
import "package:kid_puzzle/features/counting/domain/camera_fit.dart";
import "package:kid_puzzle/features/counting/domain/tap_vote.dart";
import "package:kid_puzzle/features/counting/domain/wander.dart";
import "package:vector_math/vector_math.dart";

void main() {
	group("wrapAngle", () {
		test("包到 (-π, π]", () {
			for (final double a in <double>[-10, -pi, -1, 0, 1, pi, 4, 10, 100]) {
				final double w = wrapAngle(a);
				expect(w, greaterThan(-pi - 1e-9));
				expect(w, lessThanOrEqualTo(pi + 1e-9));
				expect(cos(w), closeTo(cos(a), 1e-9));
				expect(sin(w), closeTo(sin(a), 1e-9));
			}
		});
	});

	group("pickSpots", () {
		test("數量正確、在圓內、彼此距離足夠", () {
			for (int seed = 0; seed < 50; seed++) {
				final List<Vector2> pts = pickSpots(7, Random(seed), radius: 3.5, spacing: 2.4);
				expect(pts.length, 7);
				for (int i = 0; i < pts.length; i++) {
					expect(pts[i].length, lessThanOrEqualTo(3.5 + 1e-9));
					for (int j = i + 1; j < pts.length; j++) {
						expect(pts[i].distanceTo(pts[j]), greaterThanOrEqualTo(2.4 - 1e-9));
					}
				}
			}
		});

		test("擠不下時放寬距離，不會卡住", () {
			final List<Vector2> pts = pickSpots(30, Random(1), radius: 3.5, spacing: 2.4);
			expect(pts.length, 30);
		});
	});

	group("WanderField", () {
		WanderField makeField(int seed) {
			final Random rnd = Random(seed);
			final List<Vector2> spots = pickSpots(7, rnd, radius: 3.5, spacing: 2.4);
			return WanderField(
				agents: <WanderAgent>[
					for (final Vector2 p in spots)
						WanderAgent(
							pos: p,
							yaw: rnd.nextDouble() * 2 * pi,
							walkSpeed: 0.3 + rnd.nextDouble() * 1.5,
							turnRate: 3.0,
							stepDuration: 0.5,
							clearance: 1.0 + rnd.nextDouble() * 0.6,
							timer: rnd.nextDouble() * 2,
						),
				],
				bound: 3.9,
				random: rnd,
			);
		}

		test("模擬一分鐘：不出界、會走動、不會互相穿過", () {
			for (int seed = 0; seed < 10; seed++) {
				final WanderField f = makeField(seed);
				final List<Vector2> start = <Vector2>[for (final WanderAgent a in f.agents) a.pos.clone()];
				double minGapRatio = double.infinity;
				for (int frame = 0; frame < 60 * 60; frame++) {
					f.update(1 / 60);
					for (int i = 0; i < f.agents.length; i++) {
						final WanderAgent a = f.agents[i];
						// 一小步可能剛好跨出邊界一點點才被擋下；只允許極小的誤差
						expect(a.pos.length, lessThanOrEqualTo(f.bound + 0.05));
						expect(a.walkWeight, inInclusiveRange(0, 1));
						for (int j = i + 1; j < f.agents.length; j++) {
							final WanderAgent b = f.agents[j];
							minGapRatio = min(minGapRatio, a.pos.distanceTo(b.pos) / WanderField.gap(a, b));
						}
					}
				}
				// 至少有一隻離開原地
				final bool moved = <bool>[
					for (int i = 0; i < f.agents.length; i++) f.agents[i].pos.distanceTo(start[i]) > 0.3,
				].any((bool m) => m);
				expect(moved, isTrue, reason: "seed $seed");
				// 擋的是「越走越近」的方向，停下後還在減速滑行，可能略小於保持距離，但不會疊在一起
				expect(minGapRatio, greaterThan(0.7), reason: "seed $seed");
			}
		});
	});

	group("fitCamera", () {
		bool inView(CameraFit fit, double pitch, double fov, double aspect, Vector3 p) {
			final Vector3 dir = cameraDirOf(pitch).normalized();
			final Vector3 forward = -dir;
			final Vector3 right = Vector3(0, 1, 0).cross(forward)..normalize();
			final Vector3 up = forward.cross(right)..normalize();
			final Vector3 v = p - fit.eye(pitch);
			final double z = v.dot(forward);
			final double tanY = tan(fov * degrees2Radians / 2);
			return z > 0 && v.dot(right).abs() <= tanY * aspect * z + 1e-6 && v.dot(up).abs() <= tanY * z + 1e-6;
		}

		for (final double aspect in <double>[1.3, 16 / 9, 2.2]) {
			test("長寬比 $aspect：地面圓周與頭頂都在畫面內", () {
				final CameraFit fit = fitCamera(
					pitchDeg: 20,
					fovDeg: 15,
					aspect: aspect,
					groundRadius: 4.8,
					topRadius: 4.4,
					maxHeight: 2.6,
					baseTarget: Vector3(0, 0.4, 0),
				);
				expect(fit.distance.isFinite, isTrue);
				expect(fit.near, greaterThan(0));
				expect(fit.far, greaterThan(fit.near));
				for (int i = 0; i < 36; i++) {
					final double a = 2 * pi * i / 36;
					expect(inView(fit, 20, 15, aspect, Vector3(cos(a) * 4.8, 0, sin(a) * 4.8)), isTrue);
					expect(inView(fit, 20, 15, aspect, Vector3(cos(a) * 4.4, 2.6, sin(a) * 4.4)), isTrue);
				}
			});
		}

		test("畫面越寬，攝影機不會越遠", () {
			double dist(double aspect) => fitCamera(
				pitchDeg: 20,
				fovDeg: 15,
				aspect: aspect,
				groundRadius: 4.8,
				topRadius: 4.4,
				maxHeight: 2.6,
				baseTarget: Vector3(0, 0.4, 0),
			).distance;
			expect(dist(2.0), lessThanOrEqualTo(dist(1.3) + 1e-6));
		});
	});

	group("pickNearestByTier", () {
		int tier(String s) => s.startsWith("T") ? 2 : s.startsWith("t") ? 1 : 0;

		/// 模擬引擎：每條視線打到的（由近到遠），依 minTier 過濾；順便記下測過幾條、
		/// 每條收到的 minTier
		String? pick(List<List<String>> rays, {List<int>? calls}) => pickNearestByTier<String>(
			rayCount: rays.length,
			castRay: (int i, int minTier) {
				calls?.add(minTier);
				return rays[i].where((String a) => tier(a) > minTier);
			},
			tier: tier,
			maxTier: 2,
		);

		test("被擋住的題目動物優先於前面的其他動物", () {
			expect(pick(<List<String>>[<String>["x", "T1"]]), "T1");
		});

		test("同優先順序選離中心最近的（先出現的視線）", () {
			expect(pick(<List<String>>[<String>["t1"], <String>["t2"], <String>["t2"]]), "t1");
		});

		test("外圈的高優先勝過中心的低優先", () {
			expect(pick(<List<String>>[<String>["x"], <String>["t1"], <String>["x"], <String>["T1"]]), "T1");
		});

		test("找到最高優先就不再往外測", () {
			final List<int> calls = <int>[];
			expect(pick(<List<String>>[<String>["T1"], <String>["x"], <String>["x"]], calls: calls), "T1");
			expect(calls.length, 1);
		});

		test("找到之後只找更高優先的", () {
			final List<int> calls = <int>[];
			expect(pick(<List<String>>[<String>[], <String>["x"], <String>["t1"], <String>["x"]], calls: calls), "t1");
			expect(calls, <int>[-1, -1, 0, 1]);
		});

		test("沒打到任何東西回傳 null", () {
			expect(pick(<List<String>>[<String>[], <String>[]]), isNull);
		});
	});

	test("半圓取樣：都在上半圓內、由近到遠", () {
		final List<({double dx, double dy})> s = upperHalfDiscSamples(24, 4);
		expect(s.first, (dx: 0.0, dy: 0.0));
		double last = 0;
		for (final ({double dx, double dy}) o in s) {
			final double d = o.dx * o.dx + o.dy * o.dy;
			expect(d, lessThanOrEqualTo(24 * 24));
			expect(o.dy, lessThanOrEqualTo(0));
			expect(d, greaterThanOrEqualTo(last));
			last = d;
		}
	});
}
