import "dart:async";
import "dart:math";
import "dart:ui" as ui;

import "package:flutter/material.dart";
import "package:flutter_animate/flutter_animate.dart";
import "package:provider/provider.dart";
import "package:showcaseview/showcaseview.dart";

import "../../../core/audio/audio_service.dart";
import "../../../core/audio/voice_service.dart";
import "../../../core/constants/app_colors.dart";
import "../../../core/constants/ui_strings.dart";
import "../../../core/network/background_asset_cache.dart";
import "../../../core/sprites/sprite_manifest.dart";
import "../../../core/sprites/sprite_registry.dart";
import "../../../core/sprites/sprite_selection.dart";
import "../../../core/storage/settings_repository.dart";
import "../../../shared/widgets/centered_showcase_bubble.dart";
import "../../../shared/widgets/click_sound.dart";
import "../../../shared/widgets/font_ready_signal.dart";
import "../../../shared/widgets/loading_spinner_overlay.dart";
import "../../puzzle/presentation/widgets/level_complete_overlay.dart";
import "../../shared/board_close_button.dart";
import "../../shared/cache_aware_picker.dart";
import "../../shared/cooldown_picker.dart";
import "../../shared/macaron_color.dart";
import "../../shared/screen_lock_option.dart";
import "../domain/memory_board.dart";
import "../domain/memory_grid_layout.dart";
import "memory_game_setup_page.dart";
import "widgets/memory_card_view.dart";

/// 記憶遊戲主畫面。
///
/// 每關流程：
/// 1. 以冷卻抽樣（[CacheAwarePicker] + [CooldownPicker]）從啟用的素材類別抽
///    一個類別，再從該類別可用物件中抽 N 個（類別內同樣有冷卻）
/// 2. 每個物件兩張卡、洗牌後背面朝上排成網格
/// 3. 一次翻兩張：
///    - 相同 → 唸物件名稱（沒語音則 snap 音效）、短暫停留後播消失特效
///    - 不同 → 停頓 [_mismatchHold] 後自動翻回；期間盤面鎖定
/// 4. 全部消掉 → 等最後一句語音念完 → 過關畫面 → 點擊進下一關
class MemoryGamePage extends StatefulWidget {
	const MemoryGamePage({super.key});

	@override
	State<MemoryGamePage> createState() => _MemoryGamePageState();
}

class _MemoryGamePageState extends State<MemoryGamePage> {
	/// 不符合的兩張翻開後、停留多久才翻回（從翻牌動畫結束起算）。
	static const Duration _mismatchHold = Duration(milliseconds: 1000);

	/// 配對成功後、兩張保持正面多久才開始消失特效（從翻牌動畫結束起算）。
	static const Duration _matchHold = Duration(milliseconds: 350);

	/// 網格左右各保留的寬度：右上關閉按鈕（56 + 12 邊距）不擋到卡片，
	/// 左側對稱保留、讓盤面視覺置中。
	static const double _sideGutter = 84;
	static const double _verticalGutter = 20;

	final Random _random = Random();

	int _minPairs = 3;
	int _maxPairs = 6;
	bool _screenLockEnabled = false;
	bool _initialized = false;

	/// 類別冷卻抽樣器：key = 類別 id。
	late final CooldownPicker<String> _categoryPicker =
			CooldownPicker<String>(random: _random);

	/// 每個類別獨立的 item 冷卻抽樣器（key = item.id）。
	final Map<String, CooldownPicker<String>> _itemPickers =
			<String, CooldownPicker<String>>{};

	/// 是否還沒抽過任何關卡（用來決定「第一關只選已 cache 類別」）。
	bool _firstLevel = true;

	_MemoryLevel? _level;
	bool _completed = false;

	/// 切下一關期間：spinner overlay + 任何 _goNextLevel 重入皆 no-op。
	bool _loadingNext = false;

	/// 遊戲頁教學（畫面中央純氣泡）。第一次進來、第一關發完牌後顯示一次。
	final GlobalKey _tutorialKey = GlobalKey();
	late final ShowcaseView _showcase;

	/// 遊戲頁教學「當前版本」。更新教學內容時 bump 此值，舊使用者會重看一次。
	static const int _tutorialVersion = 1;

	/// 教學氣泡顯示期間卡片不接受輸入：卡片用 Listener 接 pointer-down、
	/// 會先把事件吃掉（翻牌），Showcase backdrop 的 tap 就等不到完整 click。
	bool _tutorialActive = false;

