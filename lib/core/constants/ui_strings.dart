// 集中所有「會在 UI 上實際渲染」的中文字串。
//
// 動機：web 版第一次進入子頁面時，瀏覽器尚未為「該頁才出現」的字下載 glyph，
// 會看到一瞬間 fallback / tofu。把所有 UI 文字集中、串接後交給 FontReadyProbe
// 預熱，第一幀前就保證整個 App 用到的字都已解碼完畢。
//
// 新增 UI 文字時：
// 1. 寫進對應的 const String（如 [home]、[setup]、[parent]…）。
// 2. 在實際渲染處引用同一個 const（不要重新 hard-code 一份）。
// 3. 不需更新 [preheatCharSet] —— 它由所有 group 自動串接 + 去重。
//
// 不在這裡的字串：純除錯字串、log、註解、asset path、不會渲染的程式碼字串。

/// 首頁。
class HomeStrings {
	const HomeStrings._();

	static const String appTitle = "幼兒益智遊戲";
	static const String startButton = "開始拼圖";
	static const String startInsetPuzzle = "嵌入拼圖";
	static const String startMultiPuzzle = "多片拼圖";

	// 教學 ----
	static const String welcomeMessage = "歡迎來到《幼兒益智遊戲》！"
			"本應用程式特別針對幼兒進行開發，"
			"在操作上特別考慮到幼兒的手部協調特性，"
			"搭配精心製作的可愛風格插畫，喜歡大小朋友都喜歡！";
	static const String startTutorial = "目前本遊戲只提供拼圖，"
			"我們未來會再加入更多內容，敬請期待！";
	static const String gearTutorial = "從這邊可以進入設定頁；"
			"為了避免小朋友誤觸，這個要長壓一秒喔！";

	// PWA 安裝引導兩種文案（依瀏覽器擇一）----
	static const String pwaHintSafari =
			"如果喜歡這個應用程式，可以在「分享」選單中點選「加入主畫面」、"
			"即可安裝成為一般的應用程式喔！";
	static const String pwaHintGeneric =
			"如果喜歡這個應用程式，可以在瀏覽器選單中點選「加到主畫面」、"
			"即可安裝成為一般的應用程式喔！";
}

/// 拼圖設定頁。
class SetupStrings {
	const SetupStrings._();

	static const String startButton = "開始";

	// 教學 ----
	static const String rangeTutorial = "在這邊可以選擇拼圖片數範圍，"
			"會隨機從範圍中選一個來進行切割～";
	static const String hintTutorial = "啟用這個會顯示切割提示線，"
			"關掉的話會稍微增加難度喔！";
	static const String rotationTutorial = "啟用這個會增加旋轉的維度，"
			"會更加提昇難度喔！";
	static const String screenLockTutorial = "啟用這個會鎖定應用程式，"
			"在部份手機上有助於避免幼兒誤觸系統返回～";
	static const String cutModeTutorial = "這邊可以選擇不同的切割模式，"
			"不規則型的形狀提示較明顯，對許多幼兒來說反而比較容易喔～";
	static const String cutModeRequired = "這邊至少要選一種喔！";

	// 卡片標題 / 控制標籤 ----
	static const String rangeTitle = "選擇拼圖片數範圍";
	static const String showHintLabel = "顯示提示線";
	static const String rotationLabel = "旋轉";
	static const String screenLockLabel = "鎖定畫面";
	static const String cutModeGrid = "方格";
	static const String cutModeVoronoi = "不規則";
}

/// 拼圖遊戲畫面。
class PuzzleStrings {
	const PuzzleStrings._();

	static const String noGalleryTitle = "沒有可用的圖庫";
	static const String noGalleryDesc = "請先在「家長區 → 圖庫管理」"
			"勾選或新增至少一套含圖片的圖庫。";
	static const String ok = "好";

	static const String tutorial = "將拼片逐一放回左邊的框中以完成拼圖。"
			"長壓右上角的關閉圖示即可退出"
			"（為了避免誤觸，必須先將附近的拼片移開、圖示才會出現喔～）";

