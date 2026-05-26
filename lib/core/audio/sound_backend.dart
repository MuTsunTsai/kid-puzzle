import "sound_backend_io.dart"
		if (dart.library.html) "sound_backend_web.dart";

/// 音訊後端抽象：給定 asset 路徑能載入並重複觸發播放。
///
/// 兩個實作：
/// - `sound_backend_io.dart`（Android / iOS native / desktop）→ audioplayers
/// - `sound_backend_web.dart`（瀏覽器，含 iOS Safari）→ Web Audio API
///
/// **為什麼分流**：iOS Safari 對 `<audio>` element 連續 setSrc / play 不同
/// 短檔的行為極不穩定 — codec 路徑切換時會吐出上一段檔的解碼雜訊（snap
/// 變敲擊聲），且 setSrc 「載入中」狀態未結束被下次播放打斷會吞音。
/// Web Audio API 把 mp3 decode 成 PCM `AudioBuffer` 一次、後續播放只是
/// `BufferSource` 節點，完全沒有 codec 切換、沒有「載入中」中間狀態。
///
/// 用 conditional import 切實作；caller 永遠只看到此介面。
abstract class SoundBackend {
	/// 工廠：依平台回傳對應實作。conditional import 把 [createSoundBackend]
	/// 換成各平台版本。
	factory SoundBackend() => createSoundBackend();

	/// 預先把 [assetPath] 解碼到記憶體，後續 [play] 才會零延遲。
	///
	/// [assetPath] 需要以 `assets/` 開頭（與 pubspec 完整路徑一致）；
	/// 失敗時靜默忽略，[play] 該 asset 也只會 no-op。
	///
	/// [allowOverlap]：是否允許同一 asset 多重觸發疊播。預設 false（同 asset
	/// 連發會打斷自己、節省資源）。設 true 時 io backend 會為該 asset 維護
	/// 一個 player pool、每次 [play] 取下一個 player 觸發、聲音可同時疊起來。
	/// Web 後端本來就疊播、此旗標只影響 io。
	Future<void> load(String assetPath, {bool allowOverlap = false});

	/// 觸發播放（fire-and-forget）。若該 asset 未載入或載入失敗，no-op。
	///
	/// [channel] 若給定（非 null）：同一 channel 上一個尚未播完的聲音會被
	/// 立刻停掉、再播新的。用來實現「立刻插播下一句語音、把舊的截掉」。
	/// channel = null（預設）：與其他播放互不影響，可同時疊播（例如多個
	/// snap 連發各自播完）。
	///
	/// [volume] 0.0 ~ 1.0；預設 1.0（原音量）。
	void play(String assetPath, {String? channel, double volume = 1.0});

	/// 清理底層資源。
	Future<void> dispose();
}
