import "dart:async";
import "dart:math";
import "dart:ui" as ui;

import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:provider/provider.dart";

import "../../../core/audio/audio_service.dart";
import "../../../core/audio/voice_service.dart";
import "../../../core/constants/app_colors.dart";
import "../../../core/constants/app_dimens.dart";
import "../../../core/storage/gallery_repository.dart";
import "../../../core/system/system_guard.dart";
import "../../../shared/widgets/click_sound.dart";
import "../../../shared/widgets/long_press_progress_button.dart";
import "../domain/services/cell_planner.dart";
import "../domain/models/puzzle_piece.dart";
import "../puzzle_dimens.dart";
import "puzzle_controller.dart";
import "puzzle_setup_page.dart";
import "widgets/level_complete_overlay.dart";
import "widgets/puzzle_canvas.dart";

/// 拼圖頁面：每關隨機抽圖（不重複前幾關）、塊數依設定範圍隨機。
///
/// 進入時必須從 Navigator 帶入 [PuzzleArguments]（minPieces / maxPieces / showHint）。
class PuzzlePage extends StatefulWidget {
	const PuzzlePage({super.key});

	@override
	State<PuzzlePage> createState() => _PuzzlePageState();
}

class _PuzzlePageState extends State<PuzzlePage> {
	PuzzleController? _controller;
	bool _completed = false;
	bool _initialized = false;

	final Random _random = Random();

	// 從 PuzzleArguments 帶入
	int _minPieces = 4;
	int _maxPieces = 10;
	bool _showHint = true;
	Set<CutMode> _cutModes = <CutMode>{CutMode.grid, CutMode.voronoi};
	bool _rotationEnabled = false;
	bool _screenLockEnabled = false;

	// 當前關卡狀態
	int _seed = 0;
	int _pieceCount = 6;
	int _imageIndex = 0;
	CutMode _cutMode = CutMode.grid;

	/// 啟用中的所有圖路徑清單。值可能是「assets/...」（內建套）或絕對檔案路徑
	/// （自訂套）。在 [_bootstrap] 從 [GalleryRepository.enabledImages] 取得。
	List<String> _puzzleAssets = const <String>[];

	/// 每張圖最後出現的「關卡序號」（key = 圖索引，value = 關序）。
	/// 未出現過的圖不在 map 中。
	final Map<int, int> _lastShownLevel = <int, int>{};

	/// 目前累積的關卡序號（從 0 起算，每出一張圖 +1）。
	int _levelCounter = 0;

	/// Debug：第一次進入時強制使用的參數。null 表示直接走隨機。
	/// 找到問題切割時把 (n, seed) 填進來，重啟 App 即可重現；驗證修好後改回 null。
	// ignore: unnecessary_nullable_for_final_variable_declarations
	static const ({int n, int seed})? _debugFirstLevel = null;

	/// Debug：是否在右下角顯示 n / seed / mode 並讓它可點擊切下一關。
	/// 找問題切割時開啟、平常關閉。
	static const bool _showDebugOverlay = false;

	/// 是否還沒抽過任何隨機關卡（用來判斷是否套用 [_debugFirstLevel]）。
	bool _firstLevel = true;

	@override
	void didChangeDependencies() {
		super.didChangeDependencies();
		if (_initialized) return;
		_initialized = true;

		final Object? args = ModalRoute.of(context)?.settings.arguments;
		if (args is PuzzleArguments) {
			_minPieces = args.minPieces;
			_maxPieces = args.maxPieces;
			_showHint = args.showHint;
			if (args.cutModes.isNotEmpty) {
				_cutModes = Set<CutMode>.from(args.cutModes);
			}
			_rotationEnabled = args.rotationEnabled;
			_screenLockEnabled = args.screenLockEnabled;
		}
		// 等第一個 layout 完成後再產 controller（需要實際的畫面尺寸）
		WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
	}

