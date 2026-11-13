import "dart:async";
import "dart:math";
import "dart:ui" as ui;

import "package:flutter/foundation.dart" show kDebugMode;
import "package:flutter/material.dart" hide Animation, Material;
import "package:flutter_scene/scene.dart";
import "package:provider/provider.dart";
import "package:showcaseview/showcaseview.dart";
import "package:vector_math/vector_math.dart" as vm;

import "../../../core/analytics/analytics_service.dart";
import "../../../core/audio/audio_service.dart";
import "../../../core/audio/voice_service.dart";
import "../../../core/constants/ui_strings.dart";
import "../../../core/sprites/sprite_manifest.dart";
import "../../../core/sprites/sprite_registry.dart";
import "../../../core/storage/settings_repository.dart";
import "../../../core/system/interop.dart" as interop;
import "../../../shared/widgets/centered_showcase_bubble.dart";
import "../../../shared/widgets/font_ready_signal.dart";
import "../../../shared/widgets/loading_spinner_overlay.dart";
import "../../puzzle/presentation/widgets/level_complete_overlay.dart";
import "../../shared/board_close_button.dart";
import "../../shared/cooldown_picker.dart";
import "../../shared/screen_lock_option.dart";
import "../domain/camera_fit.dart";
import "../domain/counting_round.dart";
import "../domain/counting_species.dart";
import "../domain/occlusion.dart";
import "../domain/tap_vote.dart";
import "../domain/wander.dart";
import "render/ink_outline_pass.dart";
import "render/toon_materials.dart";
import "counting_voice_loader.dart";
import "widgets/answer_choices.dart";
import "widgets/unsupported_3d_notice.dart";

/// 練習數數的進入參數（由設定頁 / 家長設定決定）。
class CountingArguments {
	const CountingArguments({
		this.targetMin = 1,
		this.targetMax = 7,
		this.othersMin = 0,
		this.othersMax = 3,
		this.answerMode = CountingAnswerMode.autoComplete,
		this.glow = true,
		this.screenLockEnabled = false,
		this.firstTarget,
	});

	/// 題目動物 / 其他動物的隻數範圍。
	final int targetMin;
	final int targetMax;
	final int othersMin;
	final int othersMax;

	final CountingAnswerMode answerMode;

	/// 已數過的動物身上有沒有金色光輝（給新手幼兒的提示）。
	final bool glow;

	/// 進入關卡時是否啟動 app pinning（只在 Android 有效）。
	final bool screenLockEnabled;

	/// 第一關的題目動物（設定頁一打開就先抽好、預載了它的開場白）；null = 進來再抽。
	final CountingSpecies? firstTarget;
}

// ───────── 場景常數（第 0 階段原型上調定後凍結） ─────────

/// 俯瞰角度與垂直視角（度）。視角窄、眼睛退得遠，遠近差異小。
const double _pitchDeg = 20.0;
const double _fovDeg = 15.0;

/// 圓形地面的半徑（[_worldScaleFor] = 1 時）；動物中心離邊緣至少 [_boundMargin]（預留身長），
/// 頭再往外伸 [_headReach]；散布點離邊緣 [_spotMargin] 以上、彼此距離 [_spotSpacing] 以上。
/// 預留量不隨地面縮放。
const double _groundRadius = 4.8;

/// 地面多大時剛好容納幾隻（縮放 1）。
const int _animalsPerUnitWorld = 6;

/// 地面半徑的縮放：動物多時地面面積跟數量成正比（每隻的活動空間不變），攝影機
/// 等比例拉遠，整個畫面看起來是縮小的同一種密度。
double _worldScaleFor(int animals) => max(1.0, sqrt(animals / _animalsPerUnitWorld));
const double _boundMargin = 0.9;
const double _headReach = 0.5;
const double _spotMargin = 1.3;
const double _spotSpacing = 2.4;

/// 攝影機注視點（取景時只沿畫面上下方向平移）。
final vm.Vector3 _camTarget = vm.Vector3(0, 0.4, 0);

/// 最大轉彎半徑：走得快、轉得慢的話，近處偏一側的目的地會落在轉彎圓裡，永遠對不準、
/// 一直原地繞圈，所以轉身速度至少要讓轉彎半徑不超過這個值。
const double _maxTurnRadius = 0.5;

/// 地面沿視線往後退的量（ground.fmat 的 depth_offset，× 到攝影機的距離 / 參考距離）：
/// 腳底貼地的地方才不會被地面蓋掉。
const double _groundDepthOffset = 0.03;
const double _depthRefDist = 10.23;

/// 投影影子：光線方向（跟 toon.fmat 的 light_direction 一樣，影子才跟身上的明暗一致）、濃度。
final vm.Vector3 _lightDirection = vm.Vector3(-0.5, -0.8, -0.45);
const double _shadowOpacity = 0.35;

/// 點擊容錯：點上方半圓的半徑與取樣間距（邏輯像素），同 2D 拼圖（touch_vote_hit.dart）。
/// 間距 8 時細的部位（腿、脖子、耳朵）會從樣本之間漏掉，判定偏嚴。
const double _tapRadius = 24;
const double _tapStep = 4;

