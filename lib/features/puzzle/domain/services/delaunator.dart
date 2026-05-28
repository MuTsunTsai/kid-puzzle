// Delaunator：快速 Delaunay triangulation。
//
// 從 Mapbox delaunator (JS, ISC license) 1:1 port 過來：
// https://github.com/mapbox/delaunator
//
// ----------------------------------------------------------------------------
// ISC License
//
// Copyright (c) 2026, Mapbox
//
// Permission to use, copy, modify, and/or distribute this software for any
// purpose with or without fee is hereby granted, provided that the above
// copyright notice and this permission notice appear in all copies.
//
// THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
// REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY
// AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
// INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
// LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
// OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
// PERFORMANCE OF THIS SOFTWARE.
// ----------------------------------------------------------------------------
//
// 演算法：
// 1. 找最接近 bbox 中心的 seed 點 i0；找離 i0 最近的 i1；找與 (i0, i1) 形成
//    最小外接圓的 i2 → seed triangle。
// 2. 把所有點依「離 seed triangle 外心的距離」排序（spatial sort）。
// 3. 依排序依序加入點：用 hash 找凸包上可見邊、加入新三角形、edge flip 維持
//    Delaunay 條件。
//
// 時間複雜度 O(n log n)；比 naive Bowyer-Watson O(n²) 快非常多。
//
// 為了維持輕量、不外露 typed array 細節，輸入用 List<Offset>、輸出
// [triangles] 為 `Uint32List`（每 3 個一組）。呼叫端通常會把它轉成自己的
// 三角形型別。

import "dart:math";
import "dart:typed_data";
import "dart:ui";

const double _kEpsilon = 2.220446049250313e-16; // Math.pow(2, -52)
const int _kEdgeStackSize = 512;

/// Delaunay triangulation 計算結果。
///
/// 建構時就完成三角化。用 [triangles] 取得結果（每 3 個 int 為一個三角形、
/// 索引指向原 [points]）。
class Delaunator {
	Delaunator(List<Offset> points) {
		final int n = points.length;
		coords = Float64List(n * 2);
		for (int i = 0; i < n; i++) {
			coords[2 * i] = points[i].dx;
			coords[2 * i + 1] = points[i].dy;
		}

		final int maxTriangles = n > 0 ? (2 * n - 5).clamp(0, 1 << 30) : 0;
		_triangles = Uint32List(maxTriangles * 3);
		_halfedges = Int32List(maxTriangles * 3);

		_hashSize = sqrt(n).ceil();
		_hullPrev = Uint32List(n);
		_hullNext = Uint32List(n);
		_hullTri = Uint32List(n);
		_hullHash = Int32List(_hashSize);

		_ids = Uint32List(n);
		_dists = Float64List(n);
		_edgeStack = Uint32List(_kEdgeStackSize);

		_update();
	}

	late final Float64List coords;
	late final Uint32List _triangles;
	late final Int32List _halfedges;
	late final int _hashSize;
	late final Uint32List _hullPrev;
	late final Uint32List _hullNext;
	late final Uint32List _hullTri;
	late final Int32List _hullHash;
	late final Uint32List _ids;
	late final Float64List _dists;
	late final Uint32List _edgeStack;

	int _trianglesLen = 0;
	double _cx = 0;
	double _cy = 0;
	int _hullStart = 0;

	/// 三角形索引清單（每三個一組，逆時針方向）。
	Uint32List get triangles =>
			Uint32List.sublistView(_triangles, 0, _trianglesLen);