	Future<void> _bootstrap() async {
		// 家長若於 setup 頁勾選「鎖定畫面」、進入拼圖頁時嘗試啟動 app pinning。
		// 失敗（極少數機型 / 模式）就 silently 略過、不卡流程。
		if (_screenLockEnabled) {
			await SystemGuard.enable();
			if (!mounted) return;
		}

		final List<String> images =
				context.read<GalleryRepository>().enabledImageTokens();
		if (!mounted) return;
		if (images.isEmpty) {
			await _showEmptyGalleryThenExit();
			return;
		}
		setState(() {
			_puzzleAssets = images;
		});
		_pickRandomLevelParams();
		await _resetController();
	}

	/// 沒有任何可用圖時：顯示提示對話框 → 關掉後返回上一頁。
	Future<void> _showEmptyGalleryThenExit() async {
		await showDialog<void>(
			context: context,
			barrierDismissible: false,
			builder: (BuildContext ctx) => AlertDialog(
				title: const Text("沒有可用的圖庫"),
				content: const Text(
					"請先在「家長區 → 圖庫管理」勾選或新增至少一套含圖片的圖庫。",
				),
				actions: <Widget>[
					ElevatedButton(
						onPressed: ClickSound.wrap(ctx, () => Navigator.of(ctx).pop()),
						child: const Text("好"),
					),
				],
			),
		);
		if (!mounted) return;
		Navigator.of(context).maybePop();
	}

	/// 隨機決定下一關的 seed / 塊數 / 圖片索引（避開最近用過的）。
	void _pickRandomLevelParams() {
		if (_firstLevel && _debugFirstLevel != null) {
			_pieceCount = _debugFirstLevel!.n;
			_seed = _debugFirstLevel!.seed;
			_imageIndex = _pickNextImageIndex();
			_firstLevel = false;
			return;
		}
		_firstLevel = false;
		_seed = _random.nextInt(1 << 31);
		_pieceCount = _minPieces == _maxPieces
				? _minPieces
				: _minPieces + _random.nextInt(_maxPieces - _minPieces + 1);
		_imageIndex = _pickNextImageIndex();
		_cutMode = _pickRandomCutMode();
	}

	/// 從啟用的切割模式集合裡均勻隨機抽一個。空集合 fallback 到 grid。
	CutMode _pickRandomCutMode() {
		if (_cutModes.isEmpty) return CutMode.grid;
		final List<CutMode> list = _cutModes.toList();
		return list[_random.nextInt(list.length)];
	}

	/// 用權重隨機抽下一張圖。
	///
	/// 每張圖 i 的權重 = `min(1, d_i / n)`，其中：
	/// - `d_i` = 這張圖「上次出現後過了幾關」（從未出現過視為 d=∞ → 權重 1）
	/// - `n` = 圖的總數
	///
	/// **保證冷卻**：若 `d_i ≤ 0.4 × n` 則權重強制為 0，確保剛出現過的圖在
	/// 接下來 40% 圖數量的關卡內絕不重複。
	///
	/// 結果：冷卻期內權重 0，冷卻過後 d/n 線性回升，距離超過 n 關後達到上限 1。
	int _pickNextImageIndex() {
		if (_puzzleAssets.isEmpty) return 0;
		final int n = _puzzleAssets.length;
		if (n == 1) return 0;

		// 冷卻關數：0.4 × n（向下取整；至少 0）
		final int cooldown = (n * 0.4).floor();

		// 計算每張圖的權重
		final List<double> weights = List<double>.generate(n, (int i) {
			final int? lastLevel = _lastShownLevel[i];
			if (lastLevel == null) return 1.0;
			final int distance = _levelCounter - lastLevel;
			if (distance <= cooldown) return 0.0;
			final double w = distance / n;
			return w > 1.0 ? 1.0 : w;
		});

		// 加權隨機：累積分佈 → 抽 [0, total) 的點
		double total = 0;
		for (final double w in weights) {
			total += w;
		}
		// 極端保險：若所有權重為 0（理論上 cooldown < n 時不可能），均勻抽
		if (total <= 0) return _random.nextInt(n);

		final double pick = _random.nextDouble() * total;
		double acc = 0;
		int picked = n - 1;
		for (int i = 0; i < n; i++) {
			acc += weights[i];
			if (pick < acc) {
				picked = i;
				break;
			}
		}

		// 記錄此張圖在本關出現、推進關卡計數
		_lastShownLevel[picked] = _levelCounter;
		_levelCounter++;
		return picked;
	}

