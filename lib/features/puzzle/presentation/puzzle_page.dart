import "dart:async";
import "dart:math";
import "dart:ui" as ui;

import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:provider/provider.dart";
import "package:showcaseview/showcaseview.dart";

import "../../../core/analytics/analytics_service.dart";
import "../../../core/audio/audio_service.dart";
import "../../../core/audio/voice_service.dart";
import "../../../core/constants/app_colors.dart";
import "../../../core/constants/app_dimens.dart";
import "../../../core/constants/ui_strings.dart";
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
import "_diag.dart";
import "widgets/level_complete_overlay.dart";
import "widgets/puzzle_canvas.dart";

/// 設定 debug 後門：下次進入 [PuzzlePage] 時固定用這組 (n, seed) + voronoi 跑
/// 第一關，用完自動清空、之後關卡恢復隨機。
///
/// 由 [KidPuzzleApp.onGenerateInitialRoutes] 在偵測到 URL query
/// `?n=...&seed=...` 時呼叫。
void setPuzzleDebugFirstLevel(({int n, int seed})? v) {
	_PuzzlePageState.debugFirstLevel = v;
}

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

	/// 圖載完但切割還沒好的「過渡圖」：用來顯示未切割的完整大圖。
	///
	/// 流程：
	///   ┌ spinner ┐  ┌── 顯示 _pendingImage ──┐ ┌── 顯示 PuzzleCanvas ───┐
	///   │ 載圖    │  │ plan / cut / prebake / │ │ reveal 動畫 + scatter │
	///   │         │  │ scatter 並行計算       │ │                       │
	///   └─────────┘  └────────────────────────┘ └───────────────────────┘
	///
	/// _imageShownAt：圖開始顯示的時刻（給 200ms 最低 hold 用、由 canvas 端
	/// 算 `now - imageShownAt`、若還沒到 200ms 就延後啟動 reveal 動畫）。
	_LoadedImage? _pendingImage;
	DateTime? _imageShownAt;

	final Random _random = Random();

	// 從 PuzzleArguments 帶入
	int _minPieces = 4;
	int _maxPieces = 10;
	bool _showHint = true;
	Set<CutMode> _cutModes = <CutMode>{CutMode.grid, CutMode.voronoi};
	bool _rotationEnabled = false;
	bool _screenLockEnabled = false;
	bool _bigKidMode = false;

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
	/// 找到問題切割時把 (n, seed) 填進來，重啟 App 即可重現；驗證修好後設回 null。
	///
	/// 也可以由外部設定（例如從 URL query `?n=...&seed=...` 注入）：
	/// 在 push PuzzlePage 之前呼叫 `_PuzzlePageState.debugFirstLevel = (n: ..., seed: ...)`。
	/// 該值只影響「第一關」、之後恢復隨機；用完一次自動清為 null、避免後續關卡又被鎖定。
	static ({int n, int seed})? debugFirstLevel;

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

	/// 當前關卡開始時間（Analytics 用）。null 表示尚未開始任何關卡。
	DateTime? _levelStartTime;

	@override
	void initState() {
		super.initState();
		diag("PuzzlePage initState build=$kDiagBuildTag");
		_showcase = ShowcaseView.register(
			scope: "puzzle",
			disableMovingAnimation: true,
		);
	}

	@override
	void dispose() {
		// 若離開拼圖頁時尚有未完成的關卡 → 送 level_exit。完成關卡時 _levelStartTime
		// 會被清為 null、這裡就不重複送。
		_logLevelExitIfActive();
		_controller?.dispose();
		_showcase.unregister();
		// 離開拼圖頁 → 解除 app pinning。fire-and-forget；非 Android / 未啟用
		// 都會靜默 no-op。
		SystemGuard.disable();
		super.dispose();
	}

	int _elapsedSecondsSinceStart() {
		final DateTime? t = _levelStartTime;
		if (t == null) return 0;
		return DateTime.now().difference(t).inSeconds;
	}

	void _logLevelExitIfActive() {
		if (_levelStartTime == null) return;
		AnalyticsService.instance.logLevelExit(
			pieceCount: _pieceCount,
			cutMode: _cutMode.name,
			durationSec: _elapsedSecondsSinceStart(),
		);
		_levelStartTime = null;
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
			_bigKidMode = args.bigKidMode;
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
				title: const Text(PuzzleStrings.noGalleryTitle),
				content: const Text(PuzzleStrings.noGalleryDesc),
				actions: <Widget>[
					ElevatedButton(
						onPressed: ClickSound.wrap(ctx, () => Navigator.of(ctx).pop()),
						child: const Text(PuzzleStrings.ok),
					),
				],
			),
		);
		if (!mounted) return;
		Navigator.of(context).maybePop();
	}

	/// 隨機決定下一關的 seed / 塊數 / 圖片索引（避開最近用過的）。
	void _pickRandomLevelParams() {
		final ({int n, int seed})? debugFirst = _PuzzlePageState.debugFirstLevel;
		if (_firstLevel && debugFirst != null) {
			_pieceCount = debugFirst.n;
			_seed = debugFirst.seed;
			// debug 後門固定走 voronoi（grid 不會卡死、debug 主要是不規則模式用）
			_cutMode = CutMode.voronoi;
			_imageIndex = _pickNextImageIndex();
			_firstLevel = false;
			// 用完即清，避免後續關卡又被鎖在同樣的 (n, seed)
			_PuzzlePageState.debugFirstLevel = null;
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
		diag("_resetController ENTER preloaded!=null=${preloaded != null} "
				"n=$_pieceCount cutMode=$_cutMode seed=$_seed");
		if (_puzzleAssets.isEmpty) return;
		// 先在 await 之前把要的東西從 context 取出來
		final Size size = MediaQuery.of(context).size;
		final double dpr = MediaQuery.devicePixelRatioOf(context);
		final AudioService audio = context.read<AudioService>();
		final VoiceService voice = context.read<VoiceService>();
		final GalleryRepository gallery = context.read<GalleryRepository>();
		final String assetPath = _puzzleAssets[
			_imageIndex % _puzzleAssets.length
		];
		diag("_resetController awaiting image future");
		final Future<_LoadedImage> future = preloaded ??
				_loadAssetImage(assetPath, gallery);
		final _LoadedImage loaded = await future;
		diag("_resetController image loaded ${loaded.size}");
		if (!mounted) {
			loaded.image.dispose();
			return;
		}

		// 步驟 1：圖一拿到就立刻顯示完整大圖、把舊 controller 拆掉。
		// 這時還沒有 _controller、build 會走 _pendingImage 分支。
		setState(() {
			_controller?.dispose();
			_controller = null;
			_pendingImage = loaded;
			_imageShownAt = DateTime.now();
			_completed = false;
		});

		// 步驟 2：plan / cut（內部已 async + yield）
		final PuzzleStageLayout stage = PuzzleStageLayout.forSize(size);
		diag("_resetController calling newLevel");
		final PuzzleController c = await PuzzleController.newLevel(
			stageLayout: stage,
			boardImage: loaded.image,
			boardImageSize: loaded.size,
			pieceCount: _pieceCount,
			cutMode: _cutMode,
			seed: _seed,
			bigKidMode: _bigKidMode,
		);
		diag("_resetController newLevel done");
		if (!mounted) {
			loaded.image.dispose();
			c.dispose();
			return;
		}
		c.rotationEnabled = _rotationEnabled;
		c.rotationStepDeg = _cutMode == CutMode.grid
				? PuzzleDimens.rotationStepGridDeg
				: PuzzleDimens.rotationStepVoronoiDeg;
		c.bigKidMode = _bigKidMode;

		// 步驟 3：prebake bitmap 快取 + 算散落位置；並行（兩者都非同步、互不依賴）。
		await Future.wait<void>(<Future<void>>[
			c.prebakePieceBitmaps(devicePixelRatio: dpr),
			c.scatterPiecesToRight(seed: _seed + 1),
		]);
		if (!mounted) {
			loaded.image.dispose();
			c.dispose();
			return;
		}

		// 接音效 / TTS（audio/tts 已在 await 之前取出）
		c.onPickup = () => audio.play(SfxKind.pickup);
		c.onDrop = () => audio.play(SfxKind.drop);
		c.onSnap = (bool merged, bool locked) => audio.play(SfxKind.snap);
		c.onRotateStep = () => audio.play(SfxKind.rotate);
		c.onCompleted = () {
			audio.play(SfxKind.complete);
			voice.speakLevelComplete();
			AnalyticsService.instance.logLevelComplete(
				pieceCount: _pieceCount,
				cutMode: _cutMode.name,
				durationSec: _elapsedSecondsSinceStart(),
			);
			_levelStartTime = null;
			_handleCompleted();
		};
		_levelStartTime = DateTime.now();
		AnalyticsService.instance.logLevelStart(
			pieceCount: _pieceCount,
			cutMode: _cutMode.name,
		);

		// 步驟 4：mount canvas、開始進場動畫。語音同時播放（與 reveal 動畫同步啟動）。
		diag("_resetController setState(swap controller)");
		setState(() {
			_controller = c;
			_pendingImage = null;
		});
		voice.speakLevelStart();
		diag("_resetController EXIT");
	}

	void _handleCompleted() {
		diag("_handleCompleted mounted=$mounted _advancing=$_advancing");
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
		diag("_startPreloadNext begin preExists=${_preloadedNextImage != null}");
		if (_puzzleAssets.isEmpty) return;
		// 已經有預載中的 Future（極端狀況：double-tap 觸發了兩次完成）→ 不重發
		if (_preloadedNextImage != null) return;

		final int nextIndex = _pickNextImageIndex();
		final String token = _puzzleAssets[nextIndex % _puzzleAssets.length];
		final GalleryRepository gallery = context.read<GalleryRepository>();
		_preloadedNextImageIndex = nextIndex;
		_preloadedNextImage = _loadAssetImage(token, gallery)
			..then(
				(_) => diag("preload future RESOLVED idx=$nextIndex"),
				onError: (Object e) =>
						diag("preload future REJECTED idx=$nextIndex err=$e"),
			);
		diag("_startPreloadNext launched idx=$nextIndex");
	}

	Future<void> _goNextLevel() async {
		diag("_goNextLevel ENTER _advancing=$_advancing assets=${_puzzleAssets.length}");
		if (_puzzleAssets.isEmpty) {
			diag("_goNextLevel EARLY-RETURN empty-assets");
			return;
		}
		// 重入鎖：第一指按下後，後續多指 / 連點全部 no-op，直到本次轉場結束
		if (_advancing) {
			diag("_goNextLevel EARLY-RETURN already-advancing");
			return;
		}
		_advancing = true;

		// 接手預載的 Future / 索引；若沒有（極端狀況）則 fallback 走原本流程
		Future<_LoadedImage>? pre = _preloadedNextImage;
		final int? preIndex = _preloadedNextImageIndex;
		_preloadedNextImage = null;
		_preloadedNextImageIndex = null;
		diag("_goNextLevel claimed-preload pre!=null=${pre != null} preIdx=$preIndex");

		bool spinnerShown = false;

		// 整個轉場流程包在 try/finally：任何例外（圖片解碼失敗、Provider 缺失等）
		// 都要保證解開 _advancing 鎖與 spinner，否則畫面會卡死、所有按鈕都點不動。
		try {
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
			if (pre != null) {
				diag("_goNextLevel waiting for preload (16ms grace)");
				final Completer<void> readyOrTimeout = Completer<void>();
				pre.whenComplete(() {
					if (!readyOrTimeout.isCompleted) readyOrTimeout.complete();
				});
				// 給 16ms（一幀）的機會：若 Future 已 resolve 就不顯示 spinner
				await Future.any(<Future<void>>[
					readyOrTimeout.future,
					Future<void>.delayed(const Duration(milliseconds: 16)),
				]);
				if (!mounted) {
					diag("_goNextLevel UNMOUNTED during preload wait");
					return;
				}
				if (!readyOrTimeout.isCompleted) {
					diag("_goNextLevel preload not ready in 16ms, showing spinner");
					setState(() => _loadingNextImage = true);
					spinnerShown = true;
				} else {
					diag("_goNextLevel preload ready");
				}
			} else {
				diag("_goNextLevel no preload, showing spinner");
				setState(() => _loadingNextImage = true);
				spinnerShown = true;
			}

			diag("_goNextLevel calling _resetController");
			await _resetController(preloaded: pre);
			diag("_goNextLevel _resetController returned");
		} catch (e, st) {
			diag("_goNextLevel CAUGHT $e");
			debugPrint("[puzzle] _goNextLevel failed: $e\n$st");
		} finally {
			diag("_goNextLevel finally spinnerShown=$spinnerShown mounted=$mounted");
			if (mounted && spinnerShown) {
				setState(() => _loadingNextImage = false);
			}
			// 下一關 controller 已就緒（或失敗）、UI 已切換 → 一律解鎖，
			// 避免任何例外把畫面鎖死。
			_advancing = false;
			diag("_goNextLevel EXIT");
		}
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
			body: LayoutBuilder(
				builder: (BuildContext context, BoxConstraints constraints) {
					// 視窗 / canvas 尺寸變化時即時 rescale，保留遊戲進度。
					// 用 post-frame callback 避免在 layout pass 內動 controller。
					_maybeRescaleForSize(
						Size(constraints.maxWidth, constraints.maxHeight),
					);
					return Stack(
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
								imageShownAt: _imageShownAt,
							),
						)
					else if (_pendingImage != null)
						// 過渡狀態：圖已載入但 controller（plan/cut/prebake/scatter）
						// 還沒準備好。顯示完整未切割大圖、占用左側 board 區。
						_PendingBoardImage(
							image: _pendingImage!,
							cutMode: _cutMode,
							pieceCount: _pieceCount,
						)
					else
						const Center(child: CircularProgressIndicator()),

					// 過關 overlay：只覆蓋右半散落區，左側完成圖保持可見
					if (_completed && _controller != null)
						LevelCompleteOverlay(
							region: _controller!.stageLayout.scatterRect,
							onContinue: () {
								diag("LevelCompleteOverlay tapped");
								_goNextLevel();
							},
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
						message: PuzzleStrings.tutorial,
						onTap: _dismissTutorial,
					),

					// 右上角返回按鈕：必須長按 [closeLongPressSeconds] 秒才真的關閉（避
					// 免幼兒誤觸）。在過渡狀態（_pendingImage、無 controller）也顯示，
					// 此時還沒拼片、不需要 hide 邏輯；有 controller 時拼片靠近會淡出避讓。
					//
					// shouldHide 是 callback（不是 bool）——避免 page build 時就固定值、
					// 拼片之後拖開仍卡在 true。每次 controller.repaintTick 觸發
					// _CloseButton 內 builder rebuild 時重算。
					if (_controller != null || _pendingImage != null)
						Positioned(
							top: 12,
							right: 12,
							child: _CloseButton(
								controller: _controller,
								bigKidMode: _bigKidMode,
								shouldHide: _shouldHideCloseButton,
							),
						),
				],
			);
				},
			),
		);
	}

	/// 視窗 / canvas 尺寸改變時呼叫 controller.rescaleStage（如果尺寸有顯著
	/// 差異）。用 post-frame callback 避免在 layout pass 內 mutate controller、
	/// 觸發 assertion。
	void _maybeRescaleForSize(Size newSize) {
		final PuzzleController? c = _controller;
		if (c == null) return;
		if (newSize.width <= 0 || newSize.height <= 0) return;
		final ui.Size cur = c.stageLayout.totalSize;
		if ((cur.width - newSize.width).abs() < 0.5 &&
				(cur.height - newSize.height).abs() < 0.5) {
			return;
		}
		WidgetsBinding.instance.addPostFrameCallback((_) {
			if (!mounted) return;
			final PuzzleController? cc = _controller;
			if (cc == null) return;
			final ui.Size again = cc.stageLayout.totalSize;
			if ((again.width - newSize.width).abs() < 0.5 &&
					(again.height - newSize.height).abs() < 0.5) {
				return;
			}
			cc.rescaleStage(PuzzleStageLayout.forSize(newSize));
		});
	}
}