	void _update() {
		final Float64List coords = this.coords;
		final int n = coords.length >> 1;

		double minX = double.infinity;
		double minY = double.infinity;
		double maxX = -double.infinity;
		double maxY = -double.infinity;

		for (int i = 0; i < n; i++) {
			final double x = coords[2 * i];
			final double y = coords[2 * i + 1];
			if (x < minX) minX = x;
			if (y < minY) minY = y;
			if (x > maxX) maxX = x;
			if (y > maxY) maxY = y;
			_ids[i] = i;
		}
		final double cx = (minX + maxX) / 2;
		final double cy = (minY + maxY) / 2;

		int i0 = 0;
		int i1 = 0;
		int i2 = 0;

		// 找最接近 bbox 中心的 seed 點
		double minDist = double.infinity;
		for (int i = 0; i < n; i++) {
			final double d = _dist(cx, cy, coords[2 * i], coords[2 * i + 1]);
			if (d < minDist) {
				i0 = i;
				minDist = d;
			}
		}
		final double i0x = coords[2 * i0];
		final double i0y = coords[2 * i0 + 1];

		// 找離 seed 最近的點
		minDist = double.infinity;
		for (int i = 0; i < n; i++) {
			if (i == i0) continue;
			final double d = _dist(i0x, i0y, coords[2 * i], coords[2 * i + 1]);
			if (d < minDist && d > 0) {
				i1 = i;
				minDist = d;
			}
		}
		double i1x = coords[2 * i1];
		double i1y = coords[2 * i1 + 1];

		double minRadius = double.infinity;

		// 找與前兩點形成最小外接圓的第三點
		for (int i = 0; i < n; i++) {
			if (i == i0 || i == i1) continue;
			final double r = _circumradius(
					i0x, i0y, i1x, i1y, coords[2 * i], coords[2 * i + 1]);
			if (r < minRadius) {
				i2 = i;
				minRadius = r;
			}
		}
		double i2x = coords[2 * i2];
		double i2y = coords[2 * i2 + 1];

		if (minRadius == double.infinity) {
			// 共線：依 dx (或 dy) 排序、把所有點當凸包輸出。
			// 我們的呼叫情境不會走到這裡（外加 4 個遠端虛擬點），保險起見不丟例外。
			_trianglesLen = 0;
			return;
		}

		// 為了逆時針方向，必要時交換 i1 / i2
		if (_orient2d(i0x, i0y, i1x, i1y, i2x, i2y) < 0) {
			final int i = i1;
			final double x = i1x;
			final double y = i1y;
			i1 = i2;
			i1x = i2x;
			i1y = i2y;
			i2 = i;
			i2x = x;
			i2y = y;
		}

		final _XY center = _circumcenter(i0x, i0y, i1x, i1y, i2x, i2y);
		_cx = center.x;
		_cy = center.y;

		for (int i = 0; i < n; i++) {
			_dists[i] = _dist(
					coords[2 * i], coords[2 * i + 1], center.x, center.y);
		}

		// 依離 seed triangle 外心的距離排序
		_quicksort(_ids, _dists, 0, n - 1);

		// 初始凸包 = seed triangle
		_hullStart = i0;

		_hullNext[i0] = _hullPrev[i2] = i1;
		_hullNext[i1] = _hullPrev[i0] = i2;
		_hullNext[i2] = _hullPrev[i1] = i0;

		_hullTri[i0] = 0;
		_hullTri[i1] = 1;
		_hullTri[i2] = 2;

		for (int i = 0; i < _hashSize; i++) {
			_hullHash[i] = -1;
		}
		_hullHash[_hashKey(i0x, i0y)] = i0;
		_hullHash[_hashKey(i1x, i1y)] = i1;
		_hullHash[_hashKey(i2x, i2y)] = i2;

		_trianglesLen = 0;
		_addTriangle(i0, i1, i2, -1, -1, -1);

		double xp = 0;
		double yp = 0;
		for (int k = 0; k < _ids.length; k++) {
			final int i = _ids[k];
			final double x = coords[2 * i];
			final double y = coords[2 * i + 1];

			// 跳過重複點
			if (k > 0 && (x - xp).abs() <= _kEpsilon && (y - yp).abs() <= _kEpsilon) {
				continue;
			}
			xp = x;
			yp = y;

			// 跳過 seed triangle 頂點
			if (i == i0 || i == i1 || i == i2) continue;

			// 用 hash 找凸包上一條可見邊
			int start = 0;
			final int key = _hashKey(x, y);
			for (int j = 0; j < _hashSize; j++) {
				start = _hullHash[(key + j) % _hashSize];
				if (start != -1 && start != _hullNext[start]) break;
			}

			start = _hullPrev[start];
			int e = start;
			int q = _hullNext[e];
			while (_orient2d(x, y, coords[2 * e], coords[2 * e + 1],
					coords[2 * q], coords[2 * q + 1]) >= 0) {
				e = q;
				if (e == start) {
					e = -1;
					break;
				}
				q = _hullNext[e];
			}
			if (e == -1) continue;

			// 加入第一個新三角形
			int t = _addTriangle(e, i, _hullNext[e], -1, -1, _hullTri[e]);

			_hullTri[i] = _legalize(t + 2);
			_hullTri[e] = t;

			// 向前推進
			int nn = _hullNext[e];
			int q2 = _hullNext[nn];
			while (_orient2d(x, y, coords[2 * nn], coords[2 * nn + 1],
					coords[2 * q2], coords[2 * q2 + 1]) < 0) {
				t = _addTriangle(nn, i, q2, _hullTri[i], -1, _hullTri[nn]);
				_hullTri[i] = _legalize(t + 2);
				_hullNext[nn] = nn; // mark removed
				nn = q2;
				q2 = _hullNext[nn];
			}

			// 向後推進
			if (e == start) {
				int qb = _hullPrev[e];
				while (_orient2d(x, y, coords[2 * qb], coords[2 * qb + 1],
						coords[2 * e], coords[2 * e + 1]) < 0) {
					t = _addTriangle(qb, i, e, -1, _hullTri[e], _hullTri[qb]);
					_legalize(t + 2);
					_hullTri[qb] = t;
					_hullNext[e] = e; // mark removed
					e = qb;
					qb = _hullPrev[e];
				}
			}

			// 更新凸包索引
			_hullStart = _hullPrev[i] = e;
			_hullNext[e] = _hullPrev[nn] = i;
			_hullNext[i] = nn;

			_hullHash[_hashKey(x, y)] = i;
			_hullHash[_hashKey(coords[2 * e], coords[2 * e + 1])] = e;
		}
	}

