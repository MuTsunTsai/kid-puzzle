import "dart:async";
import "dart:math";
import "dart:ui" as ui;

import "package:flutter/material.dart";
import "package:flutter/scheduler.dart";
import "package:provider/provider.dart";

import "../../../core/audio/audio_service.dart";
import "../../../core/audio/voice_service.dart";
import "../../../core/constants/app_colors.dart";
import "../../../core/network/background_asset_cache.dart";
import "../../../core/sprites/sprite_manifest.dart";
import "../../../core/sprites/sprite_registry.dart";
import "../../../core/sprites/sprite_selection.dart";
import "../../../core/storage/settings_repository.dart";
import "../../../shared/widgets/click_sound.dart";
import "../../../shared/widgets/loading_spinner_overlay.dart";
import "../../puzzle/presentation/puzzle_controller.dart" show PuzzleStageLayout;
import "../../puzzle/presentation/widgets/level_complete_overlay.dart";
import "../../shared/board_close_button.dart";
import "../../shared/cache_aware_picker.dart";
import "../../shared/close_button_overlap.dart";
import "../../shared/cooldown_picker.dart";
import "../../shared/screen_lock_option.dart";
import "../../shared/stage_rescale.dart";
import "inset_puzzle_controller.dart";
import "inset_puzzle_setup_page.dart";
import "widgets/inset_board_painter.dart";
import "widgets/inset_puzzle_canvas.dart";

/// 嵌入拼圖遊戲主畫面。
///
/// 流程：
/// 1. didChangeDependencies 取 InsetPuzzleArguments + 預備 layout
/// 2. _bootstrap：等 SpriteRegistry ready → 隨機抽類別 → newLevel
/// 3. 畫面：[InsetPuzzleCanvas] + 右上長按關閉按鈕（拼片靠近時淡出）
class InsetPuzzlePage extends StatefulWidget {
	const InsetPuzzlePage({super.key});

	@override
	State<InsetPuzzlePage> createState() => _InsetPuzzlePageState();
}

