package com.abstreamace.kidpuzzle

import android.app.Application
import android.content.Context
import android.os.Build
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterJNI
import io.flutter.embedding.engine.loader.FlutterLoader
import java.util.concurrent.Executors

/**
 * 讓 Android 9 也用 Impeller（練習數數的 3D 需要 Flutter GPU，只能跑在 Impeller 上）。
 *
 * 引擎選渲染器時（flutter_main.cc 的 SelectedRenderingAPI）寫死「API 29 以上才用 Impeller」，
 * 否則退回 Skia。比對的 API 版本不是引擎自己讀的，而是 FlutterLoader 用 Build.VERSION.SDK_INT
 * 傳進 FlutterJNI.init 的；這個數字在引擎裡只用在這裡（其他需要 API 版本的功能會自己問系統），
 * 所以在 Android 9 上把它報成 29，就會改用 Impeller（自動選 Vulkan / OpenGL ES）。
 *
 * 實測 Galaxy A8（Android 9）用 Impeller OpenGL ES，3D 與描邊都正常。Android 8 以下沒測過，不動。
 * 要在任何東西讀取 FlutterInjector 之前換掉（plugin 的 ContentProvider 在 onCreate 之前就會
 * 初始化），所以放在 attachBaseContext。
 */
class MainApplication : Application() {

	override fun attachBaseContext(base: Context) {
		super.attachBaseContext(base)
		if (Build.VERSION.SDK_INT == Build.VERSION_CODES.P) {
			// executor 要自己給：只給 FlutterJNI 的建構子會去讀 FlutterInjector.instance() 拿預設值，
			// 一讀就不能再 setInstance（IllegalStateException）
			val executor = Executors.newCachedThreadPool { r -> Thread(r, "flutter-worker") }
			FlutterInjector.setInstance(
				FlutterInjector.Builder()
					.setExecutorService(executor)
					.setFlutterLoader(FlutterLoader(ImpellerOnPieJNI(), executor))
					.build()
			)
		}
	}

	/** 只改傳給引擎的 API 版本，其他照舊。 */
	private class ImpellerOnPieJNI : FlutterJNI() {
		override fun init(
			context: Context,
			args: Array<String>,
			bundlePath: String?,
			appStoragePath: String,
			engineCachesPath: String,
			initTimeMillis: Long,
			apiLevel: Int,
		) {
			super.init(context, args, bundlePath, appStoragePath, engineCachesPath, initTimeMillis, maxOf(apiLevel, Build.VERSION_CODES.Q))
		}
	}
}