	@override
	void initState() {
		super.initState();
		_showcase = ShowcaseView.register(
			scope: "memory",
			disableMovingAnimation: true,
		);
	}

	@override
	void didChangeDependencies() {
		super.didChangeDependencies();
		if (_initialized) return;
		_initialized = true;
		final Object? args = ModalRoute.of(context)?.settings.arguments;
		if (args is MemoryGameArguments) {
			_minPairs = args.minPairs;
			_maxPairs = args.maxPairs;
			_screenLockEnabled = args.screenLockEnabled;
		}
		WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
	}

	@override
	void dispose() {
		_showcase.unregister();
		// 解除 app pinning；非 Android / 未啟用都 no-op。
		disableScreenLockGuard();
		super.dispose();
	}

	Future<void> _bootstrap() async {
		await maybeEnableScreenLock(_screenLockEnabled);
		if (!mounted) return;
		final SpriteRegistry registry = context.read<SpriteRegistry>();
		if (!registry.isLoaded) {
			await registry.load();
			if (!mounted) return;
		}
		if (_usableCategories(registry).isEmpty) {
			await _showNoCategoryThenExit();
			return;
		}
		await _loadNewLevel();
		if (!mounted) return;
		await _maybeStartTutorial();
	}

	Future<void> _maybeStartTutorial() async {
		final SettingsRepository repo = context.read<SettingsRepository>();
		if (repo.tutorialVersionSeen("memory") >= _tutorialVersion) return;
		final _MemoryLevel? level = _level;
		if (level == null) return;
		// 等發牌進場動畫跑完再跳氣泡，讓玩家先看到盤面。
		await Future.wait(<Future<void>>[
			waitForFontsReady(),
			Future<void>.delayed(
				Duration(milliseconds: 400 + level.board.cards.length * 45),
			),
		]);
		if (!mounted) return;
		setState(() => _tutorialActive = true);
		_showcase.startShowCase(<GlobalKey>[_tutorialKey]);
		unawaited(repo.setTutorialVersionSeen("memory", _tutorialVersion));
	}

	/// 教學氣泡被點掉：推進 / 結束流程後解除卡片的 IgnorePointer。
	void _dismissTutorial() {
		_showcase.next();
		if (!mounted) return;
		setState(() => _tutorialActive = false);
	}

	/// 算出當下可用的 (category, itemIds) 清單（規則同嵌入拼圖、見 [SpriteSelection]）。
	List<({SpriteCategory category, Set<String> itemIds})> _usableCategories(
			SpriteRegistry registry) {
		final SettingsRepository repo = context.read<SettingsRepository>();
		final Set<String> resolved = SpriteSelection.resolveSelected(
			stored: repo.spriteSelections,
			categories: registry.categories,
		);
		return <({SpriteCategory category, Set<String> itemIds})>[
			for (final SpriteCategory c in registry.categories)
				if (SpriteSelection.usableItemIds(c, resolved).isNotEmpty)
					(category: c, itemIds: SpriteSelection.usableItemIds(c, resolved)),
		];
	}

