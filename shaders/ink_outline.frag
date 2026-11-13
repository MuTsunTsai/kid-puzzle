// 畫面空間描邊（全螢幕後處理，見 lib/main.dart 的 _InkOutlinePass）。
//
// 畫一條固定寬度、置中的線：像素 p 周圍半徑 r（像素）的圓內，只要有一點 q 跟 p
// 之間是「邊緣」，p 就在線上。線寬由「最近的邊緣」距離決定，所以線條末端自然是
// 圓頭：輪廓陷進另一個物體時，邊緣在交會處結束，線就在那裡以半徑 r 的圓收尾
// （以前的描邊殼做法會越來越細）。
//
// 資料全部來自場景顏色的 alpha（toon.fmat / ground.fmat 的 encode_depth）：
// ≥ 1 = 動物（沿視線的深度 + 1）、≤ -1 = 地面（疊上半透明影子後仍是負值）、
// 0～1 = 背景（含背景上的半透明物，例如超出地面邊緣的影子）。不用另外畫深度預處理和遮罩
// （那兩次額外繪製在手機上就吃掉約 1/3 的 FPS）。
//
// 邊緣有兩種：
// 1. 動物 ↔ 非動物：動物的外輪廓、腳底與地面。不看深度，所以腳踩在地上也有線。
// 2. 動物身上的深度不連續（部位前後重疊、兩隻動物重疊）：落差超過門檻。
//    斜面（身體側面）本身在幾個像素內深度就會變很多：用 p 自己的深度斜率預測 q 的
//    深度，跟預測值比，不跟 p 比。斜率取左右（上下）兩側變化小的那側，不跨過邊緣。
// 地面、背景之間不畫線（地面沒有描邊）。
//
// 效能：先在半徑外緣一圈 8 點、半徑一半處一圈 8 點 + 上下左右 4 個鄰點檢查，都不是邊緣就直接結束，
// 只有靠近邊緣的像素才做完整的圓內搜尋。比取樣間距還細的部位可能漏檢。
//
// 輸出的 alpha 改回正常值（有畫東西 = 1），後面的色調映射與合成才正確。
//
// 已數過的動物的金色光輝也在這裡畫（畫面空間，不是 3D 外殼）：不是已數過動物的像素，
// 如果半徑內有已數過的動物、而且那隻在自己前面（地面、背景一律算後面），就依距離上色。
// 因為只畫在輪廓外，身體上（下巴等）不會有光；也不看地面深度，不會陷進地面。
// 已數過的動物在 alpha 上多加 counted code（glow_params.y，2 的次方、大於場景深度範圍），
// 見 toon.fmat 的 counted_offset。解碼見 decode()。

uniform sampler2D input_color;

uniform InkInfo {
	// rgb：線的顏色（線性 HDR，經過色調映射）、a：不透明度
	vec4 color;
	// x：半徑（像素）、y：深度落差門檻（世界單位）、zw：一個像素的 uv 大小
	vec4 params;
	// rgb：光輝的顏色、a：強度
	vec4 glow_color;
	// x：光輝半徑（像素，0 = 沒有光輝）、y：counted code
	vec4 glow_params;
}
ink;

in vec2 v_uv;
out vec4 frag_color;

float gD0;
float gGx;
float gGy;

// 去掉「已數過」的記號，還原成深度的編碼
float decode(float a) {
	return a >= ink.glow_params.y ? a - ink.glow_params.y : a;
}

float codeAt(vec2 uv) {
	return decode(texture(input_color, uv).a);
}

// 半徑 radius 的圓周上取 16 點，有沒有「比 selfDepth 前面、已數過的動物」
bool glowHit(float radius, float selfDepth, float phase) {
	const float kStep = 6.2831853 / 16.0;
	for (int i = 0; i < 16; i++) {
		float a = (float(i) + phase) * kStep;
		float c = texture(input_color, v_uv + vec2(cos(a), sin(a)) * radius * ink.params.zw).a;
		if (c >= ink.glow_params.y && c - ink.glow_params.y < selfDepth) {
			return true;
		}
	}
	return false;
}

