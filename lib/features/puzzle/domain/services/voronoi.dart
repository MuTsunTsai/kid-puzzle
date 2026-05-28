import "dart:math";
import "dart:ui";

/// 一個 Voronoi cell：包含原始種子點與多邊形頂點（順時針或逆時針）。
class VoronoiCell {
	const VoronoiCell({
		required this.seed,
		required this.polygon,
	});

	/// cell 的種子點（重心後可能與多邊形重心不同）。
	final Offset seed;

	/// cell 的多邊形頂點（已裁剪到 [bounds]，順序為環繞輸出順序）。
	final List<Offset> polygon;
}

/// 用 Bowyer-Watson 演算法計算 Voronoi diagram，並裁剪到指定矩形。
///
/// 主要流程：
/// 1. [generatePoissonLikePoints]：在 [bounds] 內取 [count] 個「分散」的種子點
/// 2. [computeVoronoi]：對 Delaunay triangulation 取對偶 → 未裁剪 Voronoi
/// 3. [clipToBounds]：把每個 cell 裁剪到 [bounds]（含外圈邊界 polygon vertices）
/// 4. [lloydRelax]：把每個 cell 種子點移到該 cell 重心，使分佈更均勻
///
/// 注意：Voronoi cell 可能「無界」（外圍 cell），裁剪到矩形後變有界多邊形。
class VoronoiBuilder {
	VoronoiBuilder._();

	/// 在 [bounds] 內生成 [count] 個分散的種子點。
	///
	/// 完全隨機取 [count] 個點，再執行 [lloydIterations] 次 Lloyd 鬆弛使分佈
	/// 均勻 — 經實測，Lloyd 單獨足以讓分佈逼近 Poisson disk，不再需要網格 + 抖動。
	static Future<List<Offset>> generatePoissonLikePoints({
		required Rect bounds,
		required int count,
		required Random random,
		int lloydIterations = 2,
	}) async {
		List<Offset> points = <Offset>[
			for (int i = 0; i < count; i++)
				Offset(
					bounds.left + random.nextDouble() * bounds.width,
					bounds.top + random.nextDouble() * bounds.height,
				),
		];

		// Lloyd 鬆弛：把每個 cell 的種子點移到該 cell 重心。
		// 每輪結束後 yield 一次、讓 UI 趁機畫一個 frame；computeVoronoi 內部
		// 也會在 Delaunay 後 yield。
		for (int iter = 0; iter < lloydIterations; iter++) {
			if (iter > 0) await Future<void>.delayed(Duration.zero);
			final List<VoronoiCell> cells = await computeVoronoi(points: points, bounds: bounds);
			points = cells.map((VoronoiCell c) => _polygonCentroid(c.polygon)).toList();
		}

		// 小 N（特別 N=2）時 Lloyd 收斂到「最低能量」配置 — 在 4:3 矩形裡通常是
		// 水平兩半。為了讓切割方向有多樣性，整組點繞 bounds 中心隨機旋轉一角度、
		// 再 clamp 進 bounds。對 N >> 3 影響很小（已分散），對 N=2/3 大幅改善。
		if (count <= 3) {
			final Offset center = bounds.center;
			final double angle = random.nextDouble() * 2 * pi;
			final double cosA = cos(angle);
			final double sinA = sin(angle);
			points = points.map((Offset p) {
				final double dx = p.dx - center.dx;
				final double dy = p.dy - center.dy;
				final double rx = dx * cosA - dy * sinA;
				final double ry = dx * sinA + dy * cosA;
				return Offset(
					(center.dx + rx).clamp(bounds.left, bounds.right),
					(center.dy + ry).clamp(bounds.top, bounds.bottom),
				);
			}).toList();
		}

		return points;
	}

