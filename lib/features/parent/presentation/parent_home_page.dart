import "package:flutter/material.dart";
import "package:provider/provider.dart";

import "../../../core/audio/audio_service.dart";
import "../../../core/audio/voice_service.dart";
import "../../../core/constants/app_colors.dart";
import "../../../core/routing/app_router.dart";
import "../../../core/storage/settings_repository.dart";
import "../../../shared/widgets/click_sound.dart";

/// 家長區首頁：音效 / TTS 開關，以及圖庫入口（M8 之後）。
///
/// 必須先通過 [ParentalLockDialog] 才能進來；本頁不再加鎖。
class ParentHomePage extends StatefulWidget {
	const ParentHomePage({super.key});

	@override
	State<ParentHomePage> createState() => _ParentHomePageState();
}

class _ParentHomePageState extends State<ParentHomePage> {
	bool _audioEnabled = true;
	bool _ttsEnabled = true;
	bool _loaded = false;

	@override
	void didChangeDependencies() {
		super.didChangeDependencies();
		if (_loaded) return;
		_loaded = true;
		final SettingsRepository repo = context.read<SettingsRepository>();
		setState(() {
			_audioEnabled = repo.audioEnabled;
			_ttsEnabled = repo.ttsEnabled;
		});
	}

	@override
	Widget build(BuildContext context) {
		return Scaffold(
			appBar: AppBar(
				title: const Text("家長區"),
				backgroundColor: AppColors.primary,
				foregroundColor: Colors.white,
			),
			body: ListView(
				padding: const EdgeInsets.symmetric(vertical: 8),
				children: <Widget>[
					_SectionTitle(text: "音效"),
					SwitchListTile(
						title: const Text("音效"),
						subtitle: const Text("點擊、拖曳、過關等音效"),
						value: _audioEnabled,
						onChanged: (bool v) {
							setState(() => _audioEnabled = v);
							context.read<AudioService>().enabled = v;
							context.read<SettingsRepository>().setAudioEnabled(v);
						},
					),
					SwitchListTile(
						title: const Text("語音提示"),
						subtitle: const Text("進關卡 / 過關的語音鼓勵"),
						value: _ttsEnabled,
						onChanged: (bool v) {
							setState(() => _ttsEnabled = v);
							context.read<VoiceService>().enabled = v;
							context.read<SettingsRepository>().setTtsEnabled(v);
						},
					),
					const Divider(),
					_SectionTitle(text: "內容"),
					ListTile(
						leading: const Icon(Icons.collections),
						title: const Text("圖庫管理"),
						subtitle: const Text("一套一套組織內建與自訂圖庫"),
						trailing: const Icon(Icons.chevron_right),
						onTap: ClickSound.wrap(
							context,
							() => Navigator.of(context).pushNamed(AppRoutes.parentGallery),
						),
					),
				],
			),
		);
	}
}

class _SectionTitle extends StatelessWidget {
	const _SectionTitle({required this.text});

	final String text;

	@override
	Widget build(BuildContext context) {
		return Padding(
			padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
			child: Text(
				text,
				style: const TextStyle(
					fontSize: 14,
					fontWeight: FontWeight.bold,
					color: AppColors.primary,
				),
			),
		);
	}
}