/// 點擊範圍內的取樣點，由近到遠（見 [pickNearestByTier]）。
final List<({double dx, double dy})> _tapSamples = upperHalfDiscSamples(_tapRadius, _tapStep);

/// 題目動物出場時至少要看得到多少：被前面不同種的動物擋住的部分不超過 1/3（同類擋住不算）。
/// 排不出來時試 [_layoutAttempts] 次，取最好的一次。
const double _minTargetVisible = 2 / 3;
const int _layoutAttempts = 40;

/// 每試幾次換一組位置（其餘只重新分配哪隻站哪裡、朝哪邊）。
const int _layoutRespotEvery = 5;

/// 被點到時的彈跳時間（秒）與幅度。
const double _bounceDuration = 0.45;
const double _bounceAmount = 0.35;

/// 最後一隻數到（或選對數字）、數字唸完之後，再停多久才放過關音效與鼓勵語。
const Duration _completeHold = Duration(milliseconds: 400);

/// 等最後一個數字唸完的上限：語音 future 出錯或逾時都不能擋住過關（同記憶遊戲）。
const Duration _voiceWaitLimit = Duration(seconds: 4);

/// 開場白最多等多久載好（設定頁通常已經預載）；來不及就只有題目文字。
const Duration _questionVoiceWait = Duration(milliseconds: 1500);

/// 過關語音最多等多久載好；來不及就改播共用的過關鼓勵語。
const Duration _correctVoiceWait = Duration(seconds: 2);

/// 點錯動物：「叭叭」音效之後隔多久再唸「那是○○喔！」。
const Duration _wrongVoiceDelay = Duration(milliseconds: 250);

/// 所有動物裡最高的那種（最大縮放）的高度，再多留 10% 給動作（跳起來、抬頭）。
final double _maxAnimalHeight =
		kCountingSpecies.map((CountingSpecies s) => s.height * s.maxScale).reduce(max) * 1.1;

/// 場上的一隻動物。
class _Animal {
	_Animal({
		required this.id,
		required this.species,
		required this.node,
		required this.scale,
		required this.agent,
		required this.idleClip,
		required this.walkClip,
	});

	/// 在這一關的代號（給 [CountingRound] 用）。
	final int id;
	final CountingSpecies species;
	final Node node;
	final double scale;
	final WanderAgent agent;
	final AnimationClip idleClip;
	final AnimationClip walkClip;

	/// 被點到時的彈跳動畫進度（秒）；null = 沒在彈。
	double? bounceT;
}

/// 一種動物載入後的模型與動畫（同種動物從這裡複製）。
class _Template {
	const _Template(this.node, this.idle, this.walk, this.bounds);
	final Node node;
	final Animation idle;
	final Animation walk;

	/// 模型外框（縮放 1、站姿），出場位置的遮擋檢查用。
	final vm.Aabb3 bounds;
}

/// 一隻動物的出場安排。[yaw] 同 [WanderAgent.yaw]。
class _SpawnPlan {
	const _SpawnPlan(this.species, this.spot, this.yaw, this.scale);
	final CountingSpecies species;
	final vm.Vector2 spot;
	final double yaw;
	final double scale;
}

/// 模型所有 mesh 外框的聯集（模型座標）；量不到時用高度與身長估。
vm.Aabb3 _modelBounds(Node root, CountingSpecies species) {
	vm.Aabb3? out;
	walkNodes(root, (Node n) {
		final List<MeshPrimitive> prims = n.mesh?.primitives ?? <MeshPrimitive>[];
		if (prims.isEmpty) return;
		final vm.Matrix4 m = n.globalTransform;
		for (final MeshPrimitive p in prims) {
			final vm.Aabb3? b = p.geometry.localBounds;
			if (b == null) continue;
			final vm.Aabb3 w = vm.Aabb3.copy(b)..transform(m);
			if (out == null) {
				out = w;
			} else {
				out!.hull(w);
			}
		}
	});
	final vm.Aabb3? b = out;
	if (b != null && b.max.y > b.min.y) return b;
	final double c = species.clearance;
	return vm.Aabb3.minMax(vm.Vector3(-c * 0.3, 0, -c * 0.45), vm.Vector3(c * 0.3, species.height, c * 0.45));
}

/// 3D 練習數數：場上有幾種 Q 版動物走來走去，數題目指定的那一種有幾隻。
class CountingPage extends StatelessWidget {
	const CountingPage({super.key});

	@override
	Widget build(BuildContext context) {
		final Object? args = ModalRoute.of(context)?.settings.arguments;
		final CountingArguments a = args is CountingArguments ? args : const CountingArguments();
		return Scaffold(
			backgroundColor: const Color(0xFFFFF6E5),
			body: interop.supports3d
					? _CountingStage(args: a)
					: Stack(
							children: <Widget>[
								const Positioned.fill(child: Unsupported3dNotice()),
								Positioned(top: 12, right: 12, child: _closeButton(context)),
							],
						),
		);
	}
}

Widget _closeButton(BuildContext context) => BoardCloseButton(
	repaint: null,
	bigKidMode: context.read<SettingsRepository>().bigKidMode,
	shouldHide: () => false,
	onClose: () => Navigator.of(context).maybePop(),
);

