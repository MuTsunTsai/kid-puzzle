import "dart:async";

import "package:flutter/material.dart";
import "package:provider/provider.dart";
import "package:showcaseview/showcaseview.dart";

import "../../../core/analytics/analytics_service.dart";
import "../../../core/constants/app_colors.dart";
import "../../../core/constants/ui_strings.dart";
import "../../../core/routing/app_router.dart";
import "../../../core/storage/settings_repository.dart";
import "../../../shared/widgets/click_sound.dart";
import "../../../shared/widgets/font_ready_signal.dart";
import "../../../shared/widgets/tutorial_bubble.dart";
import "../../shared/screen_lock_option.dart";

/// 記憶遊戲設定頁：選每關配對組數範圍（2~10 組，即 4~20 張卡）。
class MemoryGameSetupPage extends StatefulWidget {
	const MemoryGameSetupPage({super.key});

	@override
	State<MemoryGameSetupPage> createState() => _MemoryGameSetupPageState();
}

class _MemoryGameSetupPageState extends State<MemoryGameSetupPage> {
	static const int _absoluteMin = 2;
	static const int _absoluteMax = 10;

	double _min = 3;
	double _max = 6;
	bool _screenLock = false;
	bool _loadedFromRepo = false;

	final GlobalKey _tutorialRangeKey = GlobalKey();
	final GlobalKey _tutorialScreenLockKey = GlobalKey();
	late final ShowcaseView _showcase;

	/// 設定頁教學「當前版本」。更新教學內容時 bump 此值，舊使用者會重看一次。
	static const int _setupTutorialVersion = 1;

	@override
	void initState() {
		super.initState();
		_showcase = ShowcaseView.register(
			scope: "memorySetup",
			disableMovingAnimation: true,
			onFinish: () => unawaited(
					AnalyticsService.instance.logTutorialComplete("memorySetup")),
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
		if (repo.tutorialVersionSeen("memorySetup") >= _setupTutorialVersion) {
			return;
		}
		await waitForFontsReady();
		if (!mounted) return;
		_showcase.startShowCase(<GlobalKey>[
			_tutorialRangeKey,
			if (showScreenLockOption) _tutorialScreenLockKey,
		]);
		unawaited(AnalyticsService.instance.logTutorialBegin("memorySetup"));
		unawaited(
				repo.setTutorialVersionSeen("memorySetup", _setupTutorialVersion));
	}

	/// 把 [child] 包進教學 Showcase，點氣泡推進下一步。
	Widget _tutorialWrap({
		required GlobalKey key,
		required String text,
		required Widget child,
	}) {
		return Showcase.withWidget(
			key: key,
			container: TutorialBubble(text: text, onTap: _showcase.next),
			targetBorderRadius: const BorderRadius.all(Radius.circular(8)),
			child: child,
		);
	}

	@override
	void didChangeDependencies() {
		super.didChangeDependencies();
		if (_loadedFromRepo) return;
		_loadedFromRepo = true;
		final SettingsRepository repo = context.read<SettingsRepository>();
		int lo = 3;
		int hi = 6;
		bool screenLock = false;
		try {
			lo = repo.memoryMinPairs;
			hi = repo.memoryMaxPairs;
			screenLock = repo.screenLockEnabled;
		} catch (_) {}
		if (lo < _absoluteMin) lo = _absoluteMin;
		if (hi > _absoluteMax) hi = _absoluteMax;
		if (lo > hi) lo = hi;
		_min = lo.toDouble();
		_max = hi.toDouble();
		_screenLock = screenLock;
	}

	void _persist() {
		context.read<SettingsRepository>().setMemoryPairRange(
					minPairs: _min.round(),
					maxPairs: _max.round(),
				);
	}

	void _persistScreenLock() {
		context.read<SettingsRepository>().setScreenLockEnabled(_screenLock);
	}

	@override
	Widget build(BuildContext context) {
		final int minInt = _min.round();
		final int maxInt = _max.round();
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
													MemoryStrings.rangeTitle,
													style: TextStyle(
														fontSize: 24,
														fontWeight: FontWeight.bold,
														color: Colors.white,
													),
												),
												const SizedBox(height: 20),
												_tutorialWrap(
													key: _tutorialRangeKey,
													text: MemoryStrings.rangeTutorial,
													child: Row(
														children: <Widget>[
															_CountBadge(value: minInt),
															Expanded(
																child: SliderTheme(
																	data: SliderThemeData(
																		activeTrackColor: Colors.white,
																		inactiveTrackColor:
																				Colors.white.withValues(alpha: 0.3),
																		thumbColor: Colors.white,
																		overlayColor:
																				Colors.white.withValues(alpha: 0.2),
																		valueIndicatorColor: Colors.white,
																		valueIndicatorTextStyle: const TextStyle(
																			color: AppColors.primary,
																			fontWeight: FontWeight.bold,
																		),
																	),
																	child: RangeSlider(
																		min: _absoluteMin.toDouble(),
																		max: _absoluteMax.toDouble(),
																		divisions: _absoluteMax - _absoluteMin,
																		values: RangeValues(_min, _max),
																		labels: RangeLabels("$minInt", "$maxInt"),
																		onChanged: (RangeValues v) {
																			setState(() {
																				_min = v.start;
																				_max = v.end;
																			});
																			_persist();
																		},
																	),
																),
															),
															_CountBadge(value: maxInt),
														],
													),
												),
												const SizedBox(height: 32),
												Row(
													mainAxisAlignment: MainAxisAlignment.center,
													children: <Widget>[
														if (showScreenLockOption) ...<Widget>[
															_tutorialWrap(
																key: _tutorialScreenLockKey,
																text: MemoryStrings.screenLockTutorial,
																child: Material(
																	color: Colors.white,
																	borderRadius: BorderRadius.circular(12),
																	child: Padding(
																		padding: const EdgeInsets.symmetric(
																			horizontal: 8,
																			vertical: 4,
																		),
																		child: OptionCheckRow(
																			label: MemoryStrings.screenLockLabel,
																			value: _screenLock,
																			onChanged: (bool v) {
																				setState(() => _screenLock = v);
																				_persistScreenLock();
																			},
																		),
																	),
																),
															),
															const SizedBox(width: 20),
														],
														ElevatedButton(
															onPressed: ClickSound.wrap(context, () {
																Navigator.of(context).pushReplacementNamed(
																	AppRoutes.memoryGame,
																	arguments: MemoryGameArguments(
																		minPairs: minInt,
																		maxPairs: maxInt,
																		screenLockEnabled: _screenLock,
																	),
																);
															}),
															style: ElevatedButton.styleFrom(
																backgroundColor: Colors.white,
																foregroundColor: AppColors.primary,
																padding: const EdgeInsets.symmetric(
																	horizontal: 40,
																	vertical: 14,
																),
																shape: RoundedRectangleBorder(
																	borderRadius: BorderRadius.circular(28),
																),
																elevation: 6,
															),
															child: const Text(
																MemoryStrings.startButton,
																style: TextStyle(
																	fontSize: 22,
																	fontWeight: FontWeight.bold,
																),
															),
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

/// 進入 [MemoryGamePage] 時帶的參數。
class MemoryGameArguments {
	const MemoryGameArguments({
		required this.minPairs,
		required this.maxPairs,
		required this.screenLockEnabled,
	});

	/// 每關配對組數範圍（一組 = 兩張卡）。
	final int minPairs;
	final int maxPairs;

	/// 進入關卡時是否啟動 app pinning（只在 Android 有效）。
	final bool screenLockEnabled;
}

class _CountBadge extends StatelessWidget {
	const _CountBadge({required this.value});

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
