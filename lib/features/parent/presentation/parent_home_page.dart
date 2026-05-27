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
					const Divider(),
					_SectionTitle(text: "系統"),
					// 音效 / 語音提示並排在同一列、各佔一半寬度
					Row(
						crossAxisAlignment: CrossAxisAlignment.start,
						children: <Widget>[
							Expanded(
								child: SwitchListTile(
									title: const Text("音效"),
									subtitle: const Text("點擊、拖曳、過關等"),
									value: _audioEnabled,
									controlAffinity: ListTileControlAffinity.leading,
									onChanged: (bool v) {
										setState(() => _audioEnabled = v);
										context.read<AudioService>().enabled = v;
										context.read<SettingsRepository>().setAudioEnabled(v);
									},
								),
							),
							Expanded(
								child: SwitchListTile(
									title: const Text("語音提示"),
									subtitle: const Text("進關卡 / 過關的鼓勵"),
									value: _ttsEnabled,
									controlAffinity: ListTileControlAffinity.leading,
									onChanged: (bool v) {
										setState(() => _ttsEnabled = v);
										context.read<VoiceService>().enabled = v;
										context.read<SettingsRepository>().setTtsEnabled(v);
									},
								),
							),
						],
					),
					ListTile(
						leading: const Icon(Icons.school_outlined),
						title: const Text("重新觀看教學"),
						subtitle: const Text("清除所有教學的「已看過」紀錄"),
						onTap: ClickSound.wrap(context, _resetTutorials),
					),
				],
			),
		);
	}

	Future<void> _resetTutorials() async {
		final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
		await context.read<SettingsRepository>().resetAllTutorials();
		if (!mounted) return;
		messenger.showSnackBar(
			const SnackBar(
				content: Text("已重設教學，下次進入相關畫面會再次顯示。"),
				duration: Duration(seconds: 2),
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