	Future<void> _resetController() async {
		if (_puzzleAssets.isEmpty) return;
		// 先在 await 之前把要的東西從 context 取出來
		final Size size = MediaQuery.of(context).size;
		final AudioService audio = context.read<AudioService>();
		final VoiceService voice = context.read<VoiceService>();
		final GalleryRepository gallery = context.read<GalleryRepository>();
		final String assetPath = _puzzleAssets[
			_imageIndex % _puzzleAssets.length
		];
		final _LoadedImage loaded = await _loadAssetImage(assetPath, gallery);

		final PuzzleStageLayout stage = PuzzleStageLayout.forSize(size);
		final PuzzleController c = PuzzleController.newLevel(
			stageLayout: stage,
			boardImage: loaded.image,
			boardImageSize: loaded.size,
			pieceCount: _pieceCount,
			cutMode: _cutMode,
			seed: _seed,
		);
		// 旋轉設定要在 scatter 之前套，否則初始角度不會被灑進去
		c.rotationEnabled = _rotationEnabled;
		c.rotationStepDeg = _cutMode == CutMode.grid
				? PuzzleDimens.rotationStepGridDeg
				: PuzzleDimens.rotationStepVoronoiDeg;
		// 一開始全部散落到右側
		c.scatterPiecesToRight(seed: _seed + 1);

		// 接音效 / TTS（audio/tts 已在 await 之前取出）
		c.onPickup = () => audio.play(SfxKind.pickup);
		c.onDrop = () => audio.play(SfxKind.drop);
		c.onSnap = (bool merged, bool locked) => audio.play(SfxKind.snap);
		c.onRotateStep = () => audio.play(SfxKind.rotate);
		c.onCompleted = () {
			audio.play(SfxKind.complete);
			voice.speakLevelComplete();
			_handleCompleted();
		};
		// 進關卡的語音提示
		voice.speakLevelStart();

		if (!mounted) {
			loaded.image.dispose();
			return;
		}
		setState(() {
			_controller?.dispose();
			_controller = c;
			_completed = false;
		});
	}

	void _handleCompleted() {
		if (!mounted) return;
		setState(() => _completed = true);
	}

	void _goNextLevel() {
		if (_puzzleAssets.isEmpty) return;
		_pickRandomLevelParams();
		_resetController();
	}

	@override
	void dispose() {
		_controller?.dispose();
		// 離開拼圖頁 → 解除 app pinning。fire-and-forget；非 Android / 未啟用
		// 都會靜默 no-op。
		SystemGuard.disable();
		super.dispose();
	}

	/// 是否該隱藏右上 X 按鈕：有任何拼片接近右上角區域時隱藏，避免拖曳誤觸。
	bool _shouldHideCloseButton() {
		final PuzzleController? c = _controller;
		if (c == null) return false;
		final Size screen = MediaQuery.of(context).size;
		// 右上「危險區」：包住 X 按鈕（top:12, right:12, ~64×64）加上 buffer。
		const double dangerSize = 60;
		final Rect dangerZone = Rect.fromLTWH(
			screen.width - dangerSize,
			0,
			dangerSize,
			dangerSize,
		);
		for (final PuzzlePiece p in c.layout.pieces) {
			if (p.locked) continue;
			final Rect pieceRect = p.currentPosition & p.sourceRect.size;
			if (pieceRect.overlaps(dangerZone)) return true;
		}
		return false;
	}