class _InsetPuzzlePageState extends State<InsetPuzzlePage>
		with StageRescaleMixin<InsetPuzzlePage> {
	InsetPuzzleController? _controller;
	final InsetBoardCache _boardCache = InsetBoardCache();
	DateTime? _imageShownAt;
	bool _initialized = false;
	bool _completed = false;
	/// 切下一關期間：spinner overlay + 任何 _goNextLevel 重入皆 no-op。
	/// 點下到新 controller 就緒前都為 true，避免幼兒連點觸發多輪轉場。
	bool _loadingNext = false;
	int _minPieces = 4;
	int _maxPieces = 8;
	bool _allowSimilarSilhouette = false;
	bool _screenLockEnabled = false;
	final Random _random = Random();

	/// 是否還沒抽過任何關卡（用來決定「第一關只選已 cache 類別」）。
	bool _firstLevel = true;

	/// 類別冷卻抽樣器：key = 類別 id。
	late final CooldownPicker<String> _categoryPicker =
			CooldownPicker<String>(random: _random);

	/// 每個類別獨立的 item 冷卻抽樣器（key = item.id）。跨類別冷卻沒意義，
	/// 同一類別內才需要避免短時間內重複出現相同物件。
	final Map<String, CooldownPicker<String>> _itemPickers =
			<String, CooldownPicker<String>>{};

	/// Debug 開關：true 時跑一份獨立的物理模擬、每代繪到 board 上方當動畫。
	/// 與實際關卡互不干擾；觀察完手動關掉。
	static const bool _debugLayoutPhysics = false;

	/// 當前 debug 模擬的 snapshot（容器矩形 + 每片中心 + tile）。null 代表
	/// 還沒開始或已結束。
	_LayoutSnapshot? _debugSnapshot;

	@override
	void didChangeDependencies() {
		super.didChangeDependencies();
		if (_initialized) return;
		_initialized = true;
		final Object? args = ModalRoute.of(context)?.settings.arguments;
		if (args is InsetPuzzleArguments) {
			_minPieces = args.minPieces;
			_maxPieces = args.maxPieces;
			_allowSimilarSilhouette = args.allowSimilarSilhouette;
			_screenLockEnabled = args.screenLockEnabled;
		}
		WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
	}

	@override
	void dispose() {
		_controller?.dispose();
		_boardCache.dispose();
		// 解除 app pinning；非 Android / 未啟用都 no-op。
		disableScreenLockGuard();
		super.dispose();
	}

	Future<void> _bootstrap() async {
		// 家長若於 setup 頁勾選「鎖定畫面」、進入嵌入拼圖時嘗試啟動 app pinning。
		// 失敗（極少數機型 / 模式）就 silently 略過、不卡流程。
		await maybeEnableScreenLock(_screenLockEnabled);
		if (!mounted) return;
		final SpriteRegistry registry = context.read<SpriteRegistry>();
		if (!registry.isLoaded) {
			await registry.load();
			if (!mounted) return;
		}
		if (registry.categories.isEmpty) {
			await _showNoCategoryThenExit();
			return;
		}
		// 套使用者選取 → 至少要有一個類別且該類別至少有一個可用物件才能玩。
		// 為 0 時與「manifest 全空」走相同提示後退出。
		if (_usableCategories(registry).isEmpty) {
			await _showNoCategoryThenExit();
			return;
		}
		await _loadNewLevel();
	}

	/// 算出當下可用的 (category, itemIds) 清單。
	/// 規則 = [SpriteSelection]：父類未選 → 整類不可用；父選但所有子類別都
	/// 沒選 → 該類別無可用 items、視為不可用。
	List<({SpriteCategory category, Set<String> itemIds})> _usableCategories(
			SpriteRegistry registry) {
		final SettingsRepository repo = context.read<SettingsRepository>();
		final Set<String> resolved = SpriteSelection.resolveSelected(
			stored: repo.spriteSelections,
			categories: registry.categories,
		);
		final List<({SpriteCategory category, Set<String> itemIds})> out =
				<({SpriteCategory category, Set<String> itemIds})>[];
		for (final SpriteCategory c in registry.categories) {
			final Set<String> ids = SpriteSelection.usableItemIds(c, resolved);
			if (ids.isNotEmpty) {
				out.add((category: c, itemIds: ids));
			}
		}
		return out;
	}

	/// 重新抽類別 + newLevel + 烤 board，最後 setState 把 controller 換上。
	/// 失敗時不會把舊 controller 留下殘缺狀態（會直接 return）。
	Future<void> _loadNewLevel() async {
		final SpriteRegistry registry = context.read<SpriteRegistry>();
		final AudioService audio = context.read<AudioService>();
		final VoiceService voice = context.read<VoiceService>();
		// 用冷卻抽樣選類別：剛玩過的類別在 0.4 × N 關內絕不重複。
		// 候選池會被使用者選取狀態過濾 — 父未選 / 子全未選的類別都不會出現。
		final List<({SpriteCategory category, Set<String> itemIds})> usable =
				_usableCategories(registry);
		if (usable.isEmpty) {
			// _bootstrap 已先擋過；理論上跑到這代表使用者在遊戲進行中改動了
			// settings、或極端時序。安全 fallback 是退出。
			await _showNoCategoryThenExit();
			return;
		}
		// Cache 偏好細節見 [CacheAwarePicker]。非 web 平台 isSpriteCategoryCached
		// 一律 true、自動退化為純 CooldownPicker 行為。
		final BackgroundAssetCache cache = context.read<BackgroundAssetCache>();
		final bool isFirst = _firstLevel;
		_firstLevel = false;
		final String? catId = CacheAwarePicker.pick<String>(
			picker: _categoryPicker,
			candidates: usable.map((({SpriteCategory category, Set<String> itemIds}) e)
					=> e.category.id),
			isCached: cache.isSpriteCategoryCached,
			firstLevel: isFirst,
		);
		final ({SpriteCategory category, Set<String> itemIds}) selected =
				catId != null
						? usable.firstWhere((({SpriteCategory category, Set<String> itemIds}) e)
								=> e.category.id == catId)
						: usable[_random.nextInt(usable.length)];
		final SpriteCategory category = selected.category;
		final Set<String> usableIds = selected.itemIds;
		final Size size = MediaQuery.of(context).size;
		final PuzzleStageLayout stage = PuzzleStageLayout.forSize(size);

		// Debug 動畫：抽到 items 後存起來，每代 settle 完把 snapshot push 到 UI、
		// 等 endOfFrame 才繼續下一代。這樣 debug 畫面顯示的就是即將實際生成
		// 的關卡（同一條 settle）。
		List<SpriteItem> debugChosen = const <SpriteItem>[];
		ui.Rect debugContainer = ui.Rect.zero;

		// 抽該類別內要用的物件：用該類別專屬 picker、冷卻機制與選圖一致。
		final int pieceCount = _minPieces == _maxPieces
				? _minPieces
				: _minPieces + _random.nextInt(_maxPieces - _minPieces + 1);
		final CooldownPicker<String> itemPicker = _itemPickers.putIfAbsent(
			category.id,
			() => CooldownPicker<String>(random: _random),
		);
		// 候選 = 該類別 items ∩ usableIds（子類別過濾）。
		final Map<String, SpriteItem> byId = <String, SpriteItem>{
			for (final SpriteItem it in category.items) it.id: it,
		};
		// 先把該類別所有 sprite 的 pixel buffer 載好，silhouette 重疊比較
		// 才有 alpha 可查（dilatedMask / alphaBounds 共用同一份 buffer）。
		await registry.preloadCategoryPixels(category);
		// 開啟「允許剪影相似」→ 門檻放寬到 0.95、只擋幾乎完全相同的剪影；
		// 預設關閉 → 門檻 0.85、嚴格排除任何明顯相近的對。
		final double maxSilhouetteOverlap = _allowSimilarSilhouette ? 0.95 : 0.85;
		final List<String> pickedIds = itemPicker.pickManyWhere(
			category.items
					.where((SpriteItem it) => usableIds.contains(it.id))
					.map((SpriteItem it) => it.id),
			pieceCount,
			(String candidateId, List<String> alreadyChosen) {
				final SpriteItem? candidate = byId[candidateId];
				if (candidate == null) return false;
				// 與任一已選物件重疊超過門檻 → 拒收。
				for (final String otherId in alreadyChosen) {
					final SpriteItem? other = byId[otherId];
					if (other == null) continue;
					if (registry.silhouetteOverlapRatio(candidate, other) >
							maxSilhouetteOverlap) {
						return false;
					}
				}
				return true;
			},
		);
		final List<SpriteItem> chosen = <SpriteItem>[
			for (final String id in pickedIds)
				if (byId[id] != null) byId[id]!,
		];

		// 防呆：剪影條件可能把候選池消耗到湊不滿 pieceCount —— 那就少幾個玩。
		// 若連一個都湊不出來（極端情況：類別只剩單一物件且子分類都關了？）
		// 走「無可用素材」退場，避免 controller.newLevel n=0 算 sqrt 炸掉。
		if (chosen.isEmpty) {
			await _showNoCategoryThenExit();
			return;
		}
		if (chosen.length < pieceCount) {
			debugPrint("[inset_puzzle] piece count short: requested=$pieceCount "
					"got=${chosen.length} category=${category.id}");
		}

		final InsetPuzzleController c = await InsetPuzzleController.newLevel(
			stageLayout: stage,
			registry: registry,
			category: category,
			chosen: chosen,
			seed: _random.nextInt(1 << 31),
			onSettleChosen: _debugLayoutPhysics
					? (List<SpriteItem> items, ui.Rect container) {
							debugChosen = items;
							debugContainer = container;
						}
					: null,
			onSettleStep: _debugLayoutPhysics
					? (List<ui.Offset> centers, double tile) async {
							if (!mounted) return;
							setState(() {
								_debugSnapshot = _LayoutSnapshot(
									container: debugContainer,
									centers: centers,
									tile: tile,
									items: debugChosen,
									registry: registry,
									category: category,
								);
							});
							// 等真實 frame 畫完才繼續下一代
							await SchedulerBinding.instance.endOfFrame;
						}
					: null,
		);
		if (!mounted) {
			c.dispose();
			return;
		}
		c.onPickup = () => audio.play(SfxKind.pickup);
		c.onDrop = () => audio.play(SfxKind.drop);
		// 最後一片 snap 觸發的語音 future；onCompleted await 它確保語音念完才出過關畫面。
		Future<void>? lastVoiceFuture;
		c.onSnap = (piece) {
			// 條件：語音開 + 有 clip → 播朗讀；否則 fallback 到 snap 音效。
			// fallback 涵蓋兩種情境：
			// (1) 對應的語音 clip 不存在（zip 內沒有此 itemId）
			// (2) 「語音」開關被關掉
			// 兩種情境下都靠 snap 音效給玩家「成功歸位」的聽覺回饋（前提是
			// 音效開關有開、否則 AudioService 自己會靜默）。
			if (registry.voiceEnabled && registry.hasNameVoice(piece.item)) {
				// 並行 fire-and-forget：每片 snap 都會獨立 player 念完整段、
				// 連續 snap 不會互相打斷（見 SpriteVoicePlayer 實作）。
				// 留一份 future 給 onCompleted 等。
				lastVoiceFuture = registry.playName(piece.item);
			} else {
				audio.play(SfxKind.snap);
				lastVoiceFuture = null;
			}
		};
		c.onCompleted = () async {
			// 過關時最後一片可能正在念名稱語音 → 等它念完、再放過關音 + setState。
			// 沒語音的物件 fallback 立刻接過關音、不卡幼兒。
			final Future<void>? voiceFut = lastVoiceFuture;
			if (voiceFut != null) {
				await voiceFut;
			}
			if (!mounted) return;
			audio.play(SfxKind.complete);
			voice.speakLevelComplete();
			setState(() => _completed = true);
		};

		final double dpr = MediaQuery.devicePixelRatioOf(context);
		await _boardCache.rebuild(
			controller: c,
			totalSize: size,
			devicePixelRatio: dpr,
		);
		if (!mounted) {
			c.dispose();
			return;
		}

		final InsetPuzzleController? old = _controller;
		setState(() {
			_controller = c;
			_imageShownAt = DateTime.now();
			_completed = false;
			// 清掉 debug overlay，不要疊到實際遊戲畫面
			_debugSnapshot = null;
		});
		voice.speakLevelStart();
		old?.dispose();
	}

	/// 點下 overlay → 進下一關。重入鎖避免幼兒連點 / 多指亂按；
	/// 期間顯示 spinner overlay。
	Future<void> _goNextLevel() async {
		if (_loadingNext) return;
		setState(() => _loadingNext = true);
		try {
			await _loadNewLevel();
		} finally {
			if (mounted) setState(() => _loadingNext = false);
		}
	}

	Future<void> _showNoCategoryThenExit() async {
		await showDialog<void>(
			context: context,
			barrierDismissible: false,
			builder: (BuildContext ctx) => AlertDialog(
				title: const Text("沒有可用的素材"),
				content: const Text("尚未準備任何 sprite 類別，請先加入素材。"),
				actions: <Widget>[
					ElevatedButton(
						onPressed: ClickSound.wrap(ctx, () => Navigator.of(ctx).pop()),
						child: const Text("好"),
					),
				],
			),
		);
		if (!mounted) return;
		unawaited(Navigator.of(context).maybePop());
	}

	bool _shouldHideCloseButton() {
		final InsetPuzzleController? c = _controller;
		if (c == null) return false;
		final Size screen = MediaQuery.of(context).size;
		return shouldHideCloseButton(
			screenSize: screen,
			hitTest: c.isOpaqueAtStagePoint,
		);
	}

	@override
	ui.Size? get currentStageSize => _controller?.stageLayout.totalSize;

	@override
	void applyRescale(ui.Size newSize) {
		final InsetPuzzleController? c = _controller;
		if (c == null) return;
		c.rescaleStage(PuzzleStageLayout.forSize(newSize));
		// rescale 後底板尺寸 / slot 位置都變了 → 重烤 bitmap
		final double dpr = MediaQuery.devicePixelRatioOf(context);
		_boardCache.rebuild(
			controller: c,
			totalSize: newSize,
			devicePixelRatio: dpr,
		);
	}

	@override
	Widget build(BuildContext context) {
		return Scaffold(
			backgroundColor: AppColors.boardBackground,
			body: LayoutBuilder(
				builder: (BuildContext context, BoxConstraints constraints) {
					maybeRescaleForSize(
						Size(constraints.maxWidth, constraints.maxHeight),
					);
					return Stack(
				children: <Widget>[
					if (_controller != null)
						InsetPuzzleCanvas(
							controller: _controller!,
							boardCache: _boardCache,
							imageShownAt: _imageShownAt,
						)
					else
						const Center(child: CircularProgressIndicator()),

					// 過關 overlay：與多片拼圖一致、只覆蓋右半散落區
					if (_completed && _controller != null)
						LevelCompleteOverlay(
							region: _controller!.stageLayout.scatterRect,
							onContinue: _goNextLevel,
						),

					// 切下一關期間：全螢幕 spinner，擋住輸入
					if (_loadingNext) const LoadingSpinnerOverlay(),

					// Debug 物理模擬動畫 overlay：畫容器邊框 + 每片中心圓 + tile 方框
					if (_debugLayoutPhysics && _debugSnapshot != null)
						Positioned.fill(
							child: IgnorePointer(
								child: CustomPaint(
									painter: _DebugLayoutPainter(snapshot: _debugSnapshot!),
								),
							),
						),
					if (_controller != null)
						Positioned(
							top: 12,
							right: 12,
							child: BoardCloseButton(
								repaint: _controller!.repaintTick,
								bigKidMode: context.read<SettingsRepository>().bigKidMode,
								shouldHide: _shouldHideCloseButton,
								onClose: () => Navigator.of(context).maybePop(),
							),
						),
				],
			);
				},
			),
		);
	}
}

