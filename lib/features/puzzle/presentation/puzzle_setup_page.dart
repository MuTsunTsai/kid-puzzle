import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:provider/provider.dart";
import "package:showcaseview/showcaseview.dart";

import "../../../core/audio/audio_service.dart";
import "../../../core/constants/app_colors.dart";
import "../../../core/routing/app_router.dart";
import "../../../core/storage/settings_repository.dart";
import "../../../shared/widgets/click_sound.dart";
import "../../../shared/widgets/tutorial_bubble.dart";
import "../domain/services/cell_planner.dart";
import "../puzzle_dimens.dart";

/// 進入拼圖前的設定頁：選擇片數的下限與上限。
///
/// 進入遊戲後每關會從 [min, max] 範圍內隨機選一個片數。
///
/// 排版：
/// - 第一排：「最小數字 ── slider ── 最大數字」
/// - 第二排：「玩法選項 card + 切割模式 card + 開始按鈕」
class PuzzleSetupPage extends StatefulWidget {
	const PuzzleSetupPage({super.key});

	@override
	State<PuzzleSetupPage> createState() => _PuzzleSetupPageState();
}

class _PuzzleSetupPageState extends State<PuzzleSetupPage> {
	double _min = PuzzleDimens.defaultMinPieces.toDouble();
	double _max = PuzzleDimens.defaultMaxPieces.toDouble();
	bool _showHint = true;
	Set<CutMode> _cutModes = <CutMode>{CutMode.grid, CutMode.voronoi};
	bool _rotation = false;
	bool _screenLock = false;
	bool _loadedFromRepo = false;

	// 完整教學流程 key（首次進入或從家長區重設後，依序播放）
	final GlobalKey _tutorialRangeKey = GlobalKey();
	final GlobalKey _tutorialHintKey = GlobalKey();
	final GlobalKey _tutorialRotationKey = GlobalKey();
	final GlobalKey _tutorialScreenLockKey = GlobalKey();
	final GlobalKey _tutorialCutModeKey = GlobalKey();

	/// 開始按鈕點下、但切割模式空集合 → 觸發這個 showcase 提醒（與完整教學流程獨立）。
	final GlobalKey _cutModeRequiredKey = GlobalKey();

	late final ShowcaseView _showcase;

	/// setup 頁教學「當前版本」。更新教學內容時 bump 此值，舊使用者會重看一次。
	static const int _setupTutorialVersion = 1;

	@override
	void initState() {
		super.initState();
		_showcase = ShowcaseView.register(
			scope: "puzzleSetup",
			disableMovingAnimation: true,
		);
		WidgetsBinding.instance.addPostFrameCallback((_) => _maybeStartTutorial());
	}

	@override
	void dispose() {
		_showcase.unregister();
		super.dispose();
	}

	Future<void> _maybeStartTutorial() async {
		if (!mounted) return;
		final SettingsRepository repo = context.read<SettingsRepository>();
		final int seen = repo.tutorialVersionSeen("puzzleSetup");
		if (seen >= _setupTutorialVersion) return;
		final List<GlobalKey> sequence = <GlobalKey>[
			_tutorialRangeKey,
			_tutorialHintKey,
			_tutorialRotationKey,
			if (_showScreenLockOption) _tutorialScreenLockKey,
			_tutorialCutModeKey,
		];
		_showcase.startShowCase(sequence);
		repo.setTutorialVersionSeen("puzzleSetup", _setupTutorialVersion);
	}

	/// 只有 Android 才顯示「鎖定畫面」選項。
	bool get _showScreenLockOption =>
			!kIsWeb && defaultTargetPlatform == TargetPlatform.android;

	static const double _absoluteMin = 2;
	static const double _absoluteMax = 30;

