import "dart:async";
import "dart:math";
import "dart:ui" as ui;

import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:provider/provider.dart";
import "package:showcaseview/showcaseview.dart";

import "../../../core/audio/audio_service.dart";
import "../../../core/audio/voice_service.dart";
import "../../../core/constants/app_colors.dart";
import "../../../core/constants/app_dimens.dart";
import "../../../core/storage/gallery_repository.dart";
import "../../../core/storage/settings_repository.dart";
import "../../../core/system/system_guard.dart";
import "../../../shared/widgets/centered_showcase_bubble.dart";
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

	/// 預先決定下一關要用的圖索引（在當前關完成的同時開始下載）。
	/// `null` 表示尚未預決定（例如剛進入頁面或第一關還沒打完）。
	int? _preloadedNextImageIndex;

	/// 預載中的下一張圖 Future。完成關卡的瞬間發起、`_goNextLevel` 時 await。
	/// 若使用者切下一關時 Future 已 resolve，幾乎無延遲；否則顯示 spinner 等候。
	Future<_LoadedImage>? _preloadedNextImage;

	/// 是否正在等候圖片下載（顯示 spinner overlay）。
	bool _loadingNextImage = false;

	/// _goNextLevel 重入鎖：點下後直到下一關完全載入完畢才能再次觸發。
	/// 避免幼兒連點 / 多指亂按時排到一堆重複的轉場。
	bool _advancing = false;

	/// 拼圖頁 welcome 教學 key + controller。第一次進來顯示一段說明；之後不再顯示。
	final GlobalKey _tutorialWelcomeKey = GlobalKey();
	late final ShowcaseView _showcase;

	/// 拼圖頁教學「當前版本」。更新教學內容時 bump 此值，舊使用者會重看一次。
	static const int _puzzleTutorialVersion = 1;

	/// 教學氣泡 active 期間 PuzzleCanvas 不接受輸入。
	///
	/// 原因：PuzzleCanvas 內部用 `Listener` 整片接 pointer events（raw 事件、
	/// 不進 gesture arena），會立刻處理 pointer-down 把事件 capture 掉，
	/// 導致 Showcase 的 backdrop tap（走 GestureDetector → tap recognizer 等 release）
	/// 永遠等不到完整 click。教學顯示時用 IgnorePointer 把 canvas 整片暫停。
	bool _tutorialActive = false;

	@override
	void initState() {
		super.initState();
		_showcase = ShowcaseView.register(
			scope: "puzzle",
			disableMovingAnimation: true,
		);
	}

	@override
	void dispose() {
		_controller?.dispose();
		_showcase.unregister();
		// 離開拼圖頁 → 解除 app pinning。fire-and-forget；非 Android / 未啟用
		// 都會靜默 no-op。
		SystemGuard.disable();
		super.dispose();
	}

	Future<void> _maybeStartTutorial() async {
		if (!mounted) return;
		final SettingsRepository repo = context.read<SettingsRepository>();
		final int seen = repo.tutorialVersionSeen("puzzle");
		if (seen >= _puzzleTutorialVersion) return;
		setState(() => _tutorialActive = true);
		_showcase.startShowCase(<GlobalKey>[_tutorialWelcomeKey]);
		repo.setTutorialVersionSeen("puzzle", _puzzleTutorialVersion);
	}

	/// 教學氣泡被點掉時呼叫：先讓套件推進 / 結束流程，再解除 PuzzleCanvas 的
	/// IgnorePointer。
	void _dismissTutorial() {
		_showcase.next();
		if (!mounted) return;
		setState(() => _tutorialActive = false);
	}

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
		if (!mounted) return;
		// controller 就緒、第一關拼片散落後才啟動教學氣泡。
		await _maybeStartTutorial();
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

	Future<void> _resetController({Future<_LoadedImage>? preloaded}) async {
		if (_puzzleAssets.isEmpty) return;
		// 先在 await 之前把要的東西從 context 取出來
		final Size size = MediaQuery.of(context).size;
		final AudioService audio = context.read<AudioService>();
		final VoiceService voice = context.read<VoiceService>();
		final GalleryRepository gallery = context.read<GalleryRepository>();
		final String assetPath = _puzzleAssets[
			_imageIndex % _puzzleAssets.length
		];
		final Future<_LoadedImage> future = preloaded ??
				_loadAssetImage(assetPath, gallery);
		final _LoadedImage loaded = await future;

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
		// 玩家還在看慶祝動畫 / 點下一關前，先預下載下一關的圖。
		// 連線快的話到使用者真的點下一關時已 ready，幾乎無感切換。
		_startPreloadNext();
	}

	/// 預先決定下一關的圖索引並開始 async 載入。
	/// 注意：這裡只「先決定圖」，塊數 / seed / cutMode 等仍在 _goNextLevel 才抽，
	/// 因為這些不影響圖片下載、且避免提前消耗 RNG 狀態。
	void _startPreloadNext() {
		if (_puzzleAssets.isEmpty) return;
		// 已經有預載中的 Future（極端狀況：double-tap 觸發了兩次完成）→ 不重發
		if (_preloadedNextImage != null) return;

		final int nextIndex = _pickNextImageIndex();
		final String token = _puzzleAssets[nextIndex % _puzzleAssets.length];
		final GalleryRepository gallery = context.read<GalleryRepository>();
		_preloadedNextImageIndex = nextIndex;
		_preloadedNextImage = _loadAssetImage(token, gallery);
	}

	Future<void> _goNextLevel() async {
		if (_puzzleAssets.isEmpty) return;
		// 重入鎖：第一指按下後，後續多指 / 連點全部 no-op，直到本次轉場結束
		if (_advancing) return;
		_advancing = true;

		// 接手預載的 Future / 索引；若沒有（極端狀況）則 fallback 走原本流程
		Future<_LoadedImage>? pre = _preloadedNextImage;
		final int? preIndex = _preloadedNextImageIndex;
		_preloadedNextImage = null;
		_preloadedNextImageIndex = null;

		// 抽塊數、seed、cutMode；圖片若已預載則沿用、否則重抽
		_seed = _random.nextInt(1 << 31);
		_pieceCount = _minPieces == _maxPieces
				? _minPieces
				: _minPieces + _random.nextInt(_maxPieces - _minPieces + 1);
		_cutMode = _pickRandomCutMode();
		if (preIndex != null) {
			_imageIndex = preIndex;
		} else {
			_imageIndex = _pickNextImageIndex();
			pre = null;
		}

		// 如果預載 Future 還沒 resolve，這裡會被 await 住 → 給使用者一個 spinner
		// 視覺反饋。已 resolve 的話就會立刻往下走、不顯示 spinner（避免閃一下）。
		bool spinnerShown = false;
		if (pre != null) {
			final Completer<void> readyOrTimeout = Completer<void>();
			pre.whenComplete(() {
				if (!readyOrTimeout.isCompleted) readyOrTimeout.complete();
			});
			// 給 16ms（一幀）的機會：若 Future 已 resolve 就不顯示 spinner
			await Future.any(<Future<void>>[
				readyOrTimeout.future,
				Future<void>.delayed(const Duration(milliseconds: 16)),
			]);
			if (!mounted) return;
			if (!readyOrTimeout.isCompleted) {
				setState(() => _loadingNextImage = true);
				spinnerShown = true;
			}
		} else {
			setState(() => _loadingNextImage = true);
			spinnerShown = true;
		}

		await _resetController(preloaded: pre);

		if (!mounted) {
			_advancing = false;
			return;
		}
		if (spinnerShown) {
			setState(() => _loadingNextImage = false);
		}
		// 下一關 controller 已就緒、UI 已切換 → 解鎖，允許下次過關後再進
		_advancing = false;
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
						IgnorePointer(
							// 教學氣泡 active 時，整片 canvas 不接受輸入；否則 PuzzleCanvas
							// 內部的 Listener 會立刻 capture pointer-down，使 Showcase
							// backdrop 的 tap recognizer 永遠等不到 release 確認。
							ignoring: _tutorialActive,
							child: PuzzleCanvas(
								controller: _controller!,
								showCutLineHint: _showHint,
							),
						)
					else
						const Center(child: CircularProgressIndicator()),

					// 過關 overlay：只覆蓋右半散落區，左側完成圖保持可見
					if (_completed && _controller != null)
						LevelCompleteOverlay(
							region: _controller!.stageLayout.scatterRect,
							onContinue: _goNextLevel,
						),

					// 切換下一關時，若預載的圖片尚未下載完成 → 顯示全螢幕 spinner
					if (_loadingNextImage)
						Positioned.fill(
							child: Container(
								color: Colors.black.withValues(alpha: 0.45),
								child: const Center(child: CircularProgressIndicator()),
							),
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

					// 首次進拼圖頁的教學氣泡（畫面中央，無 highlight）。
					CenteredShowcaseBubble(
						showcaseKey: _tutorialWelcomeKey,
						message: "將拼片逐一放回左邊的框中以完成拼圖。"
								"長壓右上角的關閉圖示即可退出（為了避免誤觸，"
								"必須先將附近的拼片移開、圖示才會出現喔～）",
						onTap: _dismissTutorial,
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