	/// 對給定的種子點集合計算 Voronoi diagram，並裁剪到 [bounds]。
	///
	/// 回傳每個種子點對應的 [VoronoiCell]。
	///
	/// 非同步：在 Delaunay 後 yield 一次，把昂貴的兩段（Delaunay 三角化、cell
	/// 組裝迴圈）切到不同 frame、不阻塞 UI 太久。
	static Future<List<VoronoiCell>> computeVoronoi({
		required List<Offset> points,
		required Rect bounds,
	}) async {
		// 步驟：
		// 1. 對 points 做 Delaunay triangulation
		// 2. 每個三角形的外接圓圓心 = Voronoi vertex
		// 3. 對每個種子點，收集圍繞它的三角形，依角度排序連起來形成 polygon
		// 4. 裁剪到 bounds

		// 為了讓邊界 cell 也有完整多邊形，加四個遠端「虛擬點」
		final double pad = max(bounds.width, bounds.height) * 4;
		final List<Offset> all = <Offset>[
			...points,
			Offset(bounds.left - pad, bounds.top - pad),
			Offset(bounds.right + pad, bounds.top - pad),
			Offset(bounds.right + pad, bounds.bottom + pad),
			Offset(bounds.left - pad, bounds.bottom + pad),
		];

		final List<_Triangle> triangles = _delaunay(all);
		// Delaunay 後 yield 一次：把昂貴的兩段（Delaunay 三角化、cell 組裝）
		// 切到不同 frame，避免大 n 時阻塞 UI 太久。
		await Future<void>.delayed(Duration.zero);

		// 對每個原始種子點，收集圍繞它的三角形
		final List<VoronoiCell> cells = <VoronoiCell>[];
		for (int i = 0; i < points.length; i++) {
			final List<_Triangle> incident = triangles.where((_Triangle t) =>
					t.a == i || t.b == i || t.c == i).toList();
			// 取每個三角形的外接圓圓心
			final List<Offset> verts = incident
					.map((_Triangle t) => _circumcenter(all[t.a], all[t.b], all[t.c]))
					.toList();
			// 依角度排序圍繞種子點
			final Offset seed = points[i];
			verts.sort((Offset p, Offset q) {
				final double angP = atan2(p.dy - seed.dy, p.dx - seed.dx);
				final double angQ = atan2(q.dy - seed.dy, q.dx - seed.dx);
				return angP.compareTo(angQ);
			});
			// 裁剪到 bounds
			final List<Offset> clipped = _clipPolygonToRect(verts, bounds);
			cells.add(VoronoiCell(seed: seed, polygon: clipped));
		}
		return cells;
	}

	/// 求三角形外接圓圓心。
	static Offset _circumcenter(Offset a, Offset b, Offset c) {
		final double d = 2 *
				(a.dx * (b.dy - c.dy) +
						b.dx * (c.dy - a.dy) +
						c.dx * (a.dy - b.dy));
		if (d.abs() < 1e-12) {
			// 退化三角形：回傳重心
			return Offset(
				(a.dx + b.dx + c.dx) / 3,
				(a.dy + b.dy + c.dy) / 3,
			);
		}
		final double ax2y2 = a.dx * a.dx + a.dy * a.dy;
		final double bx2y2 = b.dx * b.dx + b.dy * b.dy;
		final double cx2y2 = c.dx * c.dx + c.dy * c.dy;
		final double ux = (ax2y2 * (b.dy - c.dy) +
				bx2y2 * (c.dy - a.dy) +
				cx2y2 * (a.dy - b.dy)) /
				d;
		final double uy = (ax2y2 * (c.dx - b.dx) +
				bx2y2 * (a.dx - c.dx) +
				cx2y2 * (b.dx - a.dx)) /
				d;
		return Offset(ux, uy);
	}

