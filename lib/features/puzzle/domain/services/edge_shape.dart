import "dart:math";

import "../models/puzzle_edge.dart";

/// 拼圖耳的「形狀生成器」抽象介面。
///
/// 一個 EdgeShape 負責決定：給定一條邊的長度與類型，產出沿 +X 方向描繪、
/// 凸方向（tabOut 為 -Y、tabIn 為 +Y）一致的「形狀指令序列」。
///
/// 形狀指令是與座標系無關的相對位置資料，由呼叫端（puzzle_cutter）負責
/// 套上 axisX / axisY 軸轉換成 localPath 座標。
///
/// 透過此抽象，未來想替換或調整拼圖耳造型只要實作新的 EdgeShape，
/// 不必動到 puzzle_cutter 主邏輯。
abstract class EdgeShape {
	const EdgeShape();

	/// 生成一條邊的形狀指令。
	///
	/// - [length]：邊的長度。
	/// - [tabSize]：耳尺寸基底（pixel）。由呼叫端依「該邊長度」與「上限規則」
	///   算好後傳入；EdgeShape 本身不再決定上限，避免上限邏輯散落多處。
	/// - [type]：邊類型（flat / tabOut / tabIn）。
	/// - [baselineBulge]：整條邊的「基線」曲率（pixel）。正值代表 baseline 朝
	///   +Y 鼓起、負值朝 -Y 鼓起、0 表示直線 baseline（傳統拼圖耳）。
	///   兩端點仍固定在 (0, 0) 與 (length, 0)。耳朵的所有 y 偏移會疊加在
	///   baseline 之上。flat 類型仍會走 baseline 曲線。
	/// - [forceFlat]：是否強制不畫耳朵（即使 [type] 不是 flat）。用於「太短的
	///   邊」——耳朵被上限夾到失去意義時，整條邊只走 baseline 曲線比較自然。
	/// - [widthShrinkRatio]：耳朵 base 寬度的縮減比例（1.0 = 原寬，0.0 = 退化
	///   到一點）。實作時應把所有 X 比例朝中心 0.5 靠攏（lerp）。深度由
	///   [tabSize] 控制，寬度由此參數獨立控制 — 兩者都縮才能避免「窄而矮的
	///   耳朵在 base 上仍佔據過寬範圍」的問題。
	/// - [seed]：隨機種子（用於形狀微調的確定性）。
	///
	/// 回傳的指令序列從 (0, 0) 起始（不必明確 moveTo）、結束於 (length, 0)。
	List<EdgeCommand> build({
		required double length,
		required double tabSize,
		required EdgeType type,
		required double baselineBulge,
		required bool forceFlat,
		required int seed,
		double widthShrinkRatio = 1.0,
	});

	/// 在沒有任何上限規則的情況下，給定邊長 [length] 預期的 tabSize（pixel）。
	///
	/// puzzle_cutter 會把此值與「凹入端的尺寸上限」一起傳給 [clampTabSize] 取得實際 tabSize。
	double naturalTabSizeFor(double length);

	/// 從外部給定的 [tabSize] 換算出耳朵的「凸出距離」（pixel）。
	///
	/// sourceRect 必須外擴此距離才能完整容納耳朵，否則繪製時耳朵會被裁切掉。
	double protrusionFromTabSize(double tabSize);

	/// 給「自然耳尺寸」[naturalTabSize] 與「凸出距離上限」[maxProtrusion]，
	/// 回傳實際應使用的 tabSize（凸出距離不會超過 [maxProtrusion]）。
	///
	/// 由呼叫端（puzzle_cutter）負責決定 [maxProtrusion]（通常是 tabIn 那片
	/// 短邊乘上一個比例），EdgeShape 只負責把它換算成對應的 tabSize。
	double clampTabSize(double naturalTabSize, double maxProtrusion);
}

/// 邊上的一個繪圖指令（lineTo 或 cubicTo）。
///
/// [isTab] 標示此段是否「屬於耳朵本體」（凸出 / 凹入的兩段 cubic）。
/// 兩端 baseline 段、flat 段、forceFlat 段的 isTab 皆為 false。
/// 自交修正時只在乎涉及耳朵的衝突，純 baseline 之間的近距離不算數。
sealed class EdgeCommand {
	const EdgeCommand({this.isTab = false});
	final bool isTab;
}