// 這個像素的光輝強度（0～1）：外圈先查，大部分像素 16 次取樣就結束；
// 有碰到才往內查，找出大約的距離
float glowAmount(float code) {
	float R = ink.glow_params.x;
	// 地面、背景在所有動物後面；沒數過的動物要比較深度
	float selfDepth = code >= 0.999 ? code : 1.0e6;
	if (!glowHit(R, selfDepth, 0.0)) {
		return 0.0;
	}
	float dist = R;
	if (glowHit(R * 0.75, selfDepth, 0.5)) {
		dist = R * 0.75;
		if (glowHit(R * 0.5, selfDepth, 0.0)) {
			dist = R * 0.5;
			if (glowHit(R * 0.25, selfDepth, 0.5)) {
				dist = R * 0.25;
			}
		}
	}
	float t = 1.0 - dist / (R * 1.25);
	return t * t * (3.0 - 2.0 * t);
}

// p（動物）與 p + o 之間是不是邊緣
bool isEdge(vec2 o) {
	float c = codeAt(v_uv + o * ink.params.zw);
	if (c < 0.999) {
		return true;
	}
	float predicted = gD0 + gGx * o.x + gGy * o.y;
	return abs(c - predicted) > ink.params.y;
}

// p（不是動物）與 p + o 之間是不是邊緣：只有對面是動物時
bool isEdgeOutside(vec2 o) {
	return codeAt(v_uv + o * ink.params.zw) >= 0.999;
}

// 地面像素的實際覆蓋率（不透明度）。
// Android（Impeller）有 MSAA：地面邊緣只蓋到一部分的像素，resolve 後顏色與 alpha 都跟
// 透明背景平均過（rgb = f × 地面色、alpha = f × 地面的負值編碼）。若一律當成不透明，
// 這些變暗的像素就會在地面邊緣排成一條斷續的深色線（web 沒有 MSAA，不會發生）。
// 旁邊有背景像素時，拿四周最負的值（完整覆蓋的地面，深度幾乎相同）當分母還原 f；
// 不在邊緣的地面像素（含影子內的漸層）維持不透明。
float groundCoverage(float a) {
	vec2 ts = ink.params.zw;
	float l = texture(input_color, v_uv - vec2(ts.x, 0.0)).a;
	float r = texture(input_color, v_uv + vec2(ts.x, 0.0)).a;
	float d = texture(input_color, v_uv - vec2(0.0, ts.y)).a;
	float u = texture(input_color, v_uv + vec2(0.0, ts.y)).a;
	bool bg = (l >= 0.0 && l < 0.999) || (r >= 0.0 && r < 0.999)
		|| (d >= 0.0 && d < 0.999) || (u >= 0.0 && u < 0.999);
	if (!bg) {
		return 1.0;
	}
	float full = min(a, min(min(l, r), min(d, u)));
	return clamp(a / full, 0.0, 1.0);
}

