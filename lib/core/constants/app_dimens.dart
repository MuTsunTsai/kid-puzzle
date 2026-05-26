/// 跨單元共用的尺寸 / 行為常數。
///
/// 單一單元（拼圖、未來的配對 / 找不同 …）專用常數請放各自 `features/<name>/`
/// 下的 dimens 檔。這裡只收「會被多個單元同時引用」的東西。
class AppDimens {
	AppDimens._();

	/// 首頁齒輪長按時間（秒）— 進入家長區前的安全鎖。
	static const int gearLongPressSeconds = 1;

	/// 家長鎖最大連續錯誤次數 — 達到後直接關閉 dialog。
	static const int maxParentLockFailures = 3;
}