/// 直線到 (x, y)。
class LineToCmd extends EdgeCommand {
	const LineToCmd(this.x, this.y, {super.isTab});
	final double x;
	final double y;
}

/// 三次貝茲到 (x, y)，控制點 (c1x, c1y)、(c2x, c2y)。
class CubicToCmd extends EdgeCommand {
	const CubicToCmd(
		this.c1x,
		this.c1y,
		this.c2x,
		this.c2y,
		this.x,
		this.y, {
		super.isTab,
	});
	final double c1x;
	final double c1y;
	final double c2x;
	final double c2y;
	final double x;
	final double y;
}

/// 傳統拼圖耳：兩段三次貝茲構成的對稱耳形。
///
/// 沿邊的 X 軸佈局：
///
/// ```
/// 0 ───── x1 ──┐          ┌── x7 ───── length
///              │   x4(tip)│
///              └─cubic1───►─cubic2─┘
/// ```
///
/// 所有比例（tabSizeRatio、x1Ratio、tipXRatio、tipYRatio 等）皆為建構子參數，
/// 修改造型只要 new 一個不同參數的 ClassicTabShape。
class ClassicTabShape extends EdgeShape {
	const ClassicTabShape({
		this.tabSizeRatio = 0.22,
		this.x1Ratio = 0.35,
		this.cp1XRatio = 0.30,
		this.cp2XRatio = 0.30,
		this.tipXRatio = 0.50,
		this.cp3XRatio = 0.70,
		this.cp4XRatio = 0.70,
		this.x7Ratio = 0.65,
		this.midYRatio = 0.4,
		this.tipYRatio = 1.2,
		this.jitterRatio = 0.025,
		this.baselineBulgeMaxRatio = 0.06,
	});

	/// 邊的 baseline 曲率最大值佔邊長的比例（由 cutter 在此範圍內隨機抽樣）。
	///
	/// 0 = 直線 baseline（傳統拼圖耳）；越大整條邊弧度越深。
	/// 6% 是手工拼圖紙板常見的弧度，視覺自然。
	final double baselineBulgeMaxRatio;

	/// 耳尺寸的「自然比例」：在沒有上限規則的情況下，預期 tabSize ≈ length * tabSizeRatio。
	///
	/// 實際傳入 `build()` 的 tabSize 由呼叫端決定（可能被上限夾過）；此欄位
	/// 留下來作為外部計算「自然 tabSize」用。
	final double tabSizeRatio;

	@override
	double naturalTabSizeFor(double length) => length * tabSizeRatio;

	/// 從外部給的 tabSize 換算實際凸出距離。
	@override
	double protrusionFromTabSize(double tabSize) => tabSize * tipYRatio;

	/// 凸出距離不能超過 [maxProtrusion]，逆推回 tabSize 上限。
	@override
	double clampTabSize(double naturalTabSize, double maxProtrusion) {
		if (tipYRatio <= 0) return naturalTabSize;
		final double maxTabSize = maxProtrusion / tipYRatio;
		return naturalTabSize < maxTabSize ? naturalTabSize : maxTabSize;
	}

	/// 進入耳之前直線段結束的 X 比例。
	final double x1Ratio;

	/// 第一段 cubic 的第一控制點 X 比例。
	final double cp1XRatio;

	/// 第一段 cubic 的第二控制點 X 比例。
	final double cp2XRatio;

	/// 耳頂 X 比例。
	final double tipXRatio;

	/// 第二段 cubic 的第一控制點 X 比例。
	final double cp3XRatio;

	/// 第二段 cubic 的第二控制點 X 比例。
	final double cp4XRatio;

	/// 出耳後直線段起始的 X 比例。
	final double x7Ratio;

	/// 控制點中間段 Y 對 tabSize 的比例（產生收尾弧度的關鍵）。
	final double midYRatio;

	/// 耳頂 Y 對 tabSize 的比例（凸出多遠）。
	final double tipYRatio;

	/// 控制點 X 微擾範圍（±jitterRatio * length）。
	final double jitterRatio;

	/// baseline 在 [x] 處的 y 值：bulge × sin(π·x/length)。
	///
	/// 端點 (0) 與 (length) 必定 y=0；中點 (length/2) y=bulge（最高）。
	double _baselineY(double x, double length, double bulge) {
		if (length <= 0) return 0;
		return bulge * sin(pi * x / length);
	}