	/// Bowyer-Watson Delaunay triangulation。
	///
	/// 回傳的三角形以 [points] 索引描述。包含「super triangle」頂點的三角形已被
	/// 過濾掉，但為了讓邊界 cell 有完整外接圓圓心，呼叫端通常會把「遠端虛擬點」
	/// 一起塞進來。
	static List<_Triangle> _delaunay(List<Offset> points) {
		final int n = points.length;
		if (n < 3) return <_Triangle>[];

		// 建 super triangle：足以包住所有點的大三角形
		double minX = double.infinity, minY = double.infinity;
		double maxX = -double.infinity, maxY = -double.infinity;
		for (final Offset p in points) {
			if (p.dx < minX) minX = p.dx;
			if (p.dy < minY) minY = p.dy;
			if (p.dx > maxX) maxX = p.dx;
			if (p.dy > maxY) maxY = p.dy;
		}
		final double dx = maxX - minX;
		final double dy = maxY - minY;
		final double deltaMax = max(dx, dy) * 10;
		final double midX = (minX + maxX) / 2;
		final double midY = (minY + maxY) / 2;
		// 三個 super triangle 頂點，加到 points 末端
		final Offset st1 = Offset(midX - 20 * deltaMax, midY - deltaMax);
		final Offset st2 = Offset(midX, midY + 20 * deltaMax);
		final Offset st3 = Offset(midX + 20 * deltaMax, midY - deltaMax);
		final List<Offset> pts = <Offset>[...points, st1, st2, st3];
		final int stA = n;
		final int stB = n + 1;
		final int stC = n + 2;

		final List<_Triangle> triangles = <_Triangle>[_Triangle(stA, stB, stC)];

		for (int i = 0; i < n; i++) {
			final Offset p = pts[i];
			// 找出 circumcircle 包含 p 的三角形
			final List<_Triangle> bad = <_Triangle>[];
			for (final _Triangle t in triangles) {
				if (_inCircumcircle(pts[t.a], pts[t.b], pts[t.c], p)) {
					bad.add(t);
				}
			}
			// 找出 bad triangles 的邊界 (每條邊只屬於一個 bad triangle 的)
			final List<_Edge> polygon = <_Edge>[];
			for (final _Triangle t in bad) {
				for (final _Edge e in <_Edge>[
					_Edge(t.a, t.b),
					_Edge(t.b, t.c),
					_Edge(t.c, t.a),
				]) {
					// 此邊是否在其他 bad triangle 也出現？
					int sharedCount = 0;
					for (final _Triangle u in bad) {
						if (identical(u, t)) continue;
						if (_triangleHasEdge(u, e)) sharedCount++;
					}
					if (sharedCount == 0) polygon.add(e);
				}
			}
			// 移除 bad triangles
			triangles.removeWhere(bad.contains);
			// 加入新三角形：p 與 polygon 每條邊形成新三角形
			for (final _Edge e in polygon) {
				triangles.add(_Triangle(e.a, e.b, i));
			}
		}

		// 過濾掉含 super triangle 頂點的三角形
		triangles.removeWhere((_Triangle t) =>
				t.a >= n || t.b >= n || t.c >= n);
		return triangles;
	}

	/// 點 p 是否在三角形 abc 的外接圓內。
	static bool _inCircumcircle(Offset a, Offset b, Offset c, Offset p) {
		final double ax = a.dx - p.dx;
		final double ay = a.dy - p.dy;
		final double bx = b.dx - p.dx;
		final double by = b.dy - p.dy;
		final double cx = c.dx - p.dx;
		final double cy = c.dy - p.dy;
		final double det = (ax * ax + ay * ay) * (bx * cy - cx * by) -
				(bx * bx + by * by) * (ax * cy - cx * ay) +
				(cx * cx + cy * cy) * (ax * by - bx * ay);
		// abc 為逆時針時 det > 0 表示 p 在內。需檢查 abc 方向
		final double cross = (b.dx - a.dx) * (c.dy - a.dy) -
				(b.dy - a.dy) * (c.dx - a.dx);
		// cross > 0 = 逆時針
		return cross > 0 ? det > 0 : det < 0;
	}

