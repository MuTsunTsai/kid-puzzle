import "../constants/asset_paths.dart";
import "sound_backend.dart";

/// 音效種類。
enum SfxKind {
	click,
	pickup,
	drop,
	snap,
	rotate,
	complete,
	error,
}

/// 音效服務：透過 [SoundBackend] 播放短促音效。實際後端依平台切換
/// （native → audioplayers；web → Web Audio API）。
///
/// [enabled] 可在執行期切換；切到 false 時 [play] 直接 return。
class AudioService {
	AudioService();

	final SoundBackend _backend = SoundBackend();
	bool enabled = true;

	/// 標記為「同 asset 可疊播」的音效。短時間內可能被連發、不應該打斷自己。
	/// 列在此 set 的 kind 在 io 平台會用 player pool（[SoundBackend.load] 旗標）；
	/// web 端本來就疊播。
	static const Set<SfxKind> _overlappingKinds = <SfxKind>{
		SfxKind.rotate,
	};

	/// 預載所有音檔。app 啟動時呼叫一次。
	Future<void> preload() async {
		for (final SfxKind kind in SfxKind.values) {
			await _backend.load(
				_assetFor(kind),
				allowOverlap: _overlappingKinds.contains(kind),
			);
		}
	}

	/// 每種音效的相對音量（asset 本身錄製音量不一致時用來校正）。
	/// 沒列出的 kind 視為 1.0（原音量）。
	static const Map<SfxKind, double> _volumes = <SfxKind, double>{
		SfxKind.pickup: 0.15,
	};

	/// 播放音效。設定關閉時 no-op。
	void play(SfxKind kind) {
		if (!enabled) return;
		_backend.play(_assetFor(kind), volume: _volumes[kind] ?? 1.0);
	}

	Future<void> dispose() => _backend.dispose();

	static String _assetFor(SfxKind kind) {
		switch (kind) {
			case SfxKind.click:
				return AssetPaths.sfxClick;
			case SfxKind.pickup:
				return AssetPaths.sfxPickup;
			case SfxKind.drop:
				return AssetPaths.sfxDrop;
			case SfxKind.snap:
				return AssetPaths.sfxSnap;
			case SfxKind.rotate:
				return AssetPaths.sfxRotate;
			case SfxKind.complete:
				return AssetPaths.sfxComplete;
			case SfxKind.error:
				return AssetPaths.sfxError;
		}
	}
}
