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
/// [isTab] 標示此段是否「屬於耳朵本體」（凸出 / 凹入的內側 cubic 段）。
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

/// 傳統拼圖耳：四段三次貝茲構成的「葫蘆型」對稱耳形（含頸部收窄）。
///
/// 沿邊的 X 軸佈局：5 個 anchor 點、4 段 cubic 都屬於耳朵本體
///
/// ```
///                  ┌── x4(tip) ──┐
///                  │             │
///                xL│             │xR
///                  │             │
/// 0 ───── x1 ──────┘             └────── x7 ───── length
/// ```
///
/// - 段 1：(0, 0) → (x1, y1)        baseline 曲線（非耳朵）
/// - 段 2：(x1, y1) → (xL, yWaist)  起始沿 baseline 切線、收進頸部
/// - 段 3：(xL, yWaist) → (x4, yTip) 從頸部展開到耳頂
/// - 段 4：(x4, yTip) → (xR, yWaist) 從耳頂收回頸部（對稱於段 3）
/// - 段 5：(xR, yWaist) → (x7, y7)  從頸部收尾、沿 baseline 切線
/// - 段 6：(x7, y7) → (length, 0)   baseline 曲線（非耳朵）
///
/// 內部 anchor 的切線方向：
/// - xL / xR：±45° 斜線（左右反向）、形成葫蘆收頸的「S 型」過渡。
///   widthShrinkRatio < 1 時 slope 也等比例縮放、視覺維持對稱。
/// - tip：水平方向、讓段 3/4 在耳頂平滑接合（圓頂）。
/// - x1 / x7：沿 baseline 切線、讓耳朵與外側 baseline 段 G1 接合。
class ClassicTabShape extends EdgeShape {
	const ClassicTabShape({
		this.tabSizeRatio = 0.22,
		this.x1Ratio = 0.35,
		this.cp1XRatio = 0.40,
		this.xLRatio = 0.38,
		this.waistTangentOffsetRatio = 0.03,
		this.tipTangentOffsetRatio = 0.15,
		this.tipXRatio = 0.50,
		this.xRRatio = 0.62,
		this.cp6XRatio = 0.60,
		this.x7Ratio = 0.65,
		this.tipYRatio = 1.2,
		this.waistYRatio = 0.25,
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

	/// 進入耳之前 baseline 段結束的 X 比例（=耳朵起點 anchor）。
	final double x1Ratio;

	/// 段 2（x1 → xL）第一控制點 X 比例（沿 baseline 切線出發）。
	final double cp1XRatio;

	/// 左頸 anchor X 比例。
	final double xLRatio;

	/// 頸部兩側控制點離 anchor 的 X 偏移（佔 length 的比例）。
	/// xL 左右各 ±waistTangentOffsetRatio·length、xR 同理。
	/// 偏移越小切線段越短、收頸越緊；越大越鬆。
	final double waistTangentOffsetRatio;

	/// 耳頂兩側控制點離 tip 的 X 偏移（佔 length 的比例）。
	final double tipTangentOffsetRatio;

	/// 耳頂 X 比例。
	final double tipXRatio;

	/// 右頸 anchor X 比例。
	final double xRRatio;

	/// 段 5（xR → x7）第二控制點 X 比例（沿 baseline 切線收尾、對稱於 cp1）。
	final double cp6XRatio;

	/// 出耳後 baseline 段起始的 X 比例（=耳朵終點 anchor）。
	final double x7Ratio;

	/// 耳頂 Y 對 tabSize 的比例（凸出多遠）。
	final double tipYRatio;

	/// 頸部 Y 對 tabSize 的比例（頸部凸出多遠、應 < tipYRatio）。
	/// 視覺上是「耳朵收頸」的關鍵：waist 越小頸部越靠 baseline、耳朵越像葫蘆。
	final double waistYRatio;

	/// 控制點 X 微擾範圍（±jitterRatio * length）。
	final double jitterRatio;

	/// baseline 在 [x] 處的 y 值：bulge × sin(π·x/length)。
	///
	/// 端點 (0) 與 (length) 必定 y=0；中點 (length/2) y=bulge（最高）。
	double _baselineY(double x, double length, double bulge) {
		if (length <= 0) return 0;
		return bulge * sin(pi * x / length);
	}

	/// baseline 在 [x] 處的切線斜率 dy/dx = bulge × (π/length) × cos(π·x/length)。
	/// 給耳朵兩端控制點用：讓耳朵離開 / 進入 baseline 時切線方向一致、
	/// 視覺上形成 S 型而非 cusp。
	double _baselineSlope(double x, double length, double bulge) {
		if (length <= 0) return 0;
		return bulge * pi / length * cos(pi * x / length);
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
		final double xL = length * shrink(xLRatio) + jitter();
		final double x4 = length * shrink(tipXRatio) + jitter();
		final double xR = length * shrink(xRRatio) + jitter();
		final double c6x = length * shrink(cp6XRatio) + jitter();
		final double x7 = length * shrink(x7Ratio) + jitter();

		// 頸部 / 耳頂兩側控制點：用相對 anchor 的偏移、保證左右對稱
		final double waistOff = length * waistTangentOffsetRatio;
		final double tipOff = length * tipTangentOffsetRatio;
		final double c2x = xL + waistOff; // 段 2 進 xL 的控制點（xL 右側）
		final double c3x = xL - 3 * waistOff; // 段 3 離 xL 的控制點（xL 左側）
		final double c4x = x4 - tipOff;   // 段 3 進 tip 的控制點（tip 左側）
		final double c5x = x4 + tipOff;   // 段 4 離 tip 的控制點（tip 右側）
		final double c6xWaist = xR + 3 * waistOff; // 段 4 進 xR 的控制點（xR 右側）
		final double c7xWaist = xR - waistOff; // 段 5 離 xR 的控制點（xR 左側）

		// baseline 上的 y 偏移：耳朵在這個基準之上展開
		final double y1 = _baselineY(x1, length, baselineBulge);
		final double yL = _baselineY(xL, length, baselineBulge);
		final double y4 = _baselineY(x4, length, baselineBulge);
		final double yR = _baselineY(xR, length, baselineBulge);
		final double y7 = _baselineY(x7, length, baselineBulge);

		final double yTip = tabDir * tabSize * tipYRatio;
		final double yWaist = tabDir * tabSize * waistYRatio;

		// 切線設計：
		// - x1 出發、x7 收尾：沿 baseline 切線（連到外側 baseline 段）
		// - xL：±45° 朝耳頂方向（tabOut 時 -45°、tabIn 時 +45°）
		// - xR：±45° 反向（與 xL 相反、回到 baseline 方向）
		// - tip：水平（圓頂、段 3/4 在 tip 平滑接合）
		final double slope1 = _baselineSlope(x1, length, baselineBulge);
		final double slope7 = _baselineSlope(x7, length, baselineBulge);
		final double c1y = y1 + (c1x - x1) * slope1;
		final double c6y = y7 + (c6x - x7) * slope7;

		final double yWaistL = yL + yWaist;
		final double yWaistR = yR + yWaist;
		final double yTipAnchor = y4 + yTip;

		// 頸部斜率：±45°、左右反向、形成葫蘆收頸。
		// tabOut（tabDir = -1，耳朵在 -Y）時：
		//   slopeL = +1（xL 切線朝右下 baseline 方向、進耳頂前先「沉一下」再拐上去）
		//   slopeR = -1（xR 切線朝右上 tip 方向、從 tip 下來先續往上再拐下去）
		// 兩處皆 G1 平滑（進入 / 離開共享切線）。
		//
		// widthShrinkRatio < 1 時整個耳朵 X 軸被壓向中心：頸部控制點離 anchor
		// 的 X 偏移也跟著縮，所以 slope 必須一起縮、Y 偏移才會等比例縮放、
		// 維持視覺上的對稱比例。否則切線太陡、頸部會「翻過頭」。
		final double slopeL = -tabDir * widthShrinkRatio;
		final double slopeR = tabDir * widthShrinkRatio;

		final double preCp1Y = _baselineY(c1x / 2, length, baselineBulge);
		final double preCp2Y = _baselineY(x1 * 0.75, length, baselineBulge);

		final double postCp1Y = _baselineY(x7 + (length - x7) * 0.25, length, baselineBulge);
		final double postCp2Y = _baselineY(x7 + (length - x7) * 0.5, length, baselineBulge);

		return <EdgeCommand>[
			// 段 1：(0, 0) → (x1, y1)，走 baseline 曲線（非耳朵）
			CubicToCmd(c1x / 2, preCp1Y, x1 * 0.75, preCp2Y, x1, y1),
			// 段 2：(x1, y1) → (xL, yWaistL)
			// c1 沿 baseline 切線出發；c2 在 xL 左側、沿 ±45° slopeL 進入
			CubicToCmd(
				c1x,
				c1y,
				c2x,
				yWaistL + (c2x - xL) * slopeL,
				xL,
				yWaistL,
				isTab: true,
			),
			// 段 3：(xL, yWaistL) → (x4, yTipAnchor)
			// c3 在 xL 右側、沿 ±45° slopeL 離開（與段 2 共享切線，G1 平滑）
			// c4 在 tip 左側、切線水平（與段 4 共享）
			CubicToCmd(
				c3x,
				yWaistL + (c3x - xL) * slopeL,
				c4x,
				yTipAnchor,
				x4,
				yTipAnchor,
				isTab: true,
			),
			// 段 4：(x4, yTipAnchor) → (xR, yWaistR)
			// 離開 tip 切線水平（c5 在 tip 右側、y = yTipAnchor）
			// 進入 xR 切線 ±45°（c6xWaist 在 xR 左側、沿 slopeR）
			CubicToCmd(
				c5x,
				yTipAnchor,
				c6xWaist,
				yWaistR + (c6xWaist - xR) * slopeR,
				xR,
				yWaistR,
				isTab: true,
			),
			// 段 5：(xR, yWaistR) → (x7, y7)
			// 離開 xR 切線 ±45°（c7xWaist 在 xR 右側、沿 slopeR、與段 4 共享）
			// c6 沿 baseline 切線收尾
			CubicToCmd(
				c7xWaist,
				yWaistR + (c7xWaist - xR) * slopeR,
				c6x,
				c6y,
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