	static bool _triangleHasEdge(_Triangle t, _Edge e) {
		final Set<int> verts = <int>{t.a, t.b, t.c};
		return verts.contains(e.a) && verts.contains(e.b);
	}

	/// Sutherland-Hodgman 多邊形裁剪到矩形。
	static List<Offset> _clipPolygonToRect(List<Offset> polygon, Rect rect) {
		List<Offset> output = List<Offset>.of(polygon);
		// 4 條矩形邊：left, right, top, bottom；每條當作半平面
		// left edge: x >= rect.left
		output = _clipBy(output, (Offset p) => p.dx >= rect.left,
				(Offset a, Offset b) => _intersectVertical(a, b, rect.left));
		// right edge: x <= rect.right
		output = _clipBy(output, (Offset p) => p.dx <= rect.right,
				(Offset a, Offset b) => _intersectVertical(a, b, rect.right));
		// top edge: y >= rect.top
		output = _clipBy(output, (Offset p) => p.dy >= rect.top,
				(Offset a, Offset b) => _intersectHorizontal(a, b, rect.top));
		// bottom edge: y <= rect.bottom
		output = _clipBy(output, (Offset p) => p.dy <= rect.bottom,
				(Offset a, Offset b) => _intersectHorizontal(a, b, rect.bottom));
		return output;
	}

	static List<Offset> _clipBy(
		List<Offset> input,
		bool Function(Offset) inside,
		Offset Function(Offset a, Offset b) intersect,
	) {
		final List<Offset> output = <Offset>[];
		if (input.isEmpty) return output;
		for (int i = 0; i < input.length; i++) {
			final Offset curr = input[i];
			final Offset prev = input[(i - 1 + input.length) % input.length];
			final bool currIn = inside(curr);
			final bool prevIn = inside(prev);
			if (currIn) {
				if (!prevIn) output.add(intersect(prev, curr));
				output.add(curr);
			} else if (prevIn) {
				output.add(intersect(prev, curr));
			}
		}
		return output;
	}

	static Offset _intersectVertical(Offset a, Offset b, double x) {
		final double t = (x - a.dx) / (b.dx - a.dx);
		return Offset(x, a.dy + t * (b.dy - a.dy));
	}

	static Offset _intersectHorizontal(Offset a, Offset b, double y) {
		final double t = (y - a.dy) / (b.dy - a.dy);
		return Offset(a.dx + t * (b.dx - a.dx), y);
	}

	/// 多邊形重心。
	static Offset _polygonCentroid(List<Offset> polygon) {
		if (polygon.isEmpty) return Offset.zero;
		if (polygon.length == 1) return polygon.first;
		double area = 0;
		double cx = 0;
		double cy = 0;
		for (int i = 0; i < polygon.length; i++) {
			final Offset a = polygon[i];
			final Offset b = polygon[(i + 1) % polygon.length];
			final double cross = a.dx * b.dy - b.dx * a.dy;
			area += cross;
			cx += (a.dx + b.dx) * cross;
			cy += (a.dy + b.dy) * cross;
		}
		area /= 2;
		if (area.abs() < 1e-12) {
			// 退化：回傳平均值
			double sx = 0, sy = 0;
			for (final Offset p in polygon) {
				sx += p.dx;
				sy += p.dy;
			}
			return Offset(sx / polygon.length, sy / polygon.length);
		}
		return Offset(cx / (6 * area), cy / (6 * area));
	}
}

class _Triangle {
	const _Triangle(this.a, this.b, this.c);
	final int a;
	final int b;
	final int c;
}

class _Edge {
	const _Edge(this.a, this.b);
	final int a;
	final int b;

	@override
	bool operator ==(Object other) =>
			other is _Edge &&
			((a == other.a && b == other.b) ||
					(a == other.b && b == other.a));

	@override
	int get hashCode => a.hashCode ^ b.hashCode;
}
