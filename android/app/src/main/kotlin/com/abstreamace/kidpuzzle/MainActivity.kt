package com.abstreamace.kidpuzzle

import android.app.ActivityManager
import android.content.Context
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Kid Puzzle 主 Activity。
 *
 * Method channel `kid_puzzle/system`：
 *
 * - `enableLockTask`：啟動 app pinning（畫面釘選）。
 *   首次使用 Samsung 等機型會跳系統確認對話框、由家長按確認。回 true 表示
 *   已呼叫 startLockTask；實際是否進入釘選狀態可由 [isInLockTaskMode] 查。
 * - `disableLockTask`：解除 app pinning。idempotent。**注意**：某些機型解除後
 *   會回到螢幕鎖定畫面、這是 system 行為、無法繞過。
 */
class MainActivity : FlutterActivity() {

	companion object {
		private const val CHANNEL = "kid_puzzle/system"
	}

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)
		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
			.setMethodCallHandler { call, result ->
				when (call.method) {
					"enableLockTask" -> {
						try {
							if (!isInLockTaskMode()) {
								startLockTask()
							}
							result.success(true)
						} catch (e: Throwable) {
							result.error("LOCK_TASK_FAILED", e.message, null)
						}
					}

					"disableLockTask" -> {
						try {
							if (isInLockTaskMode()) {
								stopLockTask()
							}
							result.success(true)
						} catch (e: Throwable) {
							result.error("UNLOCK_TASK_FAILED", e.message, null)
						}
					}

					else -> result.notImplemented()
				}
			}
	}

	override fun onCreate(savedInstanceState: Bundle?) {
		super.onCreate(savedInstanceState)
		// 螢幕常亮：拼圖過程不會被自動鎖屏。
		window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
	}

	/** 目前是否處於 lock task（畫面釘選）狀態。 */
	private fun isInLockTaskMode(): Boolean {
		val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
		// API 23+ 用 lockTaskModeState；舊版用 isInLockTaskMode（API 21~22）。
		// 本 app minSdk 21、所以兩段都要顧。
		return if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
			am.lockTaskModeState != ActivityManager.LOCK_TASK_MODE_NONE
		} else {
			@Suppress("DEPRECATION")
			am.isInLockTaskMode
		}
	}
}