void main() {
	vec4 base = texture(input_color, v_uv);
	// 動物的像素 alpha = 1、地面依覆蓋率（見 groundCoverage）；
	// 0～1 是背景上的半透明物（超出地面的影子），維持原值。rgb 本來就是預乘過的
	float alpha = base.a >= 0.999 ? 1.0 : base.a < 0.0 ? groundCoverage(base.a) : base.a;
	vec3 rgb = base.rgb;
	vec2 ts = ink.params.zw;
	bool animal = base.a >= 0.999;
	bool counted = base.a >= ink.glow_params.y;
	gD0 = decode(base.a);
	// 光輝畫在線的底下：一般的 over 合成，顏色不受底色影響，背景上也看得到
	if (ink.glow_params.x > 0.0 && !counted) {
		float g = glowAmount(gD0) * ink.glow_color.a;
		rgb = rgb * (1.0 - g) + ink.glow_color.rgb * g;
		alpha = alpha * (1.0 - g) + g;
	}
	gGx = 0.0;
	gGy = 0.0;
	if (animal) {
		float dl = gD0 - codeAt(v_uv - vec2(ts.x, 0.0));
		float dr = codeAt(v_uv + vec2(ts.x, 0.0)) - gD0;
		float dd = gD0 - codeAt(v_uv - vec2(0.0, ts.y));
		float du = codeAt(v_uv + vec2(0.0, ts.y)) - gD0;
		gGx = abs(dl) < abs(dr) ? dl : dr;
		gGy = abs(dd) < abs(du) ? dd : du;
	}

	// 迴圈上下限必須是常數（GLSL ES 1.00）；超出半徑的取樣跳過
	const int kRadius = 4;
	float r = clamp(ink.params.x, 0.5, float(kRadius) - 1.0);

	// 粗篩：外緣一圈 8 點 + 半徑約一半處錯開 22.5° 的一圈 8 點 + 四個鄰點。
	// 只有外圈時，線粗一點（外圈大）點與點的空隙就大，耳朵與頭之間這類很窄的縫會從空隙
	// 漏掉，那個像素沒畫線，線上出現一粒粒亮點（web 上描邊 150% 時明顯）。中圈補這些空隙。
	float R = r + 1.0;
	float k = R * 0.7071;
	float ma = R * 0.55 * 0.9239;
	float mb = R * 0.55 * 0.3827;
	bool near;
	if (animal) {
		near = isEdge(vec2(1.0, 0.0)) || isEdge(vec2(-1.0, 0.0))
			|| isEdge(vec2(0.0, 1.0)) || isEdge(vec2(0.0, -1.0))
			|| isEdge(vec2(R, 0.0)) || isEdge(vec2(-R, 0.0))
			|| isEdge(vec2(0.0, R)) || isEdge(vec2(0.0, -R))
			|| isEdge(vec2(k, k)) || isEdge(vec2(-k, k))
			|| isEdge(vec2(k, -k)) || isEdge(vec2(-k, -k))
			|| isEdge(vec2(ma, mb)) || isEdge(vec2(-ma, mb))
			|| isEdge(vec2(ma, -mb)) || isEdge(vec2(-ma, -mb))
			|| isEdge(vec2(mb, ma)) || isEdge(vec2(-mb, ma))
			|| isEdge(vec2(mb, -ma)) || isEdge(vec2(-mb, -ma));
	} else {
		near = isEdgeOutside(vec2(1.0, 0.0)) || isEdgeOutside(vec2(-1.0, 0.0))
			|| isEdgeOutside(vec2(0.0, 1.0)) || isEdgeOutside(vec2(0.0, -1.0))
			|| isEdgeOutside(vec2(R, 0.0)) || isEdgeOutside(vec2(-R, 0.0))
			|| isEdgeOutside(vec2(0.0, R)) || isEdgeOutside(vec2(0.0, -R))
			|| isEdgeOutside(vec2(k, k)) || isEdgeOutside(vec2(-k, k))
			|| isEdgeOutside(vec2(k, -k)) || isEdgeOutside(vec2(-k, -k))
			|| isEdgeOutside(vec2(ma, mb)) || isEdgeOutside(vec2(-ma, mb))
			|| isEdgeOutside(vec2(ma, -mb)) || isEdgeOutside(vec2(-ma, -mb))
			|| isEdgeOutside(vec2(mb, ma)) || isEdgeOutside(vec2(-mb, ma))
			|| isEdgeOutside(vec2(mb, -ma)) || isEdgeOutside(vec2(-mb, -ma));
	}
	if (!near) {
		frag_color = vec4(rgb, alpha);
		return;
	}

	float reach = R * R;
	float best = 1.0e6;
	for (int y = -kRadius; y <= kRadius; y++) {
		for (int x = -kRadius; x <= kRadius; x++) {
			vec2 o = vec2(float(x), float(y));
			float l2 = dot(o, o);
			if (l2 > reach || l2 >= best || l2 == 0.0) {
				continue;
			}
			if (animal ? isEdge(o) : isEdgeOutside(o)) {
				best = l2;
			}
		}
	}
	// p 到邊緣（p 與 q 之間）的距離約為 |pq| - 0.5；邊緣 1 像素反鋸齒
	float coverage = clamp(r + 1.0 - sqrt(best), 0.0, 1.0) * ink.color.a;
	// 預乘 alpha 的 over 合成：背景（沒有畫東西、alpha = 0）上的線也要不透明
	frag_color = vec4(
		rgb * (1.0 - coverage) + ink.color.rgb * coverage,
		alpha * (1.0 - coverage) + coverage
	);
}