	static const String levelComplete = "你完成囉！";
	static const String nextLevel = "點這裡進入下一關";

	/// 斷網 + 已下載內建圖 < 20 張 時、進入拼圖前提示（每 session 一次）。
	static const String needNetworkTitle = "目前是離線模式";
	static const String needNetworkBody = "請開啟網路，以載入更多圖片喔！";
}

/// 家長區。
class ParentStrings {
	const ParentStrings._();

	static const String homeTitle = "家長區";
	static const String sectionContent = "內容";
	static const String sectionSystem = "系統";

	static const String gallery = "圖庫管理";
	static const String gallerySubtitle = "一套一套組織內建與自訂圖庫";
	static const String sprites = "素材管理";
	static const String spritesSubtitle = "選擇遊戲中使用的素材分類";
	static const String spritesDetailTitle = "預覽素材";
	static const String spritesNoneSelected =
			"目前沒有勾選任何分類，使用素材的遊戲將無法進行";

	static const String audio = "音效";
	static const String audioSubtitle = "點擊、拖曳、過關等";
	static const String voice = "語音提示";
	static const String voiceSubtitle = "素材名稱朗讀、以及關卡進入 / 過關鼓勵";

	static const String resetTutorial = "重新觀看教學";
	static const String resetTutorialSubtitle = "清除所有教學的「已看過」紀錄";
	static const String resetTutorialConfirmTitle = "重新觀看教學？";
	static const String resetTutorialConfirmBody =
			"將會清除所有教學的「已看過」紀錄，"
			"下次進入相關畫面時會再次播放。";
	static const String resetTutorialConfirmOk = "確定重設";
	static const String resetTutorialConfirmCancel = "取消";
	static const String resetTutorialDone = "已重設教學，下次進入相關畫面會再次顯示。";

	static const String bigKidMode = "大朋友模式";
	static const String bigKidModeSubtitle =
			"片數 20~300、邊框變細、不再需要長按";

	static const String tipJar = "請作者喝咖啡";
	static const String tipJarSubtitle = "自由打賞～";
	static const String tipJarUrl = "https://buymeacoffee.com/mutsuntsai";

	// 設定備份 ----
	static const String backup = "設定備份";
	static const String backupSubtitle = "匯出 / 匯入所有設定與自訂圖庫";
	static const String backupTitle = "設定備份";
	static const String backupExport = "匯出設定";
	static const String backupExportSubtitle =
			"把目前的所有設定與自訂圖庫存成單一檔案";
	static const String backupImport = "匯入設定";
	static const String backupImportSubtitle =
			"從之前匯出的檔案還原設定";
	static const String backupExportDone = "已匯出備份檔";
	static const String backupExportFailed = "匯出失敗：";
	static const String backupImportFailed = "匯入失敗：";
	static const String backupImportFailedNoBytes =
			"無法讀取所選檔案內容";
	static const String backupImportDoneReplace =
			"已匯入備份（覆蓋模式），設定與圖庫已全部替換";
	static const String backupImportDoneMerge =
			"已匯入備份（新增模式），圖庫已合併";
	static const String backupCancelled = "已取消";
	static const String backupCancel = "取消";
	static const String backupModeTitle = "選擇匯入模式";
	static const String backupModeBodyPrefix = "備份檔包含 ";
	static const String backupModeBodyMid = " 個自訂圖庫、共 ";
	static const String backupModeBodySuffix =
			" 張圖。\n\n"
			"「覆蓋」會清掉目前所有自訂圖庫與設定、換成備份檔的內容。\n"
			"「新增」只把圖庫依名稱合併進來，設定與教學紀錄不會被動到。";
	static const String backupModeReplace = "覆蓋";
	static const String backupModeMerge = "新增";
}

/// 圖庫管理列表頁。
class GalleryStrings {
	const GalleryStrings._();

