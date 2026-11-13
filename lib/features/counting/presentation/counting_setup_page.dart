import "dart:async";
import "dart:math";

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
import "../domain/counting_species.dart";
import "counting_page.dart";
import "counting_voice_loader.dart";

/// 練習數數設定頁：要數的動物 / 其他動物的隻數範圍、已數過提示、鎖定畫面。
class CountingSetupPage extends StatefulWidget {
	const CountingSetupPage({super.key});

	@override
	State<CountingSetupPage> createState() => _CountingSetupPageState();
}

class _CountingSetupPageState extends State<CountingSetupPage> {
	static const int _targetMin = 1;
	static const int _targetMax = 20;
	static const int _othersMin = 0;
	static const int _othersMax = 10;

	RangeValues _target = const RangeValues(1, 7);
	RangeValues _others = const RangeValues(0, 3);
	bool _glow = true;
	bool _screenLock = false;
	bool _loadedFromRepo = false;

	/// 第一關的題目動物：設定頁一打開就先抽好，趁家長調設定時預載它的開場白
	/// 與數字語音包，進遊戲時第一句就能馬上唸。
	final CountingSpecies _firstTarget = kCountingSpecies[Random().nextInt(kCountingSpecies.length)];

	final GlobalKey _tutorialTargetKey = GlobalKey();
	final GlobalKey _tutorialOthersKey = GlobalKey();
	final GlobalKey _tutorialGlowKey = GlobalKey();
	final GlobalKey _tutorialScreenLockKey = GlobalKey();
	late final ShowcaseView _showcase;

	/// 設定頁教學「當前版本」。更新教學內容時 bump 此值，舊使用者會重看一次。
	static const int _tutorialVersion = 1;
	static const String _tutorialScreen = "countingSetup";

	@override
	void initState() {
		super.initState();
		_showcase = ShowcaseView.register(
			scope: _tutorialScreen,
			disableMovingAnimation: true,
			onFinish: () => unawaited(AnalyticsService.instance.logTutorialComplete(_tutorialScreen)),
		);
		WidgetsBinding.instance.addPostFrameCallback((_) {
			if (!mounted) return;
			CountingVoiceLoader.of(context)
				..prefetch(<String>[howManyVoice(_firstTarget)], urgent: true)
				..loadNumbers();
			_maybeStartTutorial();
		});
	}

	@override
	void dispose() {
		_showcase.unregister();
		super.dispose();
	}

	Future<void> _maybeStartTutorial() async {
		if (!mounted) return;
		final SettingsRepository repo = context.read<SettingsRepository>();
		if (repo.tutorialVersionSeen(_tutorialScreen) >= _tutorialVersion) return;
		await waitForFontsReady();
		if (!mounted) return;
		_showcase.startShowCase(<GlobalKey>[
			_tutorialTargetKey,
			_tutorialOthersKey,
			_tutorialGlowKey,
			if (showScreenLockOption) _tutorialScreenLockKey,
		]);
		unawaited(AnalyticsService.instance.logTutorialBegin(_tutorialScreen));
		unawaited(repo.setTutorialVersionSeen(_tutorialScreen, _tutorialVersion));
	}

	/// 把 [child] 包進教學 Showcase，點氣泡推進下一步。
	Widget _tutorialWrap({required GlobalKey key, required String text, required Widget child}) {
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
		try {
			_target = _clampRange(repo.countingTargetMin, repo.countingTargetMax, _targetMin, _targetMax);
			_others = _clampRange(repo.countingOthersMin, repo.countingOthersMax, _othersMin, _othersMax);
			_glow = repo.countingGlow;
			_screenLock = repo.screenLockEnabled;
		} catch (_) {}
	}

	static RangeValues _clampRange(int lo, int hi, int min, int max) {
		final int h = hi.clamp(min, max);
		final int l = lo.clamp(min, h);
		return RangeValues(l.toDouble(), h.toDouble());
	}

	void _persistRanges() {
		context.read<SettingsRepository>().setCountingRanges(
					targetMin: _target.start.round(),
					targetMax: _target.end.round(),
					othersMin: _others.start.round(),
					othersMax: _others.end.round(),
				);
	}

	void _start() {
		final SettingsRepository repo = context.read<SettingsRepository>();
		Navigator.of(context).pushReplacementNamed(
			AppRoutes.counting,
			arguments: CountingArguments(
				targetMin: _target.start.round(),
				targetMax: _target.end.round(),
				othersMin: _others.start.round(),
				othersMax: _others.end.round(),
				answerMode: repo.countingAnswerMode,
				glow: _glow,
				screenLockEnabled: _screenLock,
				firstTarget: _firstTarget,
			),
		);
	}

