import "package:flutter/material.dart";
import "package:provider/provider.dart";

import "../../../core/constants/app_colors.dart";
import "../../../core/routing/app_router.dart";
import "../../../core/storage/settings_repository.dart";
import "../../../shared/widgets/click_sound.dart";
import "../../shared/screen_lock_option.dart";

/// 嵌入拼圖設定頁：只選每關物件數（2~12）。
class InsetPuzzleSetupPage extends StatefulWidget {
	const InsetPuzzleSetupPage({super.key});

	@override
	State<InsetPuzzleSetupPage> createState() => _InsetPuzzleSetupPageState();
}

class _InsetPuzzleSetupPageState extends State<InsetPuzzleSetupPage> {
	static const int _absoluteMin = 2;
	static const int _absoluteMax = 12;

	double _min = 4;
	double _max = 8;
	bool _allowSimilar = false;
	bool _screenLock = false;
	bool _loadedFromRepo = false;

	@override
	void didChangeDependencies() {
		super.didChangeDependencies();
		if (_loadedFromRepo) return;
		_loadedFromRepo = true;
		final SettingsRepository repo = context.read<SettingsRepository>();
		int lo = 4;
		int hi = 8;
		bool allowSimilar = false;
		bool screenLock = false;
		try {
			lo = repo.insetMinPieces;
			hi = repo.insetMaxPieces;
			allowSimilar = repo.insetAllowSimilarSilhouette;
			screenLock = repo.screenLockEnabled;
		} catch (_) {}
		if (lo < _absoluteMin) lo = _absoluteMin;
		if (hi > _absoluteMax) hi = _absoluteMax;
		if (lo > hi) lo = hi;
		final double loD = lo.toDouble();
		final double hiD = hi.toDouble();
		setState(() {
			_min = loD;
			_max = hiD;
			_allowSimilar = allowSimilar;
			_screenLock = screenLock;
		});
	}

	void _persist() {
		context.read<SettingsRepository>().setInsetPieceRange(
					minPieces: _min.round(),
					maxPieces: _max.round(),
				);
	}

	void _persistAllowSimilar() {
		context
				.read<SettingsRepository>()
				.setInsetAllowSimilarSilhouette(_allowSimilar);
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
							_CloseButton(),
							Center(
								child: ConstrainedBox(
									constraints: const BoxConstraints(maxWidth: 720),
									child: Padding(
										padding: const EdgeInsets.symmetric(horizontal: 32),
										child: Column(
											mainAxisSize: MainAxisSize.min,
											children: <Widget>[
												const Text(
													"選擇片數範圍",
													style: TextStyle(
														fontSize: 24,
														fontWeight: FontWeight.bold,
														color: Colors.white,
													),
												),
												const SizedBox(height: 20),
												Row(
													children: <Widget>[
														_PieceCountBadge(value: minInt),
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
														_PieceCountBadge(value: maxInt),
													],
												),
												const SizedBox(height: 32),
												Row(
													mainAxisAlignment: MainAxisAlignment.center,
													crossAxisAlignment: CrossAxisAlignment.center,
													children: <Widget>[
														Material(
															color: Colors.white,
															borderRadius: BorderRadius.circular(12),
															child: Padding(
																padding: const EdgeInsets.symmetric(
																	horizontal: 8, vertical: 4),
																child: Column(
																	mainAxisSize: MainAxisSize.min,
																	crossAxisAlignment: CrossAxisAlignment.start,
																	children: <Widget>[
																		OptionCheckRow(
																			label: "允許剪影相似",
																			value: _allowSimilar,
																			onChanged: (bool v) {
																				setState(() => _allowSimilar = v);
																				_persistAllowSimilar();
																			},
																		),
																		if (showScreenLockOption)
																			OptionCheckRow(
																				label: "鎖定畫面",
																				value: _screenLock,
																				onChanged: (bool v) {
																					setState(() => _screenLock = v);
																					_persistScreenLock();
																				},
																			),
																	],
																),
															),
														),
														const SizedBox(width: 20),
														ElevatedButton(
															onPressed: ClickSound.wrap(context, () {
																Navigator.of(context).pushReplacementNamed(
																	AppRoutes.insetPuzzle,
																	arguments: InsetPuzzleArguments(
																		minPieces: minInt,
																		maxPieces: maxInt,
																		allowSimilarSilhouette: _allowSimilar,
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
																"開始",
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

/// 進入 [InsetPuzzlePage] 時帶的參數。
class InsetPuzzleArguments {
	const InsetPuzzleArguments({
		required this.minPieces,
		required this.maxPieces,
		required this.allowSimilarSilhouette,
		required this.screenLockEnabled,
	});
	final int minPieces;
	final int maxPieces;

	/// 是否允許剪影相似的物件同關出現。
	/// false（預設）→ 抽 item 時門檻 0.85、嚴格排除相似剪影；
	/// true → 門檻放寬到 0.95、只擋幾乎完全相同的剪影。
	final bool allowSimilarSilhouette;

	/// 進入關卡時是否啟動 app pinning（只在 Android 有效）。
	final bool screenLockEnabled;
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