	static const String title = "圖庫管理";
	static const String addGallery = "新增圖庫";
	static const String customGallery = "自訂圖庫";
	static const String galleryName = "圖庫名稱";
	static const String cancel = "取消";
	static const String confirm = "確定";
	static const String builtin = "內建";
	static const String custom = "自訂";
	static const String menu = "選單";
	static const String rename = "重新命名";
	static const String deleteSet = "刪除整套";
	static const String deleteSetPrompt = "刪除整套？";
	static const String imagesUnit = "張圖";
	static const String delete = "刪除";
	static const String deleteSetDesc1 = "確定要刪除「";
	static const String deleteSetDesc2 = "」與其中 ";
	static const String deleteSetDesc3 = " 張圖嗎？此操作無法復原。";
	static const String separator = "．";
}

/// 圖庫內容頁。
class GalleryDetailStrings {
	const GalleryDetailStrings._();

	static const String title = "圖庫";
	static const String missingId = "未指定圖庫 id";
	static const String notFound = "找不到此圖庫";
	static const String selected = "已選取";
	static const String deleteSelected = "刪除已選取";
	static const String addImage = "新增圖片";
	static const String emptyHint = "還沒有圖片，點右上＋新增";
	static const String emptyTitle = "此圖庫沒有圖片";
	static const String importFailed = "匯入失敗：";
	static const String deletePrompt = "刪除已選取？";
	static const String deleteDesc1 = "確定要刪除 ";
	static const String deleteDesc2 = " 張圖片嗎？此操作無法復原。";
	static const String delete = "刪除";

	/// 內建圖尚未下載完成 + 目前斷網（web 限定）時的縮圖 placeholder 文字。
	static const String notDownloaded = "尚未下載";

	// 批次匯入 ----
	static const String batchDonePrefix = "已匯入 ";
	static const String batchAbortedPrefix = "已停止匯入，共匯入 ";
	static const String batchSavedSuffix = " 張";
	static const String batchSkippedSeparator = "、跳過 ";
	static const String batchSkippedSuffix = " 張";
}

/// 圖片裁切頁。
class CropStrings {
	const CropStrings._();

	static const String title = "裁切成 4:3";
	static const String done = "完成";
	static const String tooSmall = "裁切區域太小";
	static const String cropFailed = "裁切失敗";
	static const String stopBatch = "停止匯入";
}

/// 共用 widget。
class SharedStrings {
	const SharedStrings._();

	static const String parentalLockPrompt = "請輸入答案";
	static const String parentalLockFailures = "答錯次數：";
}

// ============================================================================

/// 把所有要渲染的字串串接、去重後得到的字元集合。
///
/// 給 [FontReadyProbe] 當 probeText 用：probe 會把這串字渲染成不可見 Text、
/// 量到合理寬度後 dispatch ready 訊號。第一幀前就保證整個 App 用到的字都已
/// 解碼完畢、子頁面進去時不會看到 fallback / tofu。
final String preheatCharSet = _buildPreheatCharSet();