	/// 把目前 UI 狀態寫回 [SettingsRepository]。任何欄位改動都會呼叫此方法、
	/// 確保使用者就算直接返回也不會丟失調整。Hive 的 put 是 async 但這裡不
	/// await，重排隊由 Hive 自行處理即可（後送的覆蓋先送的，最終值穩定）。
	void _persist() {
		context.read<SettingsRepository>().saveSetupConfig(
					minPieces: _min.round(),
					maxPieces: _max.round(),
					showHint: _showHint,
					cutModes: _cutModes,
					rotationEnabled: _rotation,
					screenLockEnabled: _screenLock,
				);
	}

	void _click() {
		try {
			context.read<AudioService>().play(SfxKind.click);
		} catch (_) {}
	}

	@override
	void didChangeDependencies() {
		super.didChangeDependencies();
		if (_loadedFromRepo) return;
		_loadedFromRepo = true;
		final SettingsRepository repo = context.read<SettingsRepository>();
		setState(() {
			_min = repo.minPieces
					.clamp(_absoluteMin.toInt(), _absoluteMax.toInt())
					.toDouble();
			_max = repo.maxPieces
					.clamp(_absoluteMin.toInt(), _absoluteMax.toInt())
					.toDouble();
			if (_min > _max) _max = _min;
			_showHint = repo.showHint;
			final Set<CutMode> loaded = repo.cutModes;
			if (loaded.isNotEmpty) _cutModes = loaded;
			_rotation = repo.rotationEnabled;
			_screenLock = repo.screenLockEnabled;
		});
	}

