import "package:flutter_scene/build_hooks.dart";
import "package:hooks/hooks.dart";

// 3D（數數看）的建置期資源：
// - assets/models/*.fsceneb：姊妹專案預先轉好的模型，這裡只原樣複製進 flutter_scene_generated/，
//   不在建置時轉換 glb（本專案也沒有 glb）。
// - assets/materials/*.fmat：兩階上色、地面材質，編譯成 shader bundle。
// - shaders/ink_outline.frag：畫面空間描邊（ink.shaderbundle.json），執行期用
//   resolveShaderBundleKey("ink") 載入。
// shader 跟當下的 Flutter 引擎綁定，所以必須在建置時編譯，不能預先編好放進來。
void main(List<String> args) async {
	await build(args, (BuildInput input, BuildOutputBuilder output) async {
		buildScenes(buildInput: input, buildOutput: output);
		await buildMaterials(buildInput: input, buildOutput: output);
		await buildTargetShaderBundleJson(
			buildInput: input,
			buildOutput: output,
			manifestFileName: "ink.shaderbundle.json",
			// 跟 flutter_scene 全螢幕 pass 的 vertex shader（GLSL ES 3.00）一致。不指定時 GLES 版
			// 編成 1.00，Impeller 走 OpenGL ES 的裝置（Galaxy A52 等 Vulkan 被停用的）連結時
			// 「shader version mismatch」，描邊 pipeline 建不出來
			glesLanguageVersion: 300,
		);
	});
}
