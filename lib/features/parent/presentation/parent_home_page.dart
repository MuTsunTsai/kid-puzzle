import "package:flutter/material.dart";
import "package:provider/provider.dart";

import "../../../core/analytics/analytics_service.dart";
import "../../../core/audio/audio_service.dart";
import "../../../core/audio/voice_service.dart";
import "../../../core/constants/app_colors.dart";
import "../../../core/constants/ui_strings.dart";
import "../../../core/routing/app_router.dart";
import "../../../core/storage/settings_repository.dart";
import "../../../core/system/interop.dart";
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
	bool _bigKidMode = false;
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
			_bigKidMode = repo.bigKidMode;
		});
	}

	@override
	Widget build(BuildContext context) {
		return Scaffold(
			appBar: AppBar(
				title: const Text(ParentStrings.homeTitle),
				backgroundColor: AppColors.primary,
				foregroundColor: Colors.white,
			),
			body: Center(
				// 限制內容寬度避免在桌機 / 平板橫向過寬、視覺配對失焦。
				child: ConstrainedBox(
					constraints: const BoxConstraints(maxWidth: 480),
					child: ListView(
						padding: const EdgeInsets.symmetric(vertical: 8),
						children: <Widget>[
							_SectionTitle(text: ParentStrings.sectionContent),
							ListTile(
								leading: const Icon(Icons.collections),
								title: const Text(ParentStrings.gallery),
								subtitle: const Text(ParentStrings.gallerySubtitle),
								trailing: const Icon(Icons.chevron_right),
								onTap: ClickSound.wrap(
									context,
									() => Navigator.of(context).pushNamed(AppRoutes.parentGallery),
								),
							),
							const Divider(),
							_SectionTitle(text: ParentStrings.sectionSystem),
							SwitchListTile(
								secondary: const Icon(Icons.volume_up),
								title: const Text(ParentStrings.audio),
								subtitle: const Text(ParentStrings.audioSubtitle),
								value: _audioEnabled,
								onChanged: (bool v) {
									setState(() => _audioEnabled = v);
									context.read<AudioService>().enabled = v;
									context.read<SettingsRepository>().setAudioEnabled(v);
								},
							),
							SwitchListTile(
								secondary: const Icon(Icons.record_voice_over),
								title: const Text(ParentStrings.voice),
								subtitle: const Text(ParentStrings.voiceSubtitle),
								value: _ttsEnabled,
								onChanged: (bool v) {
									setState(() => _ttsEnabled = v);
									context.read<VoiceService>().enabled = v;
									context.read<SettingsRepository>().setTtsEnabled(v);
								},
							),
							SwitchListTile(
								secondary: const Icon(Icons.escalator_warning),
								title: const Text(ParentStrings.bigKidMode),
								subtitle: const Text(ParentStrings.bigKidModeSubtitle),
								value: _bigKidMode,
								onChanged: (bool v) {
									setState(() => _bigKidMode = v);
									context.read<SettingsRepository>().setBigKidMode(v);
									AnalyticsService.instance
											.logBigKidModeToggled(enabled: v);
								},
							),
							ListTile(
								leading: const Icon(Icons.school_outlined),
								title: const Text(ParentStrings.resetTutorial),
								subtitle: const Text(ParentStrings.resetTutorialSubtitle),
								onTap: ClickSound.wrap(context, _resetTutorials),
							),
							ListTile(
								leading: const Icon(Icons.coffee),
								title: const Text(ParentStrings.tipJar),
								subtitle: const Text(ParentStrings.tipJarSubtitle),
								trailing: const Icon(Icons.open_in_new),
								onTap: ClickSound.wrap(
									context,
									() {
										AnalyticsService.instance.logTipJarOpened();
										openExternalUrl(ParentStrings.tipJarUrl);
									},
								),
							),
						],
					),
				),
			),
		);
	}

	Future<void> _resetTutorials() async {
		final bool? confirmed = await showDialog<bool>(
			context: context,
			builder: (BuildContext ctx) => AlertDialog(
				title: const Text(ParentStrings.resetTutorialConfirmTitle),
				content: const Text(ParentStrings.resetTutorialConfirmBody),
				actions: <Widget>[
					TextButton(
						onPressed: ClickSound.wrap(
							ctx,
							() => Navigator.of(ctx).pop(false),
						),
						child: const Text(ParentStrings.resetTutorialConfirmCancel),
					),
					TextButton(
						onPressed: ClickSound.wrap(
							ctx,
							() => Navigator.of(ctx).pop(true),
						),
						child: const Text(ParentStrings.resetTutorialConfirmOk),
					),
				],
			),
		);
		if (confirmed != true) return;
		if (!mounted) return;
		AnalyticsService.instance.logResetTutorials();
		final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
		await context.read<SettingsRepository>().resetAllTutorials();
		if (!mounted) return;
		messenger.showSnackBar(
			const SnackBar(
				content: Text(ParentStrings.resetTutorialDone),
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