class _CountingStage extends StatefulWidget {
	const _CountingStage({required this.args});

	final CountingArguments args;

	@override
	State<_CountingStage> createState() => _CountingStageState();
}

class _CountingStageState extends State<_CountingStage> {
	/// 反鋸齒用 FXAA，不用預設的 auto（Android 上會選 MSAA）：MSAA 把輪廓像素的深度編碼
	/// 平均掉，描邊判斷每幀不同，動物輕輕晃動時線條會閃爍。
	final Scene _scene = Scene()..antiAliasingMode = AntiAliasingMode.fxaa;
	final Random _random = Random();
	final ToonMaterials _toon = ToonMaterials();
	final Map<CountingSpecies, _Template> _templates = <CountingSpecies, _Template>{};

	/// 題目動物的冷卻抽樣（同其他模式抽類別）：最近當過題目的動物幾關內不會再出。
	late final CooldownPicker<CountingSpecies> _targetPicker = CooldownPicker<CountingSpecies>(random: _random);

	late final PerspectiveCamera _camera = PerspectiveCamera(
		position: _camTarget + cameraDirOf(_pitchDeg) * 12.6,
		target: _camTarget.clone(),
		fovRadiansY: _fovDeg * vm.degrees2Radians,
	);

	/// 上次取景用的畫面長寬比（null = 還沒取景）。
	double? _fitAspect;
	CameraFit? _fit;

	InkOutlinePass? _inkPass;
	late final PreprocessedMaterial _groundMat;

	/// 地面與接影平面（半徑 1，依這一關的地面大小縮放）。
	late final Node _ground;
	late final Node _catcher;

	/// 這一關的地面半徑（[_worldScaleFor]）。
	double _radius = _groundRadius;
	bool _sceneReady = false;
	String? _error;

	// 這一關
	CountingRoster? _roster;
	CountingRound? _round;
	final List<_Animal> _animals = <_Animal>[];
	WanderField? _field;
	String _message = "";
	bool _loading = true;
	bool _showComplete = false;
	double _glowTime = 0;

	/// 遊戲頁教學（畫面中央純氣泡）。第一次進來、第一關動物出場後顯示一次；
	/// 顯示期間不接受點動物（Showcase backdrop 的 tap 才收得到）。
	final GlobalKey _tutorialKey = GlobalKey();
	late final ShowcaseView _showcase;
	bool _tutorialActive = false;

	/// 遊戲頁教學「當前版本」。更新教學內容時 bump 此值，舊使用者會重看一次。
	static const int _tutorialVersion = 1;
	static const String _tutorialScreen = "counting";

	/// 動物出場後等多久才跳教學氣泡，讓玩家先看到場景、聽完開場白。
	static const Duration _tutorialDelay = Duration(milliseconds: 1800);

	@override
	void initState() {
		super.initState();
		_showcase = ShowcaseView.register(
			scope: _tutorialScreen,
			disableMovingAnimation: true,
			onFinish: () => unawaited(AnalyticsService.instance.logTutorialComplete(_tutorialScreen)),
		);
		unawaited(_init());
	}

	@override
	void dispose() {
		_showcase.unregister();
		// 解除 app pinning；非 Android / 未啟用都 no-op
		disableScreenLockGuard();
		super.dispose();
	}

	Future<void> _maybeStartTutorial() async {
		final SettingsRepository repo = context.read<SettingsRepository>();
		if (repo.tutorialVersionSeen(_tutorialScreen) >= _tutorialVersion) return;
		await Future.wait(<Future<void>>[waitForFontsReady(), Future<void>.delayed(_tutorialDelay)]);
		// 等待期間已經開始數了就不打擾
		if (!mounted || (_round?.counted ?? 0) > 0) return;
		setState(() => _tutorialActive = true);
		_showcase.startShowCase(<GlobalKey>[_tutorialKey]);
		unawaited(AnalyticsService.instance.logTutorialBegin(_tutorialScreen));
		unawaited(repo.setTutorialVersionSeen(_tutorialScreen, _tutorialVersion));
	}

	/// 教學氣泡被點掉：結束流程、恢復點動物。
	void _dismissTutorial() {
		_showcase.next();
		if (!mounted) return;
		setState(() => _tutorialActive = false);
	}

	Future<void> _init() async {
		await maybeEnableScreenLock(widget.args.screenLockEnabled);
		try {
			await Scene.initializeStaticResources();
			final InkOutlinePass? ink = await InkOutlinePass.load();
			if (ink != null) {
				_inkPass = ink;
				_scene.addRenderPass(ink);
			}
			// 數字語音包（第一次點動物就要用）：設定頁已經開始載，這裡不等它
			unawaited(_voices.loadNumbers());
			_groundMat = await loadFmatMaterial("assets/materials/ground.fmat");
			_buildGround();
			_sceneReady = true;
			_applyCameraParams();
			await _loadLevel();
			if (mounted) unawaited(_maybeStartTutorial());
		} catch (e, st) {
			debugPrint("練習數數載入失敗：$e\n$st");
			if (mounted) setState(() => _error = "$e");
		}
	}