String _buildPreheatCharSet() {
	const List<String> all = <String>[
		// HomeStrings
		HomeStrings.appTitle,
		HomeStrings.startButton,
		HomeStrings.startInsetPuzzle,
		HomeStrings.startMultiPuzzle,
		HomeStrings.welcomeMessage,
		HomeStrings.startTutorial,
		HomeStrings.gearTutorial,
		HomeStrings.pwaHintSafari,
		HomeStrings.pwaHintGeneric,
		// SetupStrings
		SetupStrings.startButton,
		SetupStrings.rangeTutorial,
		SetupStrings.hintTutorial,
		SetupStrings.rotationTutorial,
		SetupStrings.screenLockTutorial,
		SetupStrings.cutModeTutorial,
		SetupStrings.cutModeRequired,
		SetupStrings.rangeTitle,
		SetupStrings.showHintLabel,
		SetupStrings.rotationLabel,
		SetupStrings.screenLockLabel,
		SetupStrings.cutModeGrid,
		SetupStrings.cutModeVoronoi,
		// PuzzleStrings
		PuzzleStrings.noGalleryTitle,
		PuzzleStrings.noGalleryDesc,
		PuzzleStrings.ok,
		PuzzleStrings.tutorial,
		PuzzleStrings.levelComplete,
		PuzzleStrings.nextLevel,
		PuzzleStrings.needNetworkTitle,
		PuzzleStrings.needNetworkBody,
		// ParentStrings
		ParentStrings.homeTitle,
		ParentStrings.sectionContent,
		ParentStrings.sectionSystem,
		ParentStrings.gallery,
		ParentStrings.gallerySubtitle,
		ParentStrings.sprites,
		ParentStrings.spritesSubtitle,
		ParentStrings.spritesDetailTitle,
		ParentStrings.spritesNoneSelected,
		ParentStrings.audio,
		ParentStrings.audioSubtitle,
		ParentStrings.voice,
		ParentStrings.voiceSubtitle,
		ParentStrings.resetTutorial,
		ParentStrings.resetTutorialSubtitle,
		ParentStrings.resetTutorialDone,
		ParentStrings.backup,
		ParentStrings.backupSubtitle,
		ParentStrings.backupTitle,
		ParentStrings.backupExport,
		ParentStrings.backupExportSubtitle,
		ParentStrings.backupImport,
		ParentStrings.backupImportSubtitle,
		ParentStrings.backupExportDone,
		ParentStrings.backupExportFailed,
		ParentStrings.backupImportFailed,
		ParentStrings.backupImportFailedNoBytes,
		ParentStrings.backupImportDoneReplace,
		ParentStrings.backupImportDoneMerge,
		ParentStrings.backupCancelled,
		ParentStrings.backupCancel,
		ParentStrings.backupModeTitle,
		ParentStrings.backupModeBodyPrefix,
		ParentStrings.backupModeBodyMid,
		ParentStrings.backupModeBodySuffix,
		ParentStrings.backupModeReplace,
		ParentStrings.backupModeMerge,
		// GalleryStrings
		GalleryStrings.title,
		GalleryStrings.addGallery,
		GalleryStrings.customGallery,
		GalleryStrings.galleryName,
		GalleryStrings.cancel,
		GalleryStrings.confirm,
		GalleryStrings.builtin,
		GalleryStrings.custom,
		GalleryStrings.menu,
		GalleryStrings.rename,
		GalleryStrings.deleteSet,
		GalleryStrings.deleteSetPrompt,
		GalleryStrings.imagesUnit,
		GalleryStrings.delete,
		GalleryStrings.deleteSetDesc1,
		GalleryStrings.deleteSetDesc2,
		GalleryStrings.deleteSetDesc3,
		GalleryStrings.separator,
		// GalleryDetailStrings
		GalleryDetailStrings.title,
		GalleryDetailStrings.missingId,
		GalleryDetailStrings.notFound,
		GalleryDetailStrings.selected,
		GalleryDetailStrings.deleteSelected,
		GalleryDetailStrings.addImage,
		GalleryDetailStrings.emptyHint,
		GalleryDetailStrings.emptyTitle,
		GalleryDetailStrings.importFailed,
		GalleryDetailStrings.deletePrompt,
		GalleryDetailStrings.deleteDesc1,
		GalleryDetailStrings.deleteDesc2,
		GalleryDetailStrings.delete,
		GalleryDetailStrings.notDownloaded,
		GalleryDetailStrings.batchDonePrefix,
		GalleryDetailStrings.batchAbortedPrefix,
		GalleryDetailStrings.batchSavedSuffix,
		GalleryDetailStrings.batchSkippedSeparator,
		GalleryDetailStrings.batchSkippedSuffix,
		// CropStrings
		CropStrings.title,
		CropStrings.done,
		CropStrings.tooSmall,
		CropStrings.cropFailed,
		CropStrings.stopBatch,
		// SharedStrings
		SharedStrings.parentalLockPrompt,
		SharedStrings.parentalLockFailures,
		// 動態組成但會渲染的數字 / 標點 / 符號（保險起見補一些常見字元）
		"0123456789",
	];
	final Set<int> seen = <int>{};
	final StringBuffer buf = StringBuffer();
	for (final String s in all) {
		for (final int cp in s.runes) {
			if (seen.add(cp)) {
				buf.writeCharCode(cp);
			}
		}
	}
	return buf.toString();
}