	@override
	Widget build(BuildContext context) {
		final int minInt = _min.round();
		final int maxInt = _max.round();
		// helper：把某個 child 用 Showcase.withWidget 包起來，tooltip 點氣泡推進。
		Widget tutorialWrap({
			required GlobalKey key,
			required String text,
			required Widget child,
			TooltipPosition position = TooltipPosition.bottom,
		}) {
			return Showcase.withWidget(
				key: key,
				container: TutorialBubble(text: text, onTap: _showcase.next),
				tooltipPosition: position,
				targetBorderRadius: const BorderRadius.all(Radius.circular(8)),
				child: child,
			);
		}
		return Scaffold(
			body: Container(
				decoration: const BoxDecoration(
					gradient: LinearGradient(
						begin: Alignment.topLeft,
						end: Alignment.bottomRight,
						colors: <Color>[AppColors.primary, AppColors.accent],
					),
				),
				child: SafeArea(
					child: Stack(
						children: <Widget>[
							const _CloseButton(),
							Center(
								child: ConstrainedBox(
									constraints: const BoxConstraints(maxWidth: 720),
									child: Padding(
										padding: const EdgeInsets.symmetric(horizontal: 32),
										child: Column(
											mainAxisSize: MainAxisSize.min,
											children: <Widget>[
												const Text(
													"選擇拼圖片數範圍",
													style: TextStyle(
														fontSize: 24,
														fontWeight: FontWeight.bold,
														color: Colors.white,
													),
												),
												const SizedBox(height: 20),
												tutorialWrap(
													key: _tutorialRangeKey,
													text: "在這邊可以選擇拼圖片數範圍，"
															"會隨機從範圍中選一個來進行切割～",
													child: _PieceRangeRow(
														min: _min,
														max: _max,
														absoluteMin: _absoluteMin,
														absoluteMax: _absoluteMax,
														onChanged: (RangeValues v) {
															setState(() {
																_min = v.start;
																_max = v.end;
															});
															_persist();
														},
													),
												),
												const SizedBox(height: 20),
												Row(
													crossAxisAlignment: CrossAxisAlignment.center,
													mainAxisAlignment: MainAxisAlignment.center,
													children: <Widget>[
														_OptionsCard(
															showHint: _showHint,
															rotation: _rotation,
															screenLock: _screenLock,
															showScreenLockOption: _showScreenLockOption,
															onShowHintChanged: (bool v) {
																_click();
																setState(() => _showHint = v);
																_persist();
															},
															onRotationChanged: (bool v) {
																_click();
																setState(() => _rotation = v);
																_persist();
															},
															onScreenLockChanged: (bool v) {
																_click();
																setState(() => _screenLock = v);
																_persist();
															},
															wrapShowHintRow: (Widget row) => tutorialWrap(
																key: _tutorialHintKey,
																text: "啟用這個會顯示切割提示線，"
																		"關掉的話會稍微增加難度喔！",
																child: row,
															),
															wrapRotationRow: (Widget row) => tutorialWrap(
																key: _tutorialRotationKey,
																text: "啟用這個會增加旋轉的維度，"
																		"會更加提昇難度喔！",
																child: row,
															),
															wrapScreenLockRow: (Widget row) => tutorialWrap(
																key: _tutorialScreenLockKey,
																text: "啟用這個會鎖定應用程式，"
																		"在部份手機上有助於避免幼兒誤觸系統返回～",
																child: row,
															),
														),
														const SizedBox(width: 16),
														// 兩層 Showcase 並存：外層教學流程（startShowCase 帶 [_tutorialCutModeKey]
														// 時觸發）、內層「至少選一種」提示（_cutModeRequiredKey）。兩個 key 永遠
														// 不會同時 active，套件靠 active key 找對應 widget，不會混淆。
														tutorialWrap(
															key: _tutorialCutModeKey,
															text: "這邊可以選擇不同的切割模式，"
																	"不規則型的形狀提示較明顯，"
																	"對許多幼兒來說反而比較容易喔～",
															position: TooltipPosition.top,
															child: Showcase.withWidget(
																key: _cutModeRequiredKey,
																container: TutorialBubble(
																	text: "這邊至少要選一種喔！",
																	onTap: _showcase.next,
																),
																tooltipPosition: TooltipPosition.top,
																targetBorderRadius:
																		const BorderRadius.all(Radius.circular(12)),
																child: _CutModeCard(
																	selected: _cutModes,
																	onChanged: (Set<CutMode> sel) {
																		_click();
																		setState(
																				() => _cutModes = Set<CutMode>.from(sel));
																		_persist();
																	},
																),
															),
														),
														const SizedBox(width: 16),
														_StartButton(
															onPressed: ClickSound.wrap(context, () {
																// 切割模式必選一種；沒選就以 showcase 提示而非導頁。
																if (_cutModes.isEmpty) {
																	_showcase.startShowCase(
																			<GlobalKey>[_cutModeRequiredKey]);
																	return;
																}
																// 設定變更已即時存（_persist），這裡只需導頁。
																Navigator.of(context).pushReplacementNamed(
																	AppRoutes.puzzle,
																	arguments: PuzzleArguments(
																		minPieces: minInt,
																		maxPieces: maxInt,
																		showHint: _showHint,
																		cutModes: _cutModes,
																		rotationEnabled: _rotation,
																		screenLockEnabled: _screenLock,
																	),
																);
															}),
														),
													],
												),
											],
										),
									),
								),
							),
						],
					),
				),
			),
		);
	}
}

/// 右上「返回首頁」X 按鈕。
class _CloseButton extends StatelessWidget {
	const _CloseButton();

	@override
	Widget build(BuildContext context) {
		return Positioned(
			top: 12,
			right: 12,
			child: IconButton.filled(
				onPressed: ClickSound.wrap(
					context,
					() => Navigator.of(context).maybePop(),
				),
				icon: const Icon(Icons.close),
				iconSize: 28,
				style: IconButton.styleFrom(
					backgroundColor: Colors.white.withValues(alpha: 0.9),
					foregroundColor: AppColors.primary,
				),
			),
		);
	}
}

/// 左數字 — 滑桿 — 右數字 的片數範圍選擇列。
class _PieceRangeRow extends StatelessWidget {
	const _PieceRangeRow({
		required this.min,
		required this.max,
		required this.absoluteMin,
		required this.absoluteMax,
		required this.onChanged,
	});