	/// 語音背景載入（與設定頁共用，見 [CountingVoiceLoader]）。
	late final CountingVoiceLoader _voices = CountingVoiceLoader.of(context);

	/// 預先抽好的下一關（這關一開始就抽，好預載它的語音）。
	CountingRoster? _nextRoster;

	/// 過關卡片左邊的答案數字圖；圖或素材沒有這個數字時回 null（不顯示）。
	Widget? _answerSprite(int n) {
		final ui.Image? sheet = _voices.numberSheet;
		final SpriteItem? item = _voices.numberItems[n];
		if (sheet == null || item == null) return null;
		// 素材四周有很大的透明邊：畫成 160 × 160，但排版只佔中間實際有圖的部分，
		// 透明邊疊出去、不把卡片撐大
		return SizedBox(
			width: 110,
			height: 72,
			child: OverflowBox(
				maxWidth: 160,
				maxHeight: 160,
				child: SizedBox.square(
					dimension: 160,
					child: CustomPaint(
						painter: _SpritePainter(image: sheet, srcRect: context.read<SpriteRegistry>().srcRectOf(item)),
					),
				),
			),
		);
	}

	/// 最後一次唸的數字（過關前要等它唸完）。
	Future<void>? _lastVoice;

	/// 點錯動物：先「叭叭」，接著唸「那是○○喔！」。
	void _onWrongSpecies(CountingRound round, CountingSpecies tapped) {
		context.read<AudioService>().play(SfxKind.error);
		Future<void>.delayed(_wrongVoiceDelay, () {
			if (!mounted || !identical(round, _round)) return;
			// 還沒載好就算了，只有音效
			_voices.speakIfReady(wrongVoice(tapped));
		});
	}

	/// 唸數字 [n]；沒有語音或「語音」開關關著時放 snap 音效。
	void _speakNumber(int n) {
		final SpriteRegistry registry = context.read<SpriteRegistry>();
		final SpriteItem? item = _voices.numberItems[n];
		if (item != null && registry.voiceEnabled && registry.hasNameVoice(item)) {
			_lastVoice = registry.playName(item);
		} else {
			context.read<AudioService>().play(SfxKind.snap);
			_lastVoice = null;
		}
	}

	/// 地面（淡綠色平台）與投影影子的接影平面。光線只用來產生 shadow map：所有材質都是
	/// unlit，不受光照影響。
	void _buildGround() {
		_ground = Node(
			mesh: Mesh(CylinderGeometry(bottomRadius: 1, topRadius: 1, height: 0.05, radialSegments: 128), _groundMat),
		)
			..position = vm.Vector3(0, -0.03, 0)
			..raycastable = false
			..shadowCastingMode = ShadowCastingMode.off;
		_scene.add(_ground);
		// 接影平面比地面頂端（y = -0.005）略高，只畫出被遮住的部分
		final ShadowCatcherMaterial catcher =
				ShadowCatcherMaterial(shadowColor: const Color(0xFF1F3319), aoStrength: 0)..shadowIntensity = _shadowOpacity;
		_catcher = Node(mesh: Mesh(DiscGeometry(radius: 1, segments: 128), catcher))
			..position = vm.Vector3(0, 0.001, 0)
			..raycastable = false
			..shadowCastingMode = ShadowCastingMode.off;
		_scene.add(_catcher);
		_scene.directionalLight = DirectionalLight(direction: _lightDirection, castsShadow: true, shadowMaxDistance: 150);
		_setRadius(_groundRadius);
	}

	/// 改地面大小（換關時依動物數），並重新取景。
	void _setRadius(double r) {
		_radius = r;
		_ground.scale = vm.Vector3(r, 1, r);
		_catcher.scale = vm.Vector3(r, 1, r);
		final double? aspect = _fitAspect;
		if (aspect != null) _refit(aspect);
	}

	/// 載入（或換）一關：抽題目、載入還沒用過的模型、把動物散布在地面上。
	Future<void> _loadLevel() async {
		setState(() {
			_loading = true;
			_showComplete = false;
		});
		final CountingSpecies? first = _roster == null ? widget.args.firstTarget : null;
		// 第一關用設定頁抽好的題目（單一候選的 pick 只是記進冷卻紀錄）；之後用預先抽好的下一關
		final CountingRoster roster = _nextRoster ?? _rollRoster(first != null ? <CountingSpecies>[first] : kCountingSpecies);
		_nextRoster = null;
		// 開場白要在動物出場時唸：排到最前面，跟模型一起載
		_voices.prefetch(<String>[howManyVoice(roster.target)], urgent: true);
		for (final (CountingSpecies species, _) in roster.entries) {
			if (_templates.containsKey(species)) continue;
			final Node node = await loadScene(species.modelPath);
			await _toon.prepare(node);
			final Animation? idle = node.findAnimationByName("Idle");
			final Animation? walk = node.findAnimationByName("Walk");
			if (idle == null || walk == null) throw StateError("${species.modelPath} 缺少 Idle / Walk 動畫");
			_templates[species] = _Template(node, idle, walk, _modelBounds(node, species));
		}
		// 新載入的材質也要設深度編碼
		_applyCameraParams();
		for (final _Animal a in _animals) {
			_scene.remove(a.node);
		}
		_animals.clear();
		_nodeOwner.clear();
		_setRadius(_groundRadius * _worldScaleFor(roster.total));
		for (final _SpawnPlan p in _planLayout(roster)) {
			_animals.add(_spawn(_animals.length, p));
		}
		_field = WanderField(
			agents: <WanderAgent>[for (final _Animal a in _animals) a.agent],
			bound: _radius - _boundMargin,
			random: _random,
		);
		if (!mounted) return;
		setState(() {
			_roster = roster;
			_round = CountingRound(targetCount: roster.targetCount, mode: widget.args.answerMode, random: _random);
			_message = CountingStrings.question(roster.target.name);
			_loading = false;
		});
		// 開場白「○○有幾隻呢？」
		unawaited(_voices.speakWhenReady(howManyVoice(roster.target), _questionVoiceWait));
		_prefetchAhead(roster);
	}