	int _hashKey(double x, double y) {
		final double a = _pseudoAngle(x - _cx, y - _cy);
		int k = (a * _hashSize).floor() % _hashSize;
		if (k < 0) k += _hashSize;
		return k;
	}

	int _legalize(int aIn) {
		int a = aIn;
		int i = 0;
		int ar = 0;

		while (true) {
			final int b = _halfedges[a];

			final int a0 = a - a % 3;
			ar = a0 + (a + 2) % 3;

			if (b == -1) {
				if (i == 0) break;
				a = _edgeStack[--i];
				continue;
			}

			final int b0 = b - b % 3;
			final int al = a0 + (a + 1) % 3;
			final int bl = b0 + (b + 2) % 3;

			final int p0 = _triangles[ar];
			final int pr = _triangles[a];
			final int pl = _triangles[al];
			final int p1 = _triangles[bl];

			final bool illegal = _inCircle(
					coords[2 * p0], coords[2 * p0 + 1],
					coords[2 * pr], coords[2 * pr + 1],
					coords[2 * pl], coords[2 * pl + 1],
					coords[2 * p1], coords[2 * p1 + 1]);

			if (illegal) {
				_triangles[a] = p1;
				_triangles[b] = p0;

				final int hbl = _halfedges[bl];

				if (hbl == -1) {
					int e = _hullStart;
					do {
						if (_hullTri[e] == bl) {
							_hullTri[e] = a;
							break;
						}
						e = _hullPrev[e];
					} while (e != _hullStart);
				}
				_link(a, hbl);
				_link(b, _halfedges[ar]);
				_link(ar, bl);

				final int br = b0 + (b + 1) % 3;

				if (i < _edgeStack.length) {
					_edgeStack[i++] = br;
				}
			} else {
				if (i == 0) break;
				a = _edgeStack[--i];
			}
		}

		return ar;
	}

	void _link(int a, int b) {
		_halfedges[a] = b;
		if (b != -1) _halfedges[b] = a;
	}

	int _addTriangle(int i0, int i1, int i2, int a, int b, int c) {
		final int t = _trianglesLen;

		_triangles[t] = i0;
		_triangles[t + 1] = i1;
		_triangles[t + 2] = i2;

		_link(t, a);
		_link(t + 1, b);
		_link(t + 2, c);

		_trianglesLen += 3;
		return t;
	}
}