	@override
	List<EdgeCommand> build({
		required double length,
		required double tabSize,
		required EdgeType type,
		required double baselineBulge,
		required bool forceFlat,
		required int seed,
		double widthShrinkRatio = 1.0,
	}) {
		final bool noTab = forceFlat || type == EdgeType.flat;

		// 沒耳朵：整條邊只走 baseline 曲線（一個 cubic）。
		// 兩個控制點都放在 (length/2, 2·bulge) 附近，使 t=0.5 時 y ≈ bulge。
		// （cubic 在 t=0.5 時 y = (3·c1y + 3·c2y) / 8 = bulge → c1y = c2y = 4·bulge/3）
		if (noTab) {
			if (baselineBulge.abs() < 1e-6) {
				return <EdgeCommand>[LineToCmd(length, 0)];
			}
			final double cy = baselineBulge * 4 / 3;
			return <EdgeCommand>[
				CubicToCmd(length / 3, cy, length * 2 / 3, cy, length, 0),
			];
		}

		final double tabDir = type == EdgeType.tabOut ? -1.0 : 1.0;

		final Random random = Random(seed);
		double jitter() => (random.nextDouble() - 0.5) * 2 * jitterRatio * length;

		// 把每個 X 比例朝中心 (0.5) 靠攏：shrink=1.0 不變、shrink=0.0 全收到 0.5。
		// tipXRatio 是耳頂、預設就是 0.5，所以靠攏後不變（保證對稱）。
		double shrink(double ratio) => 0.5 + (ratio - 0.5) * widthShrinkRatio;

		final double x1 = length * shrink(x1Ratio) + jitter();
		final double c1x = length * shrink(cp1XRatio) + jitter();
		final double c2x = length * shrink(cp2XRatio) + jitter();
		final double x4 = length * shrink(tipXRatio) + jitter();
		final double c3x = length * shrink(cp3XRatio) + jitter();
		final double c4x = length * shrink(cp4XRatio) + jitter();
		final double x7 = length * shrink(x7Ratio) + jitter();

		// baseline 上的 y 偏移：耳朵在這個基準之上展開
		final double y1 = _baselineY(x1, length, baselineBulge);
		final double y4 = _baselineY(x4, length, baselineBulge);
		final double y7 = _baselineY(x7, length, baselineBulge);

		final double yMid = tabDir * tabSize * midYRatio;
		final double yTip = tabDir * tabSize * tipYRatio;

		// 前段控制點：用「等 x 的 baseline y 的一半再加碼」近似 cubic 第二段
		// 把 (0, 0) → (x1, y1) 用一條 cubic 近似 baseline：
		//   控制點 y = (4/3) × baseline(此 x) 是 t=0.5 時的近似最佳值；
		//   但因為這段不是 [0, length]、是 [0, x1]，我直接讓控制點 y = baseline 該 x 的 y。
		//   視覺上的小差距使用者察覺不到、且兩片共享的曲線是同一條，互補性無虞。
		final double preCp1Y = _baselineY(c1x / 2, length, baselineBulge);
		final double preCp2Y = _baselineY(x1 * 0.75, length, baselineBulge);

		final double postCp1Y = _baselineY(x7 + (length - x7) * 0.25, length, baselineBulge);
		final double postCp2Y = _baselineY(x7 + (length - x7) * 0.5, length, baselineBulge);

		return <EdgeCommand>[
			// 段 1：(0, 0) → (x1, y1)，走 baseline 曲線（非耳朵）
			CubicToCmd(c1x / 2, preCp1Y, x1 * 0.75, preCp2Y, x1, y1),
			// 段 2：(x1, y1) → (x4, y4 + yTip)，第一段耳朵
			CubicToCmd(
				c1x,
				y1 + yMid,
				c2x,
				y4 + yTip,
				x4,
				y4 + yTip,
				isTab: true,
			),
			// 段 3：(x4, y4 + yTip) → (x7, y7)，第二段耳朵
			CubicToCmd(
				c3x,
				y4 + yTip,
				c4x,
				y7 + yMid,
				x7,
				y7,
				isTab: true,
			),
			// 段 4：(x7, y7) → (length, 0)，再走 baseline 曲線（非耳朵）
			CubicToCmd(
				x7 + (length - x7) * 0.25,
				postCp1Y,
				x7 + (length - x7) * 0.5,
				postCp2Y,
				length,
				0,
			),
		];
	}
}

/// 預設 EdgeShape（共用 instance）。
const EdgeShape kDefaultEdgeShape = ClassicTabShape();