	@override
	Widget build(BuildContext context) {
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
							Positioned(
								top: 12,
								right: 12,
								child: IconButton.filled(
									onPressed: ClickSound.wrap(context, () => Navigator.of(context).maybePop()),
									icon: const Icon(Icons.close),
									iconSize: 28,
									style: IconButton.styleFrom(
										backgroundColor: Colors.white.withValues(alpha: 0.9),
										foregroundColor: AppColors.primary,
									),
								),
							),
							Center(
								child: SingleChildScrollView(
									padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
									child: ConstrainedBox(
										constraints: const BoxConstraints(maxWidth: 720),
										child: Column(
											mainAxisSize: MainAxisSize.min,
											children: <Widget>[
												_tutorialWrap(
													key: _tutorialTargetKey,
													text: CountingStrings.targetRangeTutorial,
													child: _RangeRow(
														title: CountingStrings.targetRangeTitle,
														min: _targetMin,
														max: _targetMax,
														values: _target,
														onChanged: (RangeValues v) {
															setState(() => _target = v);
															_persistRanges();
														},
													),
												),
												const SizedBox(height: 16),
												_tutorialWrap(
													key: _tutorialOthersKey,
													text: CountingStrings.othersRangeTutorial,
													child: _RangeRow(
														title: CountingStrings.othersRangeTitle,
														min: _othersMin,
														max: _othersMax,
														values: _others,
														onChanged: (RangeValues v) {
															setState(() => _others = v);
															_persistRanges();
														},
													),
												),
												const SizedBox(height: 24),
												Wrap(
													alignment: WrapAlignment.center,
													crossAxisAlignment: WrapCrossAlignment.center,
													spacing: 20,
													runSpacing: 12,
													children: <Widget>[
														Material(
															color: Colors.white,
															borderRadius: BorderRadius.circular(12),
															child: Padding(
																padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
																child: Column(
																	mainAxisSize: MainAxisSize.min,
																	crossAxisAlignment: CrossAxisAlignment.start,
																	children: <Widget>[
																		_tutorialWrap(
																			key: _tutorialGlowKey,
																			text: CountingStrings.glowTutorial,
																			child: OptionCheckRow(
																				label: CountingStrings.glowLabel,
																				value: _glow,
																				onChanged: (bool v) {
																					setState(() => _glow = v);
																					context.read<SettingsRepository>().setCountingGlow(v);
																				},
																			),
																		),
																		if (showScreenLockOption)
																			_tutorialWrap(
																				key: _tutorialScreenLockKey,
																				text: CountingStrings.screenLockTutorial,
																				child: OptionCheckRow(
																					label: CountingStrings.screenLockLabel,
																					value: _screenLock,
																					onChanged: (bool v) {
																						setState(() => _screenLock = v);
																						context.read<SettingsRepository>().setScreenLockEnabled(v);
																					},
																				),
																			),
																	],
																),
															),
														),
														ElevatedButton(
															onPressed: ClickSound.wrap(context, _start),
															style: ElevatedButton.styleFrom(
																backgroundColor: Colors.white,
																foregroundColor: AppColors.primary,
																padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 14),
																shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
																elevation: 6,
															),
															child: const Text(
																CountingStrings.startButton,
																style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
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

/// 標題 + 左右數字 + 範圍 slider。
class _RangeRow extends StatelessWidget {
	const _RangeRow({
		required this.title,
		required this.min,
		required this.max,
		required this.values,
		required this.onChanged,
	});

	final String title;
	final int min;
	final int max;
	final RangeValues values;
	final ValueChanged<RangeValues> onChanged;

	@override
	Widget build(BuildContext context) {
		final int lo = values.start.round();
		final int hi = values.end.round();
		return Column(
			mainAxisSize: MainAxisSize.min,
			children: <Widget>[
				Text(title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white)),
				const SizedBox(height: 8),
				Row(
					children: <Widget>[
						_CountBadge(value: lo),
						Expanded(
							child: SliderTheme(
								data: SliderThemeData(
									activeTrackColor: Colors.white,
									inactiveTrackColor: Colors.white.withValues(alpha: 0.3),
									thumbColor: Colors.white,
									overlayColor: Colors.white.withValues(alpha: 0.2),
									valueIndicatorColor: Colors.white,
									valueIndicatorTextStyle: const TextStyle(color: AppColors.primary, fontWeight: FontWeight.bold),
								),
								child: RangeSlider(
									min: min.toDouble(),
									max: max.toDouble(),
									divisions: max - min,
									values: values,
									labels: RangeLabels("$lo", "$hi"),
									onChanged: onChanged,
								),
							),
						),
						_CountBadge(value: hi),
					],
				),
			],
		);
	}
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
				style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.white),
			),
		);
	}
}