/// Debug 物理模擬的當代狀態。
class _LayoutSnapshot {
	const _LayoutSnapshot({
		required this.container,
		required this.centers,
		required this.tile,
		required this.items,
		required this.registry,
		required this.category,
	});
	final ui.Rect container;
	final List<ui.Offset> centers;
	final double tile;
	final List<SpriteItem> items;
	final SpriteRegistry registry;
	final SpriteCategory category;
}

/// 在 stage 上半透明地畫出 [_LayoutSnapshot]：容器 4:3 邊框 + 每片 sprite +
/// tile 方框 + 中心圓。給 debug 觀察物理模擬用。
class _DebugLayoutPainter extends CustomPainter {
	_DebugLayoutPainter({required this.snapshot});
	final _LayoutSnapshot snapshot;

	@override
	void paint(Canvas canvas, Size size) {
		// 1. 容器邊框
		final Paint border = Paint()
			..style = PaintingStyle.stroke
			..strokeWidth = 2
			..color = const Color(0xFFFF0066);
		canvas.drawRect(snapshot.container, border);

		final double half = snapshot.tile / 2;

		// 2. sprite（半透明，讓底下還看得到 tile 框 / 中心）
		final Paint imgPaint = Paint()
			..filterQuality = FilterQuality.medium
			..colorFilter = ColorFilter.mode(
				const Color(0xFFFFFFFF).withValues(alpha: 0.7),
				BlendMode.modulate,
			);
		final int n = snapshot.items.length;
		for (int i = 0; i < n && i < snapshot.centers.length; i++) {
			final SpriteItem item = snapshot.items[i];
			final SpriteCategory cat = snapshot.category;
			final SpriteSheet sheet = cat.sheet;
			final ({int sheet, int row, int col})? g = cat.gridOf(item);
			if (g == null) continue;
			final ui.Image? img = snapshot.registry.atlas.cachedImage(sheet.file);
			if (img == null) continue;
			final double tilePx = sheet.tile.toDouble();
			final ui.Rect src = ui.Rect.fromLTWH(
				g.col * tilePx,
				g.row * tilePx,
				tilePx,
				tilePx,
			);
			final ui.Offset c = snapshot.centers[i];
			final ui.Rect dst = ui.Rect.fromLTWH(
				c.dx - half,
				c.dy - half,
				snapshot.tile,
				snapshot.tile,
			);
			canvas.drawImageRect(img, src, dst, imgPaint);
		}

		// 3. tile 方框 + 中心圓
		final Paint tileBox = Paint()
			..style = PaintingStyle.stroke
			..strokeWidth = 1.5
			..color = const Color(0xCC0066FF);
		final Paint dot = Paint()..color = const Color(0xFFFF3300);
		for (final ui.Offset c in snapshot.centers) {
			canvas.drawRect(
				ui.Rect.fromLTWH(c.dx - half, c.dy - half, snapshot.tile, snapshot.tile),
				tileBox,
			);
			canvas.drawCircle(c, 3, dot);
		}
	}

	@override
	bool shouldRepaint(covariant _DebugLayoutPainter oldDelegate) =>
			oldDelegate.snapshot != snapshot;
}
