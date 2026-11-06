// 嵌入拼圖凹槽不重疊的回歸測試：用真實 sprite 素材、在手機 / 桌機尺寸畫面
// 跑 newLevel，再用真實 alpha 像素檢查凹槽之間有無重疊。
// 背景：0.3.1 前斥力未與 tile 等比例、手機上凹槽經常重疊。

import "dart:math";
import "dart:ui" as ui;

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:kid_puzzle/core/sprites/sprite_manifest.dart";
import "package:kid_puzzle/core/sprites/sprite_registry.dart";
import "package:kid_puzzle/features/inset_puzzle/domain/inset_piece.dart";
import "package:kid_puzzle/features/inset_puzzle/presentation/inset_puzzle_controller.dart";
import "package:kid_puzzle/features/puzzle/presentation/puzzle_controller.dart"
		show PuzzleStageLayout;

/// 兩片凹槽真實 alpha（> 32）重疊的 stage-pixel 數。
int _realOverlap(SpriteRegistry reg, SpriteSheet sheet, InsetPiece a, InsetPiece b) {
	final ui.Rect inter = a.slotRect.intersect(b.slotRect);
	if (inter.isEmpty || inter.width <= 0 || inter.height <= 0) return 0;
	int count = 0;
	for (double y = inter.top; y < inter.bottom; y += 1) {
		for (double x = inter.left; x < inter.right; x += 1) {
			if (_alpha(reg, sheet, a, x, y) > 32 && _alpha(reg, sheet, b, x, y) > 32) {
				count++;
			}
		}
	}
	return count;
}

int _alpha(SpriteRegistry reg, SpriteSheet sheet, InsetPiece p, double x, double y) {
	final ui.Rect r = p.slotRect;
	final int lx = ((x - r.left) / r.width * sheet.tile).floor();
	final int ly = ((y - r.top) / r.height * sheet.tile).floor();
	if (lx < 0 || ly < 0 || lx >= sheet.tile || ly >= sheet.tile) return 0;
	return reg.alphaInItemLocal(p.item, lx, ly);
}

void main() {
	TestWidgetsFlutterBinding.ensureInitialized();

	testWidgets("嵌入拼圖：手機尺寸下凹槽不重疊", (WidgetTester tester) async {
		await tester.runAsync(() async {
			final SpriteRegistry reg = SpriteRegistry();
			await reg.load();
			const List<Size> sizes = <Size>[
				Size(844, 390), // iPhone 橫向
				Size(915, 412), // Android 橫向
				Size(1280, 640), // 桌機
			];
			const int trialsPerCase = 3;
			int bad = 0;
			for (final SpriteCategory cat in reg.categories) {
				final List<SpriteItem> all = cat.items;
				for (int n = 2; n <= 12; n++) {
				for (final Size size in sizes) {
					for (int t = 0; t < trialsPerCase; t++) {
						final int seed = cat.id.hashCode ^ (t * 7919) ^ size.width.toInt() ^ (n * 104729);
						final Random r = Random(seed);
						final List<SpriteItem> chosen = (List<SpriteItem>.of(all)..shuffle(r))
								.take(n)
								.toList();
						final InsetPuzzleController c = await InsetPuzzleController.newLevel(
							stageLayout: PuzzleStageLayout.forSize(size),
							registry: reg,
							category: cat,
							chosen: chosen,
							seed: seed,
						);
						int worst = 0;
						int pairs = 0;
						for (int i = 0; i < c.pieces.length; i++) {
							for (int j = i + 1; j < c.pieces.length; j++) {
								final int ov = _realOverlap(reg, cat.sheet, c.pieces[i], c.pieces[j]);
								if (ov > 0) pairs++;
								if (ov > worst) worst = ov;
							}
						}
						if (pairs > 0) {
							bad++;
							// ignore: avoid_print
							print("OVERLAP n=$n cat=${cat.id} size=${size.width.toInt()}x"
									"${size.height.toInt()} seed=$seed pairs=$pairs worstPx=$worst "
									"tile=${c.pieces.first.slotRect.width.toStringAsFixed(1)}");
						}
						c.dispose();
					}
				}
				}
			}
			expect(bad, 0);
		});
	}, timeout: const Timeout(Duration(minutes: 10)));
}
