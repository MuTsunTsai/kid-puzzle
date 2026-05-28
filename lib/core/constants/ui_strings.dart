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
}

/// 家長區。
class ParentStrings {
	const ParentStrings._();

	static const String homeTitle = "家長區";
	static const String sectionContent = "內容";
	static const String sectionSystem = "系統";

	static const String gallery = "圖庫管理";
	static const String gallerySubtitle = "一套一套組織內建與自訂圖庫";

	static const String audio = "音效";
	static const String audioSubtitle = "點擊、拖曳、過關等";
	static const String voice = "語音提示";
	static const String voiceSubtitle = "進關卡 / 過關的鼓勵";

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
}

/// 圖片裁切頁。
class CropStrings {
	const CropStrings._();

	static const String title = "裁切成 4:3";
	static const String done = "完成";
	static const String tooSmall = "裁切區域太小";
	static const String cropFailed = "裁切失敗";
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
		// ParentStrings
		ParentStrings.homeTitle,
		ParentStrings.sectionContent,
		ParentStrings.sectionSystem,
		ParentStrings.gallery,
		ParentStrings.gallerySubtitle,
		ParentStrings.audio,
		ParentStrings.audioSubtitle,
		ParentStrings.voice,
		ParentStrings.voiceSubtitle,
		ParentStrings.resetTutorial,
		ParentStrings.resetTutorialSubtitle,
		ParentStrings.resetTutorialDone,
		// GalleryStrings
		GalleryStrings.title,
		GalleryStrings.addGallery,
		GalleryStrings.customGallery,
		GalleryStrings.galleryName,
		GalleryStrings.cancel,
		GalleryStrings.confirm,
		GalleryStrings.builtin,
		GalleryStrings.custom,
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
		// CropStrings
		CropStrings.title,
		CropStrings.done,
		CropStrings.tooSmall,
		CropStrings.cropFailed,
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