	/// 抽一關的名單；題目動物用冷卻抽樣，從 [candidates] 裡抽。
	CountingRoster _rollRoster(List<CountingSpecies> candidates) {
		final CountingArguments args = widget.args;
		return CountingRoster.random(
			_random,
			target: _targetPicker.pick(candidates),
			minTarget: args.targetMin,
			maxTarget: args.targetMax,
			minOthers: args.othersMin,
			maxOthers: args.othersMax,
		);
	}

	/// 一關開始後的背景載入：這關的點錯 / 過關語音 → 先抽好下一關、載它的 → 其餘。
	void _prefetchAhead(CountingRoster roster) {
		final CountingRoster next = _nextRoster = _rollRoster(kCountingSpecies);
		final CountingArguments args = widget.args;
		_voices
			..prefetch(CountingVoiceLoader.voicesOf(roster), urgent: true)
			..prefetch(CountingVoiceLoader.voicesOf(next))
			..prefetch(CountingVoiceLoader.remainingVoices(args.targetMin, args.targetMax));
	}

	/// 安排出場位置、朝向、大小：題目動物不能一開始就被前面的大動物擋住（見
	/// [_minTargetVisible]）。不合格就重新分配哪隻站哪裡（每幾次換一組位置）。
	List<_SpawnPlan> _planLayout(CountingRoster roster) {
		final List<CountingSpecies> kinds = <CountingSpecies>[
			for (final (CountingSpecies s, int count) in roster.entries)
				for (int i = 0; i < count; i++) s,
		];
		// 第一關可能還沒排版過：先用常見的長寬比取景（之後畫面量到實際比例會再取景）
		if (_fitAspect == null) _refit(16 / 9);
		List<vm.Vector2> spots = const <vm.Vector2>[];
		List<_SpawnPlan>? best;
		double bestScore = -1;
		int attempt = 0;
		for (; attempt < _layoutAttempts; attempt++) {
			if (attempt % _layoutRespotEvery == 0) {
				spots = pickSpots(kinds.length, _random, radius: _radius - _spotMargin, spacing: _spotSpacing);
			}
			final List<vm.Vector2> order = List<vm.Vector2>.of(spots)..shuffle(_random);
			final List<_SpawnPlan> plans = <_SpawnPlan>[
				for (int i = 0; i < kinds.length; i++)
					_SpawnPlan(
						kinds[i],
						order[i],
						_random.nextDouble() * 2 * pi,
						kinds[i].minScale + _random.nextDouble() * (kinds[i].maxScale - kinds[i].minScale),
					),
			];
			final double score = minTargetVisibility(
				<ScreenProxy>[for (final _SpawnPlan p in plans) _proxyOf(p)],
				(int i) => identical(plans[i].species, roster.target),
			);
			if (score > bestScore) {
				best = plans;
				bestScore = score;
			}
			if (score >= _minTargetVisible) break;
		}
		if (kDebugMode || bestScore < _minTargetVisible) {
			debugPrint("[layout] 試 ${min(attempt + 1, _layoutAttempts)} 次，題目動物最少看得到 "
					"${(bestScore * 100).round()}%");
		}
		return best!;
	}

