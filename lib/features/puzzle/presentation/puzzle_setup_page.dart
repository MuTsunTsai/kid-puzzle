import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:provider/provider.dart";

import "../../../core/audio/audio_service.dart";
import "../../../core/constants/app_colors.dart";
import "../../../core/routing/app_router.dart";
import "../../../core/storage/settings_repository.dart";
import "../../../shared/widgets/click_sound.dart";
import "../domain/services/cell_planner.dart";
import "../puzzle_dimens.dart";

/// 進入拼圖前的設定頁：選擇塊數的下限與上限。
///
/// 進入遊戲後每關會從 [min, max] 範圍內隨機選一個塊數。
///
/// 排版：
/// - 第一排：「最小數字 ── slider ── 最大數字」
/// - 第二排：「顯示提示線 + 切割模式 + 開始按鈕」
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
		return Scaffold(
			body: Container(
				decoration: const BoxDecoration(
					gradient: LinearGradient(
						begin: Alignment.topLeft,
						end: Alignment.bottomRight,
						colors: <Color>[
							AppColors.primary,
							AppColors.accent,
						],
					),
				),
				child: SafeArea(
					child: Stack(
						children: <Widget>[
							// 右上：返回首頁
							Positioned(
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
							),
							Center(
								child: ConstrainedBox(
									constraints: const BoxConstraints(maxWidth: 720),
									child: Padding(
										padding: const EdgeInsets.symmetric(horizontal: 32),
										child: Column(
											mainAxisSize: MainAxisSize.min,
											children: <Widget>[
												const Text(
													"選擇拼圖塊數範圍",
													style: TextStyle(
														fontSize: 24,
														fontWeight: FontWeight.bold,
														color: Colors.white,
													),
												),
												const SizedBox(height: 20),

												// 第一排：左數字 — slider — 右數字
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
																	min: _absoluteMin,
																	max: _absoluteMax,
																	divisions:
																			(_absoluteMax - _absoluteMin).toInt(),
																	values: RangeValues(_min, _max),
																	labels:
																			RangeLabels("$minInt", "$maxInt"),
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

												const SizedBox(height: 20),

												// 第二排：兩張 card（玩法選項 + 切割模式）+ 開始按鈕
												Row(
													crossAxisAlignment: CrossAxisAlignment.center,
													mainAxisAlignment: MainAxisAlignment.center,
													children: <Widget>[
														// 玩法選項 card：提示線 + 旋轉（上下並排）
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
																		_OptionCheckRow(
																			label: "顯示提示線",
																			value: _showHint,
																			onChanged: (bool v) {
																				_click();
																				setState(() => _showHint = v);
																				_persist();
																			},
																		),
																		_OptionCheckRow(
																			label: "旋轉",
																			value: _rotation,
																			onChanged: (bool v) {
																				_click();
																				setState(() => _rotation = v);
																				_persist();
																			},
																		),
																		if (_showScreenLockOption)
																			_OptionCheckRow(
																				label: "鎖定畫面",
																				value: _screenLock,
																				onChanged: (bool v) {
																					_click();
																					setState(() => _screenLock = v);
																					_persist();
																				},
																			),
																	],
																),
															),
														),
														const SizedBox(width: 16),

														// 切割模式：方格 / 不規則（垂直排列）
														Material(
															color: Colors.white,
															borderRadius: BorderRadius.circular(12),
															child: Padding(
																padding: const EdgeInsets.symmetric(
																		horizontal: 8, vertical: 4),
																child: SegmentedButton<CutMode>(
																	multiSelectionEnabled: true,
																	emptySelectionAllowed: false,
																	direction: Axis.vertical,
																	style: ButtonStyle(
																		shape: WidgetStateProperty.all(
																			RoundedRectangleBorder(
																				borderRadius:
																						BorderRadius.circular(12),
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
																	selected: _cutModes,
																	onSelectionChanged: (Set<CutMode> sel) {
																		// emptySelectionAllowed = false 已會擋掉「全空」
																		// 的點擊，這裡保險再過濾一次。
																		if (sel.isEmpty) return;
																		_click();
																		setState(
																				() => _cutModes = Set<CutMode>.from(sel));
																		_persist();
																	},
																),
															),
														),
														const SizedBox(width: 16),

														// 開始按鈕
														ElevatedButton(
															onPressed: ClickSound.wrap(context, () {
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
															style: ElevatedButton.styleFrom(
																backgroundColor: Colors.white,
																foregroundColor: AppColors.primary,
																padding: const EdgeInsets.symmetric(
																		horizontal: 40, vertical: 14),
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
	final void Function(bool) onChanged;

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