/// 載入結果包裝。
class _LoadedImage {
	const _LoadedImage(this.image, this.size);
	final ui.Image image;
	final ui.Size size;
}

/// 永不通知變動的 ValueListenable，給 [_CloseButton] 在「過渡狀態（無 controller）」
/// 時當 placeholder——這樣 widget tree shape 與「有 controller」階段一致、
/// AnimatedOpacity 不會在階段切換時被丟掉。
class _NeverNotifier implements ValueListenable<int> {
	const _NeverNotifier();
	@override
	int get value => 0;
	@override
	void addListener(VoidCallback listener) {}
	@override
	void removeListener(VoidCallback listener) {}
}

/// 右上角返回按鈕：長按 [AppDimens.gearLongPressSeconds] 秒（或大朋友模式
/// 下立即觸發）執行 maybePop。
///
/// - [controller] 非 null 時用 repaintTick 訂閱、配合 shouldHide 做拼片靠近時
///   淡出。
/// - [controller] null（過渡狀態）時不訂閱、固定顯示。
class _CloseButton extends StatelessWidget {
	const _CloseButton({
		required this.controller,
		required this.bigKidMode,
		required this.shouldHide,
	});

	final PuzzleController? controller;
	final bool bigKidMode;
	/// callback 而非 bool：每次 ValueListenableBuilder rebuild 都重算，避免
	/// page build 時固定值、拼片之後拖開仍卡在 true。
	final ValueGetter<bool> shouldHide;