	final double min;
	final double max;
	final double absoluteMin;
	final double absoluteMax;
	final ValueChanged<RangeValues> onChanged;

	@override
	Widget build(BuildContext context) {
		final int minInt = min.round();
		final int maxInt = max.round();
		return Row(
			children: <Widget>[
				_PieceCountBadge(value: minInt),
				Expanded(
					child: SliderTheme(
						data: SliderThemeData(
							activeTrackColor: Colors.white,
							inactiveTrackColor: Colors.white.withValues(alpha: 0.3),
							thumbColor: Colors.white,
							overlayColor: Colors.white.withValues(alpha: 0.2),
							valueIndicatorColor: Colors.white,
							valueIndicatorTextStyle: const TextStyle(
								color: AppColors.primary,
								fontWeight: FontWeight.bold,
							),
						),
						child: RangeSlider(
							min: absoluteMin,
							max: absoluteMax,
							divisions: (absoluteMax - absoluteMin).toInt(),
							values: RangeValues(min, max),
							labels: RangeLabels("$minInt", "$maxInt"),
							onChanged: onChanged,
						),
					),
				),
				_PieceCountBadge(value: maxInt),
			],
		);
	}
}

/// 玩法選項白卡：提示線 / 旋轉 / （Android）鎖定畫面 上下並排。
///
/// 每個 row 可以接一個 builder（傳入該 row 的 widget、回傳已包好 Showcase 的 widget）。
/// 沒傳 builder 時用 row 原樣。這樣外層可以把對應 row 包進 [Showcase]、
/// 而 `_OptionsCard` 內部不需要認識 Showcase 細節。
class _OptionsCard extends StatelessWidget {
	const _OptionsCard({
		required this.showHint,
		required this.rotation,
		required this.screenLock,
		required this.showScreenLockOption,
		required this.onShowHintChanged,
		required this.onRotationChanged,
		required this.onScreenLockChanged,
		this.wrapShowHintRow,
		this.wrapRotationRow,
		this.wrapScreenLockRow,
	});

	final bool showHint;
	final bool rotation;
	final bool screenLock;
	final bool showScreenLockOption;
	final ValueChanged<bool> onShowHintChanged;
	final ValueChanged<bool> onRotationChanged;
	final ValueChanged<bool> onScreenLockChanged;

	/// 對「顯示提示線」row 額外包一層（一般用來放 [Showcase]）。
	final Widget Function(Widget)? wrapShowHintRow;
	final Widget Function(Widget)? wrapRotationRow;
	final Widget Function(Widget)? wrapScreenLockRow;

	@override
	Widget build(BuildContext context) {
		Widget wrap(Widget Function(Widget)? f, Widget child) =>
				f == null ? child : f(child);
		return Material(
			color: Colors.white,
			borderRadius: BorderRadius.circular(12),
			child: Padding(
				padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
				child: Column(
					mainAxisSize: MainAxisSize.min,
					crossAxisAlignment: CrossAxisAlignment.start,
					children: <Widget>[
						wrap(
							wrapShowHintRow,
							_OptionCheckRow(
								label: "顯示提示線",
								value: showHint,
								onChanged: onShowHintChanged,
							),
						),
						wrap(
							wrapRotationRow,
							_OptionCheckRow(
								label: "旋轉",
								value: rotation,
								onChanged: onRotationChanged,
							),
						),
						if (showScreenLockOption)
							wrap(
								wrapScreenLockRow,
								_OptionCheckRow(
									label: "鎖定畫面",
									value: screenLock,
									onChanged: onScreenLockChanged,
								),
							),
					],
				),
			),
		);
	}
}

/// 切割模式選擇白卡（方格 / 不規則，可複選）。
class _CutModeCard extends StatelessWidget {
	const _CutModeCard({required this.selected, required this.onChanged});

	final Set<CutMode> selected;
	final ValueChanged<Set<CutMode>> onChanged;

