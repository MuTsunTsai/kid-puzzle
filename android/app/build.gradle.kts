import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 讀取本機 key.properties；不存在時 fallback 到環境變數（給 CI 用）
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasKeystoreFile = keystorePropertiesFile.exists()
if (hasKeystoreFile) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

fun keystoreValue(key: String, env: String): String? {
    return keystoreProperties.getProperty(key) ?: System.getenv(env)
}

val signingStoreFile = keystoreValue("storeFile", "ANDROID_KEYSTORE_PATH")
val signingStorePassword = keystoreValue("storePassword", "ANDROID_KEYSTORE_PASSWORD")
val signingKeyAlias = keystoreValue("keyAlias", "ANDROID_KEY_ALIAS")
val signingKeyPassword = keystoreValue("keyPassword", "ANDROID_KEY_PASSWORD")

val hasReleaseSigning = signingStoreFile != null &&
    signingStorePassword != null &&
    signingKeyAlias != null &&
    signingKeyPassword != null

android {
    namespace = "com.abstreamace.kidpuzzle"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.abstreamace.kidpuzzle"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                // storeFile 解析路徑：本機 key.properties 寫 keystore/kid-puzzle.jks
                // 是相對於 android/ 的；CI 走環境變數時是絕對路徑。
                storeFile = if (hasKeystoreFile) {
                    rootProject.file(signingStoreFile!!)
                } else {
                    file(signingStoreFile!!)
                }
                storePassword = signingStorePassword
                keyAlias = signingKeyAlias
                keyPassword = signingKeyPassword
            }
        }
    }

    buildTypes {
        release {
            // 有 release 簽署設定就用；沒有就 fallback 到 debug keys
            // （讓 `flutter run --release` 在沒有 keystore 的環境也能跑）
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}