	Widget _button(BuildContext context, {required bool hidden}) {
		return AnimatedOpacity(
			opacity: hidden ? 0.0 : 1.0,
			duration: const Duration(milliseconds: 500),
			child: IgnorePointer(
				ignoring: hidden,
				child: LongPressProgressButton(
					seconds: bigKidMode ? 0 : AppDimens.gearLongPressSeconds,
					onComplete: ClickSound.wrap(
						context,
						() => Navigator.of(context).maybePop(),
					)!,
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
	}

	@override
	Widget build(BuildContext context) {
		// 用「controller 變動時也存活」的單一 widget tree、確保 AnimatedOpacity
		// 在過渡 → 遊戲階段切換時不被丟掉、能正常淡出而非瞬間消失。
		final PuzzleController? c = controller;
		// 過渡狀態（controller == null）：訂閱一個 dummy ValueListenable（永遠
		// 不會 bump），hidden 固定 false。遊戲階段：訂閱 controller.repaintTick、
		// hidden 由 shouldHide() 動態決定。
		final ValueListenable<int> listenable =
				c?.repaintTick ?? const _NeverNotifier();
		return ValueListenableBuilder<int>(
			valueListenable: listenable,
			builder: (BuildContext context, _, Widget? unused) {
				final bool hidden = c == null ? false : shouldHide();
				return _button(context, hidden: hidden);
			},
		);
	}
}

/// 過渡期顯示：圖載完但 controller 還沒準備好時，用 [PuzzleStageLayout] 算出
/// 的 boardRect 把完整未切割大圖畫到正確位置；右半填散落區底色。
///
/// 上方疊「刀光快速劃過」spinner：每 [_slashIntervalMs] 毫秒生一刀，每刀是
/// 一段短漸層線在 [_slashDurationMs] 毫秒內以等速沿其角度方向掠過 board，
/// 視覺上像「快速切割」。中心點對 boardRect 中心加 jitter（範圍 ±50% 短邊）。
class _PendingBoardImage extends StatefulWidget {
	const _PendingBoardImage({
		required this.image,
		required this.cutMode,
		required this.pieceCount,
	});

	final _LoadedImage image;

	/// 切割模式：[CutMode.grid] 時刀光角度只取垂直 / 水平；[CutMode.voronoi]
	/// 時任意角度 0~π。
	final CutMode cutMode;

	/// 該關片數。低於 [_pendingAnimationsMinPieces] 時切割很快、不顯示刀光與
	/// 中央 spinner（純大圖即可），避免短暫閃爍動畫。
	final int pieceCount;

	@override
	State<_PendingBoardImage> createState() => _PendingBoardImageState();
}

class _PendingBoardImageState extends State<_PendingBoardImage>
		with SingleTickerProviderStateMixin {
	/// 每隔多久觸發一刀。
	static const int _slashIntervalMs = 700;
	/// 單刀掠過時長。
	static const int _slashDurationMs = 300;
	/// 漸層線本身長度相對 boardRect 短邊的比例。
	static const double _slashLengthRatio = 0.4;
	/// 刀光中心點對 boardRect 中心的最大 jitter（相對短邊比例）。
	static const double _centerJitterRatio = 0.25;
	/// 片數 < 此值就不顯示刀光與中央 spinner（切割很快、動畫只會閃一下）。
	static const int _pendingAnimationsMinPieces = 50;

	late final AnimationController _controller;
	final Random _random = Random();
	final List<_Slash> _slashes = <_Slash>[];
	Timer? _spawnTimer;
	int _nextId = 0;

	bool get _animationsEnabled =>
			widget.pieceCount >= _pendingAnimationsMinPieces;

	@override
	void initState() {
		super.initState();
		// 連續 ticker：讓 painter 每幀 rebuild、推進所有 active slash 的進度。
		_controller = AnimationController(
			vsync: this,
			duration: const Duration(milliseconds: 1000),
		);
		// 低片數時不啟動動畫（純大圖、無 spinner、無刀光）。
		if (_animationsEnabled) {
			_controller.repeat();
			_spawnTimer = Timer.periodic(
				const Duration(milliseconds: _slashIntervalMs),
				(_) => _spawn(),
			);
			// 首刀立即出（不等 _slashIntervalMs）
			_spawn();
		}
	}

	void _spawn() {
		if (!mounted) return;
		// grid 模式：刀光只能垂直或水平。
		final double angle;
		if (widget.cutMode == CutMode.grid) {
			angle = _random.nextBool() ? 0.0 : pi / 2;
		} else {
			angle = _random.nextDouble() * pi;
		}
		setState(() {
			_slashes.add(_Slash(
				id: _nextId++,
				angleRad: angle,
				jitterFracX: _random.nextDouble() * 2 - 1,
				jitterFracY: _random.nextDouble() * 2 - 1,
				startedAt: DateTime.now(),
			));
			// 清掉已超過時長的
			final DateTime now = DateTime.now();
			_slashes.removeWhere((_Slash s) =>
					now.difference(s.startedAt).inMilliseconds > _slashDurationMs);
		});
	}

	@override
	void dispose() {
		_spawnTimer?.cancel();
		_controller.dispose();
		super.dispose();
	}

	@override
	Widget build(BuildContext context) {
		return LayoutBuilder(
			builder: (BuildContext context, BoxConstraints constraints) {
				final Size totalSize =
						Size(constraints.maxWidth, constraints.maxHeight);
				final PuzzleStageLayout stage =
						PuzzleStageLayout.forSize(totalSize);
				return Stack(
					children: <Widget>[
						// 圖 + 散落區底色 + （若啟用）刀光
						Positioned.fill(
							child: AnimatedBuilder(
								animation: _controller,
								builder: (BuildContext context, _) {
									return CustomPaint(
										size: totalSize,
										painter: _PendingBoardImagePainter(
											image: widget.image.image,
											imageSize: widget.image.size,
											boardRect: stage.boardRect,
											scatterRect: stage.scatterRect,
											slashes: _animationsEnabled ? _slashes : const <_Slash>[],
											now: DateTime.now(),
											slashDurationMs: _slashDurationMs,
											slashLengthRatio: _slashLengthRatio,
											centerJitterRatio: _centerJitterRatio,
										),
									);
								},
							),
						),
						// 大圖中央 spinner：只在啟用動畫時出現（高片數 = 切割慢、才需要提示）。
						if (_animationsEnabled)
							Positioned.fromRect(
								rect: stage.boardRect,
								child: const Center(
									child: SizedBox(
										width: 48,
										height: 48,
										child: CircularProgressIndicator(
											strokeWidth: 4,
											valueColor: AlwaysStoppedAnimation<Color>(
												Colors.white,
											),
										),
									),
								),
							),
					],
				);
			},
		);
	}

}

/// 單一刀光描述：
/// - [angleRad]：行進方向（弧度、0~π）
/// - [jitterFracX / Y]：中心 jitter 在 [-1, 1]，乘上 [_centerJitterRatio] × 短邊
/// - [startedAt]：起始時刻；painter 用 `now - startedAt` 算 0..1 進度
class _Slash {
	const _Slash({
		required this.id,
		required this.angleRad,
		required this.jitterFracX,
		required this.jitterFracY,
		required this.startedAt,
	});
	final int id;
	final double angleRad;
	final double jitterFracX;
	final double jitterFracY;
	final DateTime startedAt;
}

class _PendingBoardImagePainter extends CustomPainter {
	_PendingBoardImagePainter({
		required this.image,
		required this.imageSize,
		required this.boardRect,
		required this.scatterRect,
		required this.slashes,
		required this.now,
		required this.slashDurationMs,
		required this.slashLengthRatio,
		required this.centerJitterRatio,
	});

	final ui.Image image;
	final ui.Size imageSize;
	final ui.Rect boardRect;
	final ui.Rect scatterRect;
	final List<_Slash> slashes;
	final DateTime now;
	final int slashDurationMs;
	final double slashLengthRatio;
	final double centerJitterRatio;

	@override
	void paint(Canvas canvas, Size size) {
		// 1. 盤底色襯
		final Paint boardBg = Paint()..color = AppColors.boardBackground;
		canvas.drawRect(Offset.zero & size, boardBg);
		// 2. 散落區底色（與最終 PuzzlePiecesPainter 一致）
		final Paint scatterBg = Paint()..color = AppColors.pieceArea;
		canvas.drawRect(scatterRect, scatterBg);
		// 3. 整張圖鋪到 boardRect
		canvas.drawImageRect(
			image,
			Rect.fromLTWH(0, 0, imageSize.width, imageSize.height),
			boardRect,
			Paint()..filterQuality = FilterQuality.medium,
		);
		// 4. 刀光
		_paintSlashes(canvas);
	}

	void _paintSlashes(Canvas canvas) {
		if (slashes.isEmpty) return;
		final Offset boardCenter = boardRect.center;
		final double shortSide =
				boardRect.shortestSide;
		final double maxJitter = shortSide * centerJitterRatio;
		final double slashLength = shortSide * slashLengthRatio;
		// 刀光從 board 邊外進入、掠到對側邊外消失。行進總距離 = 對角線長 + 一點
		// buffer，確保完全切過 board；progress 0 起點在 board 外、progress 1
		// 終點在 board 外。
		final double travelDistance =
				sqrt(boardRect.width * boardRect.width +
						boardRect.height * boardRect.height) +
				slashLength;

		canvas.save();
		canvas.clipRect(boardRect);
		for (final _Slash s in slashes) {
			final double t =
					now.difference(s.startedAt).inMilliseconds / slashDurationMs;
			if (t < 0 || t > 1) continue;
			// 中心點：board 中心 + jitter
			final Offset center = boardCenter +
					Offset(s.jitterFracX * maxJitter, s.jitterFracY * maxJitter);
			// 方向向量（沿刀光行進方向）
			final double dirX = cos(s.angleRad);
			final double dirY = sin(s.angleRad);
			// 此時段內、刀光「中心」沿方向位移：從 -travelDistance/2 → +travelDistance/2
			final double offset = (t - 0.5) * travelDistance;
			final Offset segCenter =
					center + Offset(dirX * offset, dirY * offset);
			// 短漸層線兩端
			final Offset a = segCenter - Offset(dirX, dirY) * (slashLength / 2);
			final Offset b = segCenter + Offset(dirX, dirY) * (slashLength / 2);
			final Paint paint = Paint()
				..strokeWidth = 4
				..strokeCap = StrokeCap.round
				..shader = ui.Gradient.linear(
					a,
					b,
					<Color>[
						Colors.white.withValues(alpha: 0.0),
						Colors.white.withValues(alpha: 0.95),
						Colors.white.withValues(alpha: 0.0),
					],
					<double>[0.0, 0.5, 1.0],
				);
			canvas.drawLine(a, b, paint);
		}
		canvas.restore();
	}

	@override
	bool shouldRepaint(covariant _PendingBoardImagePainter oldDelegate) => true;
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