class _XY {
	const _XY(this.x, this.y);
	final double x;
	final double y;
}

double _pseudoAngle(double dx, double dy) {
	final double p = dx / (dx.abs() + dy.abs());
	return (dy > 0 ? 3 - p : 1 + p) / 4;
}

double _dist(double ax, double ay, double bx, double by) {
	final double dx = ax - bx;
	final double dy = ay - by;
	return dx * dx + dy * dy;
}

double _orient2d(double ax, double ay, double bx, double by,
		double cx, double cy) {
	// 簡單 cross product；對非退化輸入夠用（如需 robust predicate 可換 shewchuk）
	return (ay - cy) * (bx - cx) - (ax - cx) * (by - cy);
}

bool _inCircle(double ax, double ay, double bx, double by,
		double cx, double cy, double px, double py) {
	final double dx = ax - px;
	final double dy = ay - py;
	final double ex = bx - px;
	final double ey = by - py;
	final double fx = cx - px;
	final double fy = cy - py;

	final double ap = dx * dx + dy * dy;
	final double bp = ex * ex + ey * ey;
	final double cp = fx * fx + fy * fy;

	return dx * (ey * cp - bp * fy) -
					dy * (ex * cp - bp * fx) +
					ap * (ex * fy - ey * fx) <
			0;
}

double _circumradius(double ax, double ay, double bx, double by,
		double cx, double cy) {
	final double dx = bx - ax;
	final double dy = by - ay;
	final double ex = cx - ax;
	final double ey = cy - ay;

	final double bl = dx * dx + dy * dy;
	final double cl = ex * ex + ey * ey;
	final double denom = dx * ey - dy * ex;
	if (denom == 0) return double.infinity;
	final double d = 0.5 / denom;

	final double x = (ey * bl - dy * cl) * d;
	final double y = (dx * cl - ex * bl) * d;

	return x * x + y * y;
}

_XY _circumcenter(double ax, double ay, double bx, double by,
		double cx, double cy) {
	final double dx = bx - ax;
	final double dy = by - ay;
	final double ex = cx - ax;
	final double ey = cy - ay;

	final double bl = dx * dx + dy * dy;
	final double cl = ex * ex + ey * ey;
	final double d = 0.5 / (dx * ey - dy * ex);

	final double x = ax + (ey * bl - dy * cl) * d;
	final double y = ay + (dx * cl - ex * bl) * d;

	return _XY(x, y);
}

void _quicksort(Uint32List ids, Float64List dists, int left, int right) {
	if (right - left <= 20) {
		for (int i = left + 1; i <= right; i++) {
			final int temp = ids[i];
			final double tempDist = dists[temp];
			int j = i - 1;
			while (j >= left && dists[ids[j]] > tempDist) {
				ids[j + 1] = ids[j];
				j--;
			}
			ids[j + 1] = temp;
		}
	} else {
		final int median = (left + right) >> 1;
		int i = left + 1;
		int j = right;
		_swap(ids, median, i);
		if (dists[ids[left]] > dists[ids[right]]) _swap(ids, left, right);
		if (dists[ids[i]] > dists[ids[right]]) _swap(ids, i, right);
		if (dists[ids[left]] > dists[ids[i]]) _swap(ids, left, i);

		final int temp = ids[i];
		final double tempDist = dists[temp];
		while (true) {
			do {
				i++;
			} while (dists[ids[i]] < tempDist);
			do {
				j--;
			} while (dists[ids[j]] > tempDist);
			if (j < i) break;
			_swap(ids, i, j);
		}
		ids[left + 1] = ids[j];
		ids[j] = temp;

		if (right - i + 1 >= j - left) {
			_quicksort(ids, dists, i, right);
			_quicksort(ids, dists, left, j - 1);
		} else {
			_quicksort(ids, dists, left, j - 1);
			_quicksort(ids, dists, i, right);
		}
	}
}

void _swap(Uint32List arr, int i, int j) {
	final int tmp = arr[i];
	arr[i] = arr[j];
	arr[j] = tmp;
}
