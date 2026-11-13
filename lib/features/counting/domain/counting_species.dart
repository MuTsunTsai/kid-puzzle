/// 數數看的一種動物：模型與它專屬的參數。
///
/// 模型由姊妹專案 kid-puzzle-3d-assets 的 Blender 腳本產生、預先轉成 .fsceneb
/// （`tools/build_animal.sh` 直接寫進本專案的 assets/models/），步幅、高度等數值
/// 跟模型綁定，換模型要重量（build_animal.sh 會印出要填的值）。
class CountingSpecies {
	const CountingSpecies({
		required this.id,
		required this.name,
		required this.modelPath,
		required this.height,
		required this.minScale,
		required this.maxScale,
		required this.strideSpeed,
		required this.walkAnimRate,
		required this.clearance,
		this.turnRate = kDefaultTurnRate,
	});

	/// 預設的轉身角速度上限（弧度 / 秒）。
	static const double kDefaultTurnRate = 1.6;

	/// 英文代號（Analytics 與語音檔名用，不顯示）。語音：
	/// `assets/audio/voice/counting/how_many_<id>.mp3`（「○○有幾隻呢？」）、
	/// `wrong_<id>.mp3`（「那是○○喔！」），每種動物各自錄製，[name] 要跟錄音念法一致。
	final String id;

	/// 題目與回饋文字用的名稱（例如「狐狸」）。
	final String name;

	/// 模型路徑。build hook 把 .fsceneb 複製進 flutter_scene_generated/，
	/// `loadScene` 以這個原始路徑載入。模型需有 Idle / Walk 兩段動畫。
	final String modelPath;

	/// 模型高度（縮放 1、站姿）。取景時地面上方要預留最高的動物的空間。
	final double height;

	/// 每隻隨機抽的縮放範圍。
	final double minScale;
	final double maxScale;

	/// Walk 動畫原速播放時，著地腳掌往後退的速度（模型單位 / 秒）。身體用同樣的速度
	/// 往前走，腳才會踩住地面不打滑。
	final double strideSpeed;

	/// 走路動畫的播放倍率（相對原速）。
	final double walkAnimRate;

	/// 兩隻中心的最小距離（約為身長，縮放 1 時）。
	final double clearance;

	/// 轉身角速度上限（弧度 / 秒）。步伐快的動物轉身要快一點，不然像原地踏步。
	final double turnRate;
}

/// 所有動物。數值在第 0 階段原型（spike/3d-counting 分支）的微調面板上調定後凍結。
///
/// 縮放：熊、大象、老虎、小馬、小豬等原本的縮放都放大過，看起來才不會比狐狸還小。
/// 步幅速度與保持距離都跟縮放成正比，會自動跟著變。
const List<CountingSpecies> kCountingSpecies = <CountingSpecies>[
	CountingSpecies(
		id: "fox",
		name: "狐狸",
		modelPath: "assets/models/QFoxLite.fsceneb",
		height: 1.319,
		minScale: 0.8,
		maxScale: 0.95,
		strideSpeed: 0.670,
		walkAnimRate: 0.6,
		clearance: 1.75,
	),
	CountingSpecies(
		id: "turtle",
		name: "烏龜",
		modelPath: "assets/models/QTurtleLite.fsceneb",
		height: 0.74,
		minScale: 0.765,
		maxScale: 0.9,
		strideSpeed: 0.296,
		walkAnimRate: 0.7,
		clearance: 1.6,
	),
	// 移動是「跳」：建模只量著地期，空中也在前進，畫面上要放大才不打滑（原型上調出）
	CountingSpecies(
		id: "rabbit",
		name: "兔子",
		modelPath: "assets/models/QRabbitLite.fsceneb",
		height: 1.244,
		minScale: 0.85,
		maxScale: 0.95,
		strideSpeed: 1.063,
		walkAnimRate: 0.7,
		clearance: 1.2,
	),
	CountingSpecies(
		id: "horse",
		name: "小馬",
		modelPath: "assets/models/QHorseLite.fsceneb",
		height: 1.274,
		minScale: 1.26,
		maxScale: 1.4,
		strideSpeed: 0.793,
		walkAnimRate: 0.6,
		clearance: 1.6,
	),
	CountingSpecies(
		id: "elephant",
		name: "大象",
		modelPath: "assets/models/QElephantLite.fsceneb",
		height: 1.125,
		minScale: 1.575,
		maxScale: 1.732,
		strideSpeed: 0.482,
		walkAnimRate: 0.6,
		clearance: 1.6,
	),
	CountingSpecies(
		id: "tiger",
		name: "老虎",
		modelPath: "assets/models/QTigerLite.fsceneb",
		height: 1.081,
		minScale: 1.275,
		maxScale: 1.425,
		strideSpeed: 0.620,
		walkAnimRate: 0.6,
		clearance: 1.75,
	),
	CountingSpecies(
		id: "pig",
		name: "小豬",
		modelPath: "assets/models/QPigLite.fsceneb",
		height: 0.949,
		minScale: 1.105,
		maxScale: 1.235,
		strideSpeed: 0.775,
		walkAnimRate: 0.6,
		clearance: 1.6,
	),
	CountingSpecies(
		id: "bear",
		name: "熊",
		modelPath: "assets/models/QBearLite.fsceneb",
		height: 0.895,
		minScale: 1.496,
		maxScale: 1.654,
		strideSpeed: 0.552,
		walkAnimRate: 0.6,
		clearance: 1.6,
	),
	// 走路時頭部停滯（動畫裡頭相對身體以 strideSpeed 往後退）：移動速度必須跟
	// strideSpeed 一致，頭在畫面上才會停住。pigeon.py 的 STRIDE_GAIN 要一起改
	CountingSpecies(
		id: "pigeon",
		name: "鴿子",
		modelPath: "assets/models/QPigeonLite.fsceneb",
		height: 0.835,
		minScale: 0.91,
		maxScale: 1.015,
		strideSpeed: 1.199,
		walkAnimRate: 0.8,
		clearance: 1.0,
		turnRate: 4.0,
	),
	// 搖擺步、走得慢：轉身太慢會一直原地踏步
	CountingSpecies(
		id: "penguin",
		name: "企鵝",
		modelPath: "assets/models/QPenguinLite.fsceneb",
		height: 1.039,
		minScale: 1.1,
		maxScale: 1.25,
		strideSpeed: 0.151,
		walkAnimRate: 1.0,
		clearance: 0.9,
		turnRate: 2.5,
	),
	CountingSpecies(
		id: "panda",
		name: "貓熊",
		modelPath: "assets/models/QPandaLite.fsceneb",
		height: 0.92,
		minScale: 1.4,
		maxScale: 1.55,
		strideSpeed: 0.529,
		walkAnimRate: 0.6,
		clearance: 1.6,
	),
	// 雙腳同步的「跳」；建模量到 1.277，畫面上要 1.5 倍才不打滑（原型上調出，原因同兔子）
	CountingSpecies(
		id: "kangaroo",
		name: "袋鼠",
		modelPath: "assets/models/QKangarooLite.fsceneb",
		height: 1.282,
		minScale: 1.3,
		maxScale: 1.456,
		strideSpeed: 1.915,
		walkAnimRate: 0.85,
		clearance: 1.3,
	),
];