	@override
	Widget build(BuildContext context) {
		return Scaffold(
			backgroundColor: AppColors.boardBackground,
			body: Stack(
				children: <Widget>[
					if (_controller != null)
						PuzzleCanvas(
							controller: _controller!,
							showCutLineHint: _showHint,
						)
					else
						const Center(child: CircularProgressIndicator()),

					// 過關 overlay：只覆蓋右半散落區，左側完成圖保持可見
					if (_completed && _controller != null)
						LevelCompleteOverlay(
							region: _controller!.stageLayout.scatterRect,
							onContinue: _goNextLevel,
						),

					// 右下角 debug：顯示切割參數（n / seed / mode）；點一下換下一關，
					// 方便快速掃過大量切割找問題案例。由 [_showDebugOverlay] 開關。
					if (_showDebugOverlay)
						Positioned(
							right: 8,
							bottom: 8,
							child: GestureDetector(
								behavior: HitTestBehavior.opaque,
								onTap: _goNextLevel,
								child: Container(
									padding: const EdgeInsets.symmetric(
										horizontal: 8,
										vertical: 4,
									),
									decoration: BoxDecoration(
										color: Colors.black.withValues(alpha: 0.5),
										borderRadius: BorderRadius.circular(6),
									),
									child: Text(
										"n=$_pieceCount seed=$_seed "
												"img=$_imageIndex mode=${_cutMode.name}",
										style: const TextStyle(
											color: Colors.white,
											fontSize: 12,
											fontFamily: "monospace",
										),
									),
								),
							),
						),

					// 右上角返回按鈕：必須長按 [closeLongPressSeconds] 秒才真的關閉（避
					// 免幼兒誤觸）；拼片靠近時淡出避讓（500ms 由 AnimatedOpacity 處理）。
					Positioned(
						top: 12,
						right: 12,
						child: _controller == null
								? const SizedBox.shrink()
								: ValueListenableBuilder<int>(
										valueListenable: _controller!.repaintTick,
										builder: (BuildContext context, _, Widget? unused) {
											final bool hidden = _shouldHideCloseButton();
											return AnimatedOpacity(
												opacity: hidden ? 0.0 : 1.0,
												duration: const Duration(milliseconds: 500),
												child: IgnorePointer(
													ignoring: hidden,
													child: LongPressProgressButton(
														seconds: AppDimens.gearLongPressSeconds,
														onComplete: () =>
																Navigator.of(context).maybePop(),
														progressColor: AppColors.primary,
														child: Container(
															width: 56,
															height: 56,
															decoration: BoxDecoration(
																shape: BoxShape.circle,
																color: Colors.white.withValues(alpha: 0.9),
															),
															child: const Icon(
																Icons.close,
																color: AppColors.primary,
																size: 28,
															),
														),
													),
												),
											);
										},
									),
					),
				],
			),
		);
	}
}

/// 載入結果包裝。
class _LoadedImage {
	const _LoadedImage(this.image, this.size);
	final ui.Image image;
	final ui.Size size;
}

/// 載入一張圖（assets 路徑或 `imageId:<uuid>` token 都支援），解成 ui.Image。
///
/// - 以 `assets/` 開頭 → 走 rootBundle
/// - 以 `imageId:` 開頭 → 走 [GalleryRepository.readImageBytes]
Future<_LoadedImage> _loadAssetImage(
	String token,
	GalleryRepository gallery,
) async {
	final Uint8List bytes;
	if (token.startsWith("imageId:")) {
		final String id = token.substring("imageId:".length);
		final Uint8List? data = gallery.readImageBytes(id);
		if (data == null) {
			throw StateError("找不到圖片 bytes：$id");
		}
		bytes = data;
	} else {
		bytes = (await rootBundle.load(token)).buffer.asUint8List();
	}
	final ui.Codec codec = await ui.instantiateImageCodec(bytes);
	final ui.FrameInfo frame = await codec.getNextFrame();
	final ui.Image image = frame.image;
	return _LoadedImage(
		image,
		ui.Size(image.width.toDouble(), image.height.toDouble()),
	);
}