	/// 一隻動物出場時在畫面上的範圍：模型外框的 8 個角投影到畫面（以畫面高為 1）的範圍，
	/// 取內切橢圓。
	ScreenProxy _proxyOf(_SpawnPlan p) {
		final ui.Size view = ui.Size(_fitAspect ?? 16 / 9, 1);
		final vm.Aabb3 b = _templates[p.species]!.bounds;
		final vm.Matrix4 m = vm.Matrix4.compose(
			vm.Vector3(p.spot.x, 0, p.spot.y),
			vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), p.yaw + pi),
			vm.Vector3.all(p.scale),
		);
		double x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
		for (int i = 0; i < 8; i++) {
			final vm.Vector3 corner = vm.Vector3(
				i & 1 == 0 ? b.min.x : b.max.x,
				i & 2 == 0 ? b.min.y : b.max.y,
				i & 4 == 0 ? b.min.z : b.max.z,
			);
			final Offset? s = _camera.worldToScreen(m.transformed3(corner), view);
			if (s == null) continue;
			x0 = min(x0, s.dx);
			y0 = min(y0, s.dy);
			x1 = max(x1, s.dx);
			y1 = max(y1, s.dy);
		}
		if (x0 > x1) return ScreenProxy(cx: 0, cy: 0, rx: 0, ry: 0, depth: double.infinity, kind: p.species);
		return ScreenProxy(
			cx: (x0 + x1) / 2,
			cy: (y0 + y1) / 2,
			rx: (x1 - x0) / 2,
			ry: (y1 - y0) / 2,
			depth: _camera.position.distanceTo(m.transformed3(b.center)),
			kind: p.species,
		);
	}

	/// 放一隻動物：複製模型、上 toon 材質；站 / 走兩段動畫從隨機時間點開始一直循環播放
	/// （靠權重切換）。每隻的步調略有差異。
	_Animal _spawn(int id, _SpawnPlan plan) {
		final CountingSpecies species = plan.species;
		final _Template t = _templates[species]!;
		final Node node = t.node.clone();
		final double scale = plan.scale;
		node.scale = vm.Vector3.all(scale);
		_toon.apply(node);
		final double speedScale = 0.85 + _random.nextDouble() * 0.3;
		AnimationClip makeClip(Animation a, double weight, double rate) {
			final AnimationClip clip = node.createAnimationClip(a)
				..loop = true
				..playbackTimeScale = rate
				..weight = weight;
			clip.playbackTime = _random.nextDouble() * a.endTime;
			clip.play();
			return clip;
		}

		final double walkSpeed = species.strideSpeed * scale * species.walkAnimRate * speedScale;
		final _Animal a = _Animal(
			id: id,
			species: species,
			node: node,
			scale: scale,
			idleClip: makeClip(t.idle, 1, speedScale),
			walkClip: makeClip(t.walk, 0, speedScale * species.walkAnimRate),
			agent: WanderAgent(
				pos: plan.spot.clone(),
				yaw: plan.yaw,
				walkSpeed: walkSpeed,
				turnRate: max(species.turnRate * speedScale, walkSpeed / _maxTurnRadius),
				stepDuration: (t.walk.endTime / 2) / (speedScale * species.walkAnimRate),
				clearance: species.clearance * scale,
				// 第一次出發的時間錯開，避免同時起步
				timer: 0.5 + _random.nextDouble() * 4,
			),
		);
		_place(a);
		_scene.add(node);
		walkNodes(node, (Node n) => _nodeOwner[n] = a);
		return a;
	}

	/// 把位置 / 朝向寫回節點。朝向多轉 180°：.fsceneb 的座標是 flutter_scene 的慣例
	/// （Z 反向），模型頭朝 -Z；[forwardOf] 以 +Z 為前方，轉半圈才對得上。
	void _place(_Animal a) {
		a.node.position = vm.Vector3(a.agent.pos.x, 0, a.agent.pos.y);
		a.node.rotation = vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), a.agent.yaw + pi);
		a.walkClip.weight = a.agent.walkWeight;
		a.idleClip.weight = 1 - a.agent.walkWeight;
	}

	/// 依畫面長寬比重新取景。
	void _refit(double aspect) {
		_fitAspect = aspect;
		final CameraFit fit = fitCamera(
			pitchDeg: _pitchDeg,
			fovDeg: _fovDeg,
			aspect: aspect,
			groundRadius: _radius,
			topRadius: _radius - _boundMargin + _headReach,
			maxHeight: _maxAnimalHeight,
			baseTarget: _camTarget,
		);
		_fit = fit;
		_camera
			..target = fit.target.clone()
			..position = fit.eye(_pitchDeg)
			..fovNear = fit.near;
		if (_sceneReady) _applyCameraParams();
	}

	/// 依目前的取景設定地面後退量、深度編碼與影子範圍。
	void _applyCameraParams() {
		final CameraFit? fit = _fit;
		if (fit == null) return;
		_groundMat.parameters.setFloat("depth_offset", _groundDepthOffset * _depthRefDist / fit.distance);
		final double code = _toon.applyCameraParams(
			sceneNear: fit.near,
			sceneFar: fit.far,
			inkOn: _inkPass != null,
			extra: <PreprocessedMaterial>[_groundMat],
		);
		_inkPass?.countedCode = code;
		// 引擎會在影子範圍前至少十分之一的深度內把影子淡出，要多留這一段
		_scene.directionalLight?.shadowMaxDistance = fit.far / 0.9;
	}

	void _onTick(Duration elapsed, double dt) {
		// 分頁切回前景等情況 dt 可能很大，夾住避免一次跳太遠
		final double step = min(dt, 0.1);
		_glowTime += step;
		final CountingRound? round = _round;
		_inkPass
			?..glowRadius = widget.args.glow && (round?.counted ?? 0) > 0 ? InkOutlinePass.kGlowRadius : 0
			..glowStrength = 0.9 + 0.1 * sin(_glowTime * 3);
		_field?.update(step);
		for (final _Animal a in _animals) {
			_place(a);
			final double? bt = a.bounceT;
			if (bt == null) continue;
			final double nt = bt + step;
			final double k = nt >= _bounceDuration ? 0 : sin(nt / _bounceDuration * pi);
			a.node.scale = vm.Vector3.all(a.scale * (1 + _bounceAmount * k));
			a.bounceT = nt >= _bounceDuration ? null : nt;
		}
	}

	/// 被打中的是模型裡的某個 mesh 節點，往上找到它屬於哪一隻（地面等回傳 null）。
	_Animal? _animalOfNode(Node node) => _nodeOwner[node];

	/// 每隻動物底下的所有節點 → 那隻動物（點擊判定用；raycast 打中的是 mesh 節點）。
	final Map<Node, _Animal> _nodeOwner = <Node, _Animal>{};

	/// 按下的瞬間就算點擊（以按下的位置判定）：幼兒常常手指放下去後滑一點、按久一點
	/// 才抬起，等放開再判斷（要求按得短、沒拖動）會漏掉很多次。每個指頭各自算。
	void _onPointerDown(PointerDownEvent e, Size viewSize) => _onTap(e.localPosition, viewSize);

	/// 選取的優先順序：還沒數過的題目動物 > 數過的題目動物 > 其他。
	int _tier(_Animal a) {
		final CountingRoster? roster = _roster;
		if (roster == null || !identical(a.species, roster.target)) return 0;
		return _round?.numberOf(a.id) == null ? 2 : 1;
	}

	/// 點擊判定，比照 2D 拼圖（touch_vote_hit.dart）：手指會擋住目標，使用者多半對在目標
	/// 下緣，所以取點上方半圓內的樣本投票。滑鼠也一樣放寬（2D 拼圖的滑鼠是精準命中）：
	/// 引擎對骨架模型用靜止姿勢測試、不跟著動作變形，走路中的腳、尾巴跟畫面對不上，
	/// 單點很容易落空。
	/// 選擇時先比優先順序（[_tier]）、同級選離手指中心最近的：題目動物被擋住、或只有一角
	/// 落在範圍內也會選到。
	void _onTap(Offset position, Size viewSize) {
		final CountingRound? round = _round;
		final CountingRoster? roster = _roster;
		if (_loading || _tutorialActive || round == null || roster == null || round.phase != CountingPhase.counting) {
			return;
		}
		final Stopwatch sw = Stopwatch()..start();
		int rays = 0;
		// 由近到遠一條一條 raycast，只測可能贏過目前結果的動物，找到最高優先就停
		final _Animal? a = pickNearestByTier<_Animal>(
			rayCount: _tapSamples.length,
			castRay: (int i, int minTier) {
				rays++;
				final ({double dx, double dy}) o = _tapSamples[i];
				return <_Animal>{
					for (final SceneRaycastHit hit in _scene.raycastAll(
						_camera.screenPointToRay(position + Offset(o.dx, o.dy), viewSize),
						where: (Node n) {
							final _Animal? owner = _nodeOwner[n];
							return owner != null && _tier(owner) > minTier;
						},
					))
						?_animalOfNode(hit.node),
				};
			},
			tier: _tier,
			maxTier: 2,
		);
		if (kDebugMode || sw.elapsedMilliseconds > 50) {
			debugPrint("[tap] $rays 條視線 ${sw.elapsedMilliseconds} ms → ${a?.species.name}");
		}
		if (a == null) return;
		final CountingTapResult result = round.tap(a.id, isTarget: identical(a.species, roster.target));
		final AudioService audio = context.read<AudioService>();
		setState(() {
			switch (result) {
				case CountingTapIgnored():
					break;
				case CountingTapWrongSpecies():
					_onWrongSpecies(round, a.species);
					_message = CountingStrings.wrongSpecies(a.species.name);
				case CountingTapRepeated():
					audio.play(SfxKind.click);
					// 「這隻數過囉！」還沒載好就算了，只有音效
					_voices.speakIfReady(repeatedVoice);
					_message = CountingStrings.repeated;
				case CountingTapCounted(:final int number, :final bool isLast):
					a.bounceT = 0;
					if (widget.args.glow) _toon.setCounted(a.node, true);
					if (round.mode == CountingAnswerMode.autoComplete) {
						// 每數一隻唸出累計數字
						_speakNumber(number);
						_message = isLast
								? CountingStrings.allCounted(number, roster.target.name)
								: CountingStrings.counted(number);
						if (isLast) unawaited(_completeLevel(round));
					} else {
						// 選數字模式點的時候不唸數字（不然等於直接告訴答案）
						audio.play(SfxKind.snap);
						_message = isLast
								? CountingStrings.askAnswer(roster.target.name)
								: CountingStrings.question(roster.target.name);
					}
			}
		});
	}

	void _onAnswer(int value) {
		final CountingRound? round = _round;
		final CountingRoster? roster = _roster;
		if (round == null || roster == null) return;
		final CountingAnswerResult result = round.answer(value);
		if (result == CountingAnswerResult.ignored) return;
		setState(() {
			if (result == CountingAnswerResult.correct) {
				// 選對：過關語音會唸出「一共有 n 隻」，這裡不另外唸數字
				_lastVoice = null;
				_message = CountingStrings.allCounted(value, roster.target.name);
				unawaited(_completeLevel(round));
			} else {
				context.read<AudioService>().play(SfxKind.error);
				_message = CountingStrings.wrongAnswer;
			}
		});
	}

	/// 過關：等最後一個數字唸完（有上限），停一下，放過關音效與鼓勵語、顯示過關畫面。
	Future<void> _completeLevel(CountingRound round) async {
		final Future<void>? lastVoice = _lastVoice;
		if (lastVoice != null) {
			try {
				await lastVoice.timeout(_voiceWaitLimit);
			} catch (_) {}
		}
		await Future<void>.delayed(_completeHold);
		if (!mounted || !identical(round, _round)) return;
		context.read<AudioService>().play(SfxKind.complete);
		// 「答對了！一共有 n 隻！」；超出錄音範圍時退回共用的過關鼓勵語
		final VoiceService voice = context.read<VoiceService>();
		setState(() => _showComplete = true);
		final bool spoke = round.targetCount <= kMaxCorrectVoice &&
				await _voices.speakWhenReady(correctVoice(round.targetCount), _correctVoiceWait);
		if (!spoke && mounted && identical(round, _round)) voice.speakLevelComplete();
	}

	/// 過關畫面點一下：下一關（載入中重複點忽略）。
	void _nextLevel() {
		if (_loading) return;
		unawaited(_loadLevel().catchError((Object e, StackTrace st) {
			debugPrint("練習數數載入下一關失敗：$e\n$st");
			if (mounted) setState(() => _error = "$e");
		}));
	}


	@override
	Widget build(BuildContext context) {
		final CountingRound? round = _round;
		return LayoutBuilder(
			builder: (BuildContext context, BoxConstraints c) {
				final Size size = Size(c.maxWidth, c.maxHeight);
				if (size.height > 0) {
					final double aspect = size.width / size.height;
					final double? fitted = _fitAspect;
					if (fitted == null || (aspect - fitted).abs() > 1e-3) _refit(aspect);
				}
				return Stack(
					children: <Widget>[
						// 題目 / 回饋放在 3D 場景底下（場景背景透明）：靠近上緣的動物疊在標題上，
						// 不會被標題擋住。標題不需要點擊，點擊一律由上層的場景接
						if (!_loading && round != null)
							Positioned(
								top: 16,
								left: 0,
								right: 0,
								child: Center(
									child: Container(
										padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
										decoration: BoxDecoration(
											color: Colors.white.withValues(alpha: 0.9),
											borderRadius: BorderRadius.circular(24),
										),
										child: Text(
											_message,
											style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Color(0xFF6D4C41)),
										),
									),
								),
							),
						if (_error != null)
							Center(child: Text("${CountingStrings.loadFailed}：$_error"))
						else if (_sceneReady)
							Positioned.fill(
								// 用 Listener 每個指頭各自判斷（不用 GestureDetector：手勢辨識一次只追
								// 一個指頭，幼兒另一隻手碰到螢幕時點擊會被取消；而且要放開才算）
								child: Listener(
									behavior: HitTestBehavior.opaque,
									onPointerDown: (PointerDownEvent e) => _onPointerDown(e, size),
									child: SceneView(
										_scene,
										camera: _camera,
										onTick: _onTick,
										// 預先編譯 shader，避免第一次出現新著色組合時卡頓
										warmUp: true,
									),
								),
							),
						if (!_loading && round != null) ...<Widget>[
							if (round.phase == CountingPhase.answering)
								Positioned(
									left: 0,
									right: 0,
									bottom: 24,
									child: Center(child: AnswerChoices(choices: round.choices, onChoose: _onAnswer)),
								),
						],
						if (_showComplete)
							LevelCompleteOverlay(
								region: Offset.zero & size,
								onContinue: _nextLevel,
								leading: round == null ? null : _answerSprite(round.targetCount),
							),
						if (_loading && _error == null) const LoadingSpinnerOverlay(),
						// 第一次進來的教學氣泡（畫面中央，無 highlight）
						CenteredShowcaseBubble(
							showcaseKey: _tutorialKey,
							message: widget.args.answerMode == CountingAnswerMode.chooseNumber
									? CountingStrings.gameTutorialChoose
									: CountingStrings.gameTutorialAuto,
							onTap: _dismissTutorial,
						),
						Positioned(top: 12, right: 12, child: _closeButton(context)),
					],
				);
			},
		);
	}
}

/// 畫 sheet 上的一格素材（等比例塞進正方形）。
class _SpritePainter extends CustomPainter {
	_SpritePainter({required this.image, required this.srcRect});

	final ui.Image image;
	final Rect srcRect;

	@override
	void paint(Canvas canvas, Size size) {
		final double side = size.shortestSide;
		canvas.drawImageRect(
			image,
			srcRect,
			Rect.fromCenter(center: size.center(Offset.zero), width: side, height: side),
			Paint()..filterQuality = FilterQuality.medium,
		);
	}

	@override
	bool shouldRepaint(covariant _SpritePainter oldDelegate) =>
			oldDelegate.image != image || oldDelegate.srcRect != srcRect;
}
