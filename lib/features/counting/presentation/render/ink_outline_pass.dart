import "dart:typed_data";

import "package:flutter/foundation.dart" show VoidCallback, debugPrint;

import "package:flutter_scene/gpu.dart" as gpu;
import "package:flutter_scene/scene.dart";

/// 畫面空間描邊（shaders/ink_outline.frag）：場景畫完、色調映射之前，在動物輪廓與
/// 深度不連續的地方疊一條固定寬度的線；已數過的動物外圍的金色光輝也在這裡畫。
///
/// 需要的資料（是不是動物、沿視線的深度、已數過的記號）由 toon.fmat / ground.fmat 寫在
/// 場景顏色的 alpha 裡（見 [ToonMaterials.applyCameraParams]），所以不要求引擎的深度
/// 預處理、也不畫遮罩：那兩次額外繪製在手機上會從 60 掉到 43 FPS。
class InkOutlinePass extends CustomRenderPass {
	InkOutlinePass(this.shader);

	/// 線的半徑佔畫面高度的比例（原型上定案的值：當初描邊殼的線寬 × 150%）。
	static const double kWidth = 0.0018;

	/// 深度落差門檻（世界單位）：比例 0.009 × 定案時的攝影機距離 10.23。
	static const double kThreshold = 0.009 * 10.23;

	/// 光輝的半徑（佔畫面高度的比例）。
	static const double kGlowRadius = 0.02;

	final gpu.Shader shader;

	/// 光輝半徑佔畫面高度的比例（0 = 沒有光輝，shader 整段跳過）、強度。
	double glowRadius = 0;
	double glowStrength = 1;

	/// 已數過的動物在 alpha 上多加的值（2 的次方，大於場景深度範圍）。
	double countedCode = 1024;

	/// 畫不出來時（見 [execute]）呼叫一次：呼叫端要把這個 pass 拿掉、關掉深度編碼。
	VoidCallback? onFailed;
	bool _failed = false;

	@override
	String get name => "ink_outline";

	@override
	RenderStage get stage => RenderStage.afterScene;

	@override
	void execute(RenderPassContext context) {
		final double w = context.dimensions.width;
		final double h = context.dimensions.height;
		if (_failed || w <= 0 || h <= 0) return;
		final Float32List info = Float32List.fromList(<double>[
			// 線的顏色：深咖啡（線性值）
			0.2, 0.12, 0.09, 1.0,
			kWidth * h, kThreshold, 1 / w, 1 / h,
			// 光輝的顏色（飽和的金色，線性值）與強度
			1.0, 0.56, 0.02, glowStrength,
			glowRadius * h, countedCode, 0, 0,
		]);
		// 有些裝置的驅動建不出這個 shader 的 pipeline（Galaxy A52 / Adreno：「Attempted to add an
		// invalid command」→ Failed to append draw）。例外會中斷整幀、連場景都不畫，
		// 所以吃掉它、改成沒有描邊（也沒有金色光輝）照常玩。
		try {
			context.applyShader(shader, uniforms: <String, ByteData>{"InkInfo": ByteData.sublistView(info)});
		} catch (e) {
			_failed = true;
			debugPrint("描邊畫不出來，改成不描邊：$e");
			onFailed?.call();
		}
	}

	/// 載入描邊 shader（hook/build.dart 編譯的 ink shader bundle）；失敗時回傳 null，
	/// 場景照常、只是沒有描邊。
	static Future<InkOutlinePass?> load() async {
		try {
			final gpu.ShaderLibrary? lib = await gpu.loadShaderLibraryAsync(await gpu.resolveShaderBundleKey("ink"));
			final gpu.Shader? shader = lib?["InkOutlineFragment"];
			return shader == null ? null : InkOutlinePass(shader);
		} catch (_) {
			return null;
		}
	}
}
