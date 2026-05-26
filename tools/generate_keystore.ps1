# 產生 Android release 簽署 keystore
#
# 用法：在專案根目錄執行
#   powershell -ExecutionPolicy Bypass -File tools\generate_keystore.ps1
#
# 產出：
#   android\keystore\kid-puzzle.jks   # 簽署金鑰本體（.gitignore 已排除）
#   android\key.properties            # 本機 Gradle 用的密碼設定（同上）
#
# 互動式輸入密碼；不會把密碼留在腳本中或印到 console。
# 重要：keystore 與密碼遺失即無法為已上架的 App 發布更新，請務必妥善備份。

$ErrorActionPreference = "Stop"

$keystoreDir = "android\keystore"
$keystorePath = "$keystoreDir\kid-puzzle.jks"
$propertiesPath = "android\key.properties"
$alias = "kid-puzzle"

if (Test-Path $keystorePath) {
	Write-Host "已存在 $keystorePath，若要重新產生請先手動刪除。" -ForegroundColor Yellow
	exit 1
}

if (-not (Test-Path $keystoreDir)) {
	New-Item -ItemType Directory -Path $keystoreDir | Out-Null
}

# 互動輸入：keystore 密碼、key 密碼（兩者可相同）、CN 資訊
Write-Host ""
Write-Host "=== Android Release Keystore 產生 ===" -ForegroundColor Cyan
Write-Host "（密碼建議至少 12 字元，請另存於密碼管理器）"
Write-Host ""

$storePassSecure = Read-Host -AsSecureString "請輸入 keystore 密碼"
$storePassConfirm = Read-Host -AsSecureString "再輸入一次確認"

# 比對兩次密碼
$bstr1 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($storePassSecure)
$bstr2 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($storePassConfirm)
$plain1 = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr1)
$plain2 = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr2)
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr1)
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr2)

if ($plain1 -ne $plain2) {
	Write-Host "兩次密碼不一致，已中止。" -ForegroundColor Red
	exit 1
}
if ($plain1.Length -lt 6) {
	Write-Host "keytool 要求密碼至少 6 字元。" -ForegroundColor Red
	exit 1
}
$storePass = $plain1

$useSameSecure = Read-Host "Key 密碼是否與 keystore 密碼相同？(Y/n)"
if ($useSameSecure -eq "" -or $useSameSecure -match "^[Yy]") {
	$keyPass = $storePass
} else {
	$keyPassSecure = Read-Host -AsSecureString "請輸入 key 密碼"
	$keyPassConfirm = Read-Host -AsSecureString "再輸入一次確認"

	$bstrA = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($keyPassSecure)
	$bstrB = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($keyPassConfirm)
	$plainA = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstrA)
	$plainB = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstrB)
	[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstrA)
	[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstrB)

	if ($plainA -ne $plainB) {
		Write-Host "兩次密碼不一致，已中止。" -ForegroundColor Red
		exit 1
	}
	if ($plainA.Length -lt 6) {
		Write-Host "keytool 要求密碼至少 6 字元。" -ForegroundColor Red
		exit 1
	}
	$keyPass = $plainA
}

# 憑證的 DN（Distinguished Name）；都填合理的預設即可，CN 用作者名
$dname = "CN=Mu-Tsun Tsai, OU=Abstreamace, O=Abstreamace, L=Taipei, ST=Taipei, C=TW"

Write-Host ""
Write-Host "產生 keystore 中..." -ForegroundColor Cyan

# keytool 透過 stdin 餵密碼，避免出現在 process arguments
# 順序：-storepass、-keypass 必須各餵一次
$keytoolArgs = @(
	"-genkeypair",
	"-v",
	"-keystore", $keystorePath,
	"-alias", $alias,
	"-keyalg", "RSA",
	"-keysize", "2048",
	"-validity", "10000",
	"-dname", $dname,
	"-storetype", "JKS",
	"-storepass", $storePass,
	"-keypass", $keyPass
)

& keytool @keytoolArgs

if ($LASTEXITCODE -ne 0) {
	Write-Host "keytool 失敗。" -ForegroundColor Red
	exit 1
}

# 寫 key.properties 給本機 Gradle 用
# 密碼以明文存在本機檔（已加入 .gitignore），CI 則改走環境變數
$propertiesContent = @"
storePassword=$storePass
keyPassword=$keyPass
keyAlias=$alias
storeFile=keystore/kid-puzzle.jks
"@
Set-Content -Path $propertiesPath -Value $propertiesContent -Encoding utf8

Write-Host ""
Write-Host "完成。產出檔案：" -ForegroundColor Green
Write-Host "  - $keystorePath"
Write-Host "  - $propertiesPath"
Write-Host ""
Write-Host "下一步（GitHub Actions 用）：" -ForegroundColor Cyan
Write-Host "  1. 將 keystore base64 化："
Write-Host "       [Convert]::ToBase64String([IO.File]::ReadAllBytes('$keystorePath')) | Set-Clipboard"
Write-Host "     之後到 GitHub repo Settings → Secrets and variables → Actions 新增："
Write-Host "       ANDROID_KEYSTORE_BASE64  ← 貼上剪貼簿內容"
Write-Host "       ANDROID_KEYSTORE_PASSWORD ← keystore 密碼"
Write-Host "       ANDROID_KEY_PASSWORD ← key 密碼"
Write-Host "       ANDROID_KEY_ALIAS ← $alias"
Write-Host ""
Write-Host "請務必把 keystore 與密碼備份到密碼管理器，遺失將無法為 App 發布更新。" -ForegroundColor Yellow
