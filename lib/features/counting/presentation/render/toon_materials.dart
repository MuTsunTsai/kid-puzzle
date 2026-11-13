import "dart:math";

import "package:flutter_scene/gpu.dart" as gpu;
import "package:flutter_scene/scene.dart";

/// 遞迴走訪節點樹。
void walkNodes(Node n, void Function(Node) f) {
	f(n);
	for (final Node c in n.children) {
		walkNodes(c, f);
	}
}

/// 兩階色調材質（assets/materials/toon.fmat）的管理：Blender 匯出的模型是 PBR 材質，
/// 這裡只取它的底色（與貼圖），換成 toon 版本；每個 toon 材質另外備一份「已數過」版本
/// （多了 counted_offset，描邊 pass 依此畫金色光輝）。
///
/// ⚠ flutter_scene 把材質快取在 render item 裡，單改 primitive.material 不會反映到畫面；
/// 換材質後要重設 [Node.mesh]（新的 Mesh 外殼）才生效。
class ToonMaterials {
	/// PBR 材質 → toon 版本。同一個 PBR 材質只建一份（同種動物共用）。
	final Map<Material, PreprocessedMaterial> _toon = <Material, PreprocessedMaterial>{};

	/// toon ↔ 已數過版本。
	final Map<Material, PreprocessedMaterial> _counted = <Material, PreprocessedMaterial>{};
	final Map<Material, PreprocessedMaterial> _plain = <Material, PreprocessedMaterial>{};

	/// 預先為 [root] 底下每個 PBR 材質建好 toon 版本（fmat 載入是 async）。
	Future<void> prepare(Node root) async {
		final List<PhysicallyBasedMaterial> mats = <PhysicallyBasedMaterial>[];
		walkNodes(root, (Node n) {
			for (final MeshPrimitive p in n.mesh?.primitives ?? <MeshPrimitive>[]) {
				final Material m = p.material;
				if (m is PhysicallyBasedMaterial && !_toon.containsKey(m) && !mats.contains(m)) mats.add(m);
			}
		});
		for (final PhysicallyBasedMaterial m in mats) {
			final PreprocessedMaterial toon = await _make(m);
			final PreprocessedMaterial counted = await _make(m);
			_toon[m] = toon;
			_counted[toon] = counted;
			_plain[counted] = toon;
		}
	}

	Future<PreprocessedMaterial> _make(PhysicallyBasedMaterial m) async {
		final PreprocessedMaterial t = await loadFmatMaterial("assets/materials/toon.fmat");
		t.parameters.setVec4("base_color_factor", m.baseColorFactor);
		final TextureSource? tex = m.baseColorTexture;
		final gpu.Texture? gt = tex?.sampledTexture;
		if (tex != null && gt != null) {
			t.parameters.setTexture("base_color_texture", gt, sampler: tex.sampledSampler);
		}
		return t;
	}

	/// 把 [node]（複製出來的一隻動物）換上 toon 材質。
	void apply(Node node) {
		walkNodes(node, (Node n) {
			final Mesh? mesh = n.mesh;
			if (mesh == null) return;
			n.mesh = Mesh.primitives(primitives: <MeshPrimitive>[
				for (final MeshPrimitive p in mesh.primitives) MeshPrimitive(p.geometry, _toon[p.material] ?? p.material),
			]);
		});
	}

	/// 開 / 關一隻動物的「已數過」記號（金色光輝）。同種動物共用材質，所以換的是這隻
	/// 自己的 primitive。
	void setCounted(Node node, bool on) {
		walkNodes(node, (Node n) {
			final Mesh? mesh = n.mesh;
			if (mesh == null) return;
			n.mesh = Mesh.primitives(primitives: <MeshPrimitive>[
				for (final MeshPrimitive p in mesh.primitives)
					MeshPrimitive(p.geometry, (on ? _counted[p.material] : _plain[p.material]) ?? p.material),
			]);
		});
	}

	/// 依攝影機設定深度編碼（toon / 地面材質都要），回傳描邊 pass 要用的 counted code。
	///
	/// 畫面描邊的資料寫在場景顏色的 alpha 裡。alpha 是半精度浮點數，深度先減掉一個偏移量
	/// 再存，精度才夠：偏移量取到場景最近處。已數過的記號是大於場景深度範圍的 2 的次方
	/// （盡量小才保得住深度精度）。
	double applyCameraParams({
		required double sceneNear,
		required double sceneFar,
		required bool inkOn,
		required List<PreprocessedMaterial> extra,
	}) {
		final double bias = max(0, sceneNear - 1);
		final double countedCode = pow(2.0, (log(sceneFar - sceneNear + 3) / ln2).ceil()).toDouble();
		for (final PreprocessedMaterial m in _counted.values) {
			m.parameters
				..setFloat("encode_depth", inkOn ? 1 : 0)
				..setFloat("depth_bias", bias)
				..setFloat("counted_offset", countedCode);
		}
		for (final PreprocessedMaterial m in <PreprocessedMaterial>[..._toon.values, ...extra]) {
			m.parameters
				..setFloat("encode_depth", inkOn ? 1 : 0)
				..setFloat("depth_bias", bias);
		}
		return countedCode;
	}
}