	@override
	Widget build(BuildContext context) {
		return Material(
			color: Colors.white,
			borderRadius: BorderRadius.circular(12),
			child: Padding(
				padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
				child: SegmentedButton<CutMode>(
					multiSelectionEnabled: true,
					emptySelectionAllowed: true,
					direction: Axis.vertical,
					style: ButtonStyle(
						shape: WidgetStateProperty.all(
							RoundedRectangleBorder(
								borderRadius: BorderRadius.circular(12),
							),
						),
					),
					segments: const <ButtonSegment<CutMode>>[
						ButtonSegment<CutMode>(
							value: CutMode.grid,
							label: Text("方格"),
							icon: Icon(Icons.grid_view),
						),
						ButtonSegment<CutMode>(
							value: CutMode.voronoi,
							label: Text("不規則"),
							icon: Icon(Icons.scatter_plot),
						),
					],
					selected: selected,
					onSelectionChanged: onChanged,
				),
			),
		);
	}
}

/// 大「開始」按鈕。
class _StartButton extends StatelessWidget {
	const _StartButton({required this.onPressed});

	final VoidCallback? onPressed;

	@override
	Widget build(BuildContext context) {
		return ElevatedButton(
			onPressed: onPressed,
			style: ElevatedButton.styleFrom(
				backgroundColor: Colors.white,
				foregroundColor: AppColors.primary,
				padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 14),
				shape: RoundedRectangleBorder(
					borderRadius: BorderRadius.circular(28),
				),
				elevation: 6,
			),
			child: const Text(
				"開始",
				style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
			),
		);
	}
}

class _PieceCountBadge extends StatelessWidget {
	const _PieceCountBadge({required this.value});

	final int value;

	@override
	Widget build(BuildContext context) {
		return SizedBox(
			width: 56,
			child: Text(
				"$value",
				textAlign: TextAlign.center,
				style: const TextStyle(
					fontSize: 32,
					fontWeight: FontWeight.bold,
					color: Colors.white,
				),
			),
		);
	}
}

/// 進入 [PuzzlePage] 時帶的參數。
class PuzzleArguments {
	const PuzzleArguments({
		required this.minPieces,
		required this.maxPieces,
		required this.showHint,
		required this.cutModes,
		required this.rotationEnabled,
		required this.screenLockEnabled,
	});

	final int minPieces;
	final int maxPieces;
	final bool showHint;

	/// 啟用的切割模式集合（非空）；每關隨機抽一個。
	final Set<CutMode> cutModes;

	/// 是否啟用旋轉模式：散落時隨機角度、第二指控制旋轉、融合需角度一致、
	/// 鎖定需角度為 0。
	final bool rotationEnabled;

	/// 是否在進入拼圖頁時啟用「鎖定畫面」（Android app pinning）。只有 Android
	/// 平台會生效；其他平台即使勾選也 no-op。
	final bool screenLockEnabled;
}

/// Setup card 內的 checkbox + 文字一行 UI，整行可點。
class _OptionCheckRow extends StatelessWidget {
	const _OptionCheckRow({
		required this.label,
		required this.value,
		required this.onChanged,
	});

	final String label;
	final bool value;
	final ValueChanged<bool> onChanged;

	@override
	Widget build(BuildContext context) {
		return InkWell(
			borderRadius: BorderRadius.circular(8),
			onTap: () => onChanged(!value),
			child: Padding(
				padding: const EdgeInsets.fromLTRB(0, 4, 8, 4),
				child: Row(
					mainAxisSize: MainAxisSize.min,
					children: <Widget>[
						Checkbox(
							value: value,
							onChanged: (bool? v) => onChanged(v ?? false),
						),
						const SizedBox(width: 4),
						Text(
							label,
							style: const TextStyle(
								fontSize: 18,
								fontWeight: FontWeight.w600,
								color: Colors.black87,
							),
						),
					],
				),
			),
		);
	}
}