	Future<void> _loadNewLevel() async {
		final SpriteRegistry registry = context.read<SpriteRegistry>();
		final VoiceService voice = context.read<VoiceService>();
		final BackgroundAssetCache cache = context.read<BackgroundAssetCache>();
		final List<({SpriteCategory category, Set<String> itemIds})> usable =
				_usableCategories(registry);
		if (usable.isEmpty) {
			await _showNoCategoryThenExit();
			return;
		}
		final bool isFirst = _firstLevel;
		_firstLevel = false;
		final String? catId = CacheAwarePicker.pick<String>(
			picker: _categoryPicker,
			candidates: usable.map(
					(({SpriteCategory category, Set<String> itemIds}) e) => e.category.id),
			isCached: cache.isSpriteCategoryCached,
			firstLevel: isFirst,
		);
		final ({SpriteCategory category, Set<String> itemIds}) selected =
				catId != null
						? usable.firstWhere(
								(({SpriteCategory category, Set<String> itemIds}) e) =>
										e.category.id == catId)
						: usable[_random.nextInt(usable.length)];
		final SpriteCategory category = selected.category;

		final int pairCount = _minPairs >= _maxPairs
				? _minPairs
				: _minPairs + _random.nextInt(_maxPairs - _minPairs + 1);
		final CooldownPicker<String> itemPicker = _itemPickers.putIfAbsent(
			category.id,
			() => CooldownPicker<String>(random: _random),
		);
		final List<String> pickedIds = itemPicker.pickMany(
			category.items
					.where((SpriteItem it) => selected.itemIds.contains(it.id))
					.map((SpriteItem it) => it.id),
			pairCount,
		);
		final Map<String, SpriteItem> byId = <String, SpriteItem>{
			for (final SpriteItem it in category.items)
				if (pickedIds.contains(it.id)) it.id: it,
		};
		if (byId.isEmpty) {
			await _showNoCategoryThenExit();
			return;
		}

		// 預載 sheet 圖 + 語音 zip。
		await registry.preloadCategory(category);
		if (!mounted) return;
		final ui.Image? image = registry.atlas.cachedImage(category.sheet.file);
		if (image == null) {
			await _showNoCategoryThenExit();
			return;
		}

		final _MemoryLevel level = _MemoryLevel(
			id: (_level?.id ?? 0) + 1,
			category: category,
			itemsById: byId,
			srcRects: <String, Rect>{
				for (final SpriteItem it in byId.values) it.id: registry.srcRectOf(it),
			},
			image: image,
			backColor: macaronColor(_random),
			board: MemoryBoard<String>.shuffled(byId.keys.toList(), _random),
		);
		setState(() {
			_level = level;
			_completed = false;
		});
		voice.speakLevelStart();
	}

	/// 點下 overlay → 進下一關。重入鎖避免幼兒連點 / 多指亂按。
	Future<void> _goNextLevel() async {
		if (_loadingNext) return;
		setState(() => _loadingNext = true);
		try {
			await _loadNewLevel();
		} finally {
			if (mounted) setState(() => _loadingNext = false);
		}
	}

	void _onCardTap(_MemoryLevel level, int index) {
		if (_completed || _loadingNext) return;
		final AudioService audio = context.read<AudioService>();
		final FlipResult result = level.board.flip(index);
		switch (result) {
			case FlipIgnored():
				return;
			case FlipFirst():
				audio.play(SfxKind.click);
				setState(() {});
			case FlipMatch(:final int first, :final int second):
				audio.play(SfxKind.click);
				setState(() {});
				unawaited(_handleMatch(level, first, second));
			case FlipMismatch():
				audio.play(SfxKind.click);
				setState(() {});
				unawaited(_handleMismatch(level));
		}
	}

	Future<void> _handleMatch(_MemoryLevel level, int a, int b) async {
		// 等翻牌動畫轉到正面再唸名稱，聲音與畫面同步。
		await Future<void>.delayed(MemoryCardView.flipDuration);
		if (!mounted || _level != level) return;
		final SpriteRegistry registry = context.read<SpriteRegistry>();
		final AudioService audio = context.read<AudioService>();
		final SpriteItem? item = level.itemsById[level.board.cards[a].pairKey];
		// 有語音且「語音」開關開著 → 唸名稱；否則 fallback snap 音效（同嵌入拼圖）。
		if (item != null && registry.voiceEnabled && registry.hasNameVoice(item)) {
			level.lastVoice = registry.playName(item);
		} else {
			audio.play(SfxKind.snap);
			level.lastVoice = null;
		}
		await Future<void>.delayed(_matchHold);
		if (!mounted || _level != level) return;
		setState(() {
			level.removing.add(a);
			level.removing.add(b);
		});
	}

	Future<void> _handleMismatch(_MemoryLevel level) async {
		await Future<void>.delayed(MemoryCardView.flipDuration + _mismatchHold);
		if (!mounted || _level != level) return;
		setState(level.board.hideMismatch);
	}

	void _onCardRemoved(_MemoryLevel level) {
		level.removedCount++;
		if (level.removedCount < level.board.cards.length) return;
		if (!level.board.isCompleted) return;
		unawaited(_completeLevel(level));
	}

	Future<void> _completeLevel(_MemoryLevel level) async {
		// 最後一組可能還在唸名稱 → 念完再放過關音效與鼓勵語。
		final Future<void>? voiceFut = level.lastVoice;
		if (voiceFut != null) await voiceFut;
		if (!mounted || _level != level) return;
		context.read<AudioService>().play(SfxKind.complete);
		context.read<VoiceService>().speakLevelComplete();
		setState(() => _completed = true);
	}

	Future<void> _showNoCategoryThenExit() async {
		await showDialog<void>(
			context: context,
			barrierDismissible: false,
			builder: (BuildContext ctx) => AlertDialog(
				title: const Text(MemoryStrings.noCategoryTitle),
				content: const Text(MemoryStrings.noCategoryDesc),
				actions: <Widget>[
					ElevatedButton(
						onPressed: ClickSound.wrap(ctx, () => Navigator.of(ctx).pop()),
						child: const Text(MemoryStrings.ok),
					),
				],
			),
		);
		if (!mounted) return;
		unawaited(Navigator.of(context).maybePop());
	}

	@override
	Widget build(BuildContext context) {
		final _MemoryLevel? level = _level;
		final EdgeInsets safe = MediaQuery.paddingOf(context);
		return Scaffold(
			backgroundColor: AppColors.boardBackground,
			body: LayoutBuilder(
				builder: (BuildContext context, BoxConstraints constraints) {
					final Size size = Size(constraints.maxWidth, constraints.maxHeight);
					return Stack(
						children: <Widget>[
							if (level != null)
								Positioned.fill(
									child: IgnorePointer(
										ignoring: _tutorialActive,
										child: Stack(
											children: _buildCards(level, size, safe),
										),
									),
								)
							else
								const Center(child: CircularProgressIndicator()),
							if (_completed)
								LevelCompleteOverlay(
									region: Offset.zero & size,
									onContinue: _goNextLevel,
								),
							if (_loadingNext) const LoadingSpinnerOverlay(),
							// 首次進記憶遊戲的教學氣泡（畫面中央，無 highlight）。
							CenteredShowcaseBubble(
								showcaseKey: _tutorialKey,
								message: MemoryStrings.gameTutorial,
								onTap: _dismissTutorial,
							),
							Positioned(
								top: 12,
								right: 12,
								child: BoardCloseButton(
									repaint: null,
									bigKidMode: context.read<SettingsRepository>().bigKidMode,
									shouldHide: () => false,
									onClose: () => Navigator.of(context).maybePop(),
								),
							),
						],
					);
				},
			),
		);
	}

	List<Widget> _buildCards(_MemoryLevel level, Size size, EdgeInsets safe) {
		final Rect area = Rect.fromLTRB(
			safe.left + _sideGutter,
			safe.top + _verticalGutter,
			size.width - safe.right - _sideGutter,
			size.height - safe.bottom - _verticalGutter,
		);
		final MemoryGridLayout layout = MemoryGridLayout.compute(
			area: area,
			count: level.board.cards.length,
			maxCardSize: area.shortestSide * 0.48,
		);
		return <Widget>[
			for (final MemoryCard<String> card in level.board.cards)
				Positioned.fromRect(
					key: ValueKey<String>("memory-${level.id}-${card.index}"),
					rect: layout.rects[card.index],
					child: MemoryCardView(
						faceUp: card.state != MemoryCardState.faceDown,
						removing: level.removing.contains(card.index),
						image: level.image,
						srcRect: level.srcRects[card.pairKey]!,
						backColor: level.backColor,
						onTap: () => _onCardTap(level, card.index),
						onRemoved: () => _onCardRemoved(level),
					)
							// 發牌進場：依序彈出
							.animate(delay: (card.index * 45).ms)
							.fadeIn(duration: 200.ms)
							.scale(
								duration: 380.ms,
								curve: Curves.easeOutBack,
								begin: const Offset(0.3, 0.3),
								end: const Offset(1, 1),
							),
				),
		];
	}
}

/// 單一關卡的資料與進行中狀態。以 identity 比對判斷 async callback 是否已過期
/// （玩家進到下一關後，上一關殘留的 Future 不再動畫面）。
class _MemoryLevel {
	_MemoryLevel({
		required this.id,
		required this.category,
		required this.itemsById,
		required this.srcRects,
		required this.image,
		required this.backColor,
		required this.board,
	});

	final int id;
	final SpriteCategory category;
	final Map<String, SpriteItem> itemsById;
	final Map<String, Rect> srcRects;
	final ui.Image image;
	final Color backColor;
	final MemoryBoard<String> board;

	/// 正在播（或已播完）消失特效的卡片 index。
	final Set<int> removing = <int>{};

	/// 消失特效已播完的張數。
	int removedCount = 0;

	/// 最近一次配對成功的名稱語音；過關前要等它念完。
	Future<void>? lastVoice;
}
