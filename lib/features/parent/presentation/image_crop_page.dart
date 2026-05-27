import "dart:async";
import "dart:ui" as ui;

import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:image/image.dart" as img;

import "../../../core/constants/ui_strings.dart";
import "../../../shared/widgets/click_sound.dart";

/// 進入 [ImageCropPage] 的引數。
class ImageCropArguments {
	const ImageCropArguments({required this.sourceBytes});

	/// 原始圖 bytes（任何 [img.decodeImage] 接受的格式）。
	final Uint8List sourceBytes;
}

/// 自製 4:3 裁切頁。
///
/// 平台無關（純 Flutter），所以 web/Android/iOS 共用同一份 UI。
///
/// **流程**
/// 1. 解碼原圖 → `ui.Image` 顯示在 [InteractiveViewer] 內，可平移縮放。
/// 2. 中央覆蓋固定 4:3 裁切框（畫面短邊 90%）；框外有半透明遮罩。
/// 3. `minScale` 動態 = 圖完全覆蓋裁切框的最小 scale，避免漏白。
/// 4. 「完成」→ 把裁切框 4 角從 viewer 局部座標反向 transform 回圖座標 →
///    用 `image` 套件 crop + 縮 + 重編 → Navigator.pop(Uint8List)。
class ImageCropPage extends StatefulWidget {
	const ImageCropPage({super.key});

	@override
	State<ImageCropPage> createState() => _ImageCropPageState();
}

class _ImageCropPageState extends State<ImageCropPage> {
	/// 解碼後的原圖；裁切時用 [_rawBytes] + 計算出的整數座標再做一次。
	ui.Image? _image;
	Uint8List? _rawBytes;

	final TransformationController _transform = TransformationController();

	/// 由 LayoutBuilder 算出的裁切框（在整個 body 的座標系內）。
	Rect? _cropRect;
	Size? _viewerSize;

	/// 圖在 InteractiveViewer 內 child 的尺寸（identity transform 時剛好 cover
	/// 裁切框）。圖座標 (image pixel) → child 座標：乘 [_imgToChildScale]。
	Size? _childSize;
	double _imgToChildScale = 1;

	bool _initialized = false;
	bool _processing = false;

	/// 拖曳中是否該顯示 snap 輔助線（X 軸對齊圖中心 / Y 軸對齊圖中心）。
	bool _showSnapX = false;
	bool _showSnapY = false;

	@override
	void didChangeDependencies() {
		super.didChangeDependencies();
		if (_initialized) return;
		_initialized = true;
		final Object? args = ModalRoute.of(context)?.settings.arguments;
		if (args is ImageCropArguments) {
			_load(args.sourceBytes);
		}
	}

	Future<void> _load(Uint8List bytes) async {
		_rawBytes = bytes;
		final ui.Codec codec = await ui.instantiateImageCodec(bytes);
		final ui.FrameInfo frame = await codec.getNextFrame();
		if (!mounted) {
			frame.image.dispose();
			return;
		}
		setState(() {
			_image = frame.image;
		});
	}

	@override
	void dispose() {
		_image?.dispose();
		_transform.dispose();
		super.dispose();
	}

	@override
	Widget build(BuildContext context) {
		return Scaffold(
			backgroundColor: Colors.black,
			appBar: AppBar(
				backgroundColor: Colors.black,
				foregroundColor: Colors.white,
				title: const Text(CropStrings.title),
				actions: <Widget>[
					TextButton(
						onPressed: _processing
								? null
								: ClickSound.wrap(context, _onConfirm),
						child: const Text(
							CropStrings.done,
							style: TextStyle(
								color: Colors.white,
								fontSize: 16,
								fontWeight: FontWeight.bold,
							),
						),
					),
				],
			),
			body: _image == null
					? const Center(
							child: CircularProgressIndicator(color: Colors.white),
						)
					: LayoutBuilder(
							builder: (BuildContext ctx, BoxConstraints constraints) {
								final Size size = Size(
									constraints.maxWidth,
									constraints.maxHeight,
								);
								_recomputeLayout(size);
								return _buildBody();
							},
						),
		);
	}

	void _recomputeLayout(Size viewerSize) {
		final bool sizeChanged = _viewerSize != viewerSize;
		_viewerSize = viewerSize;

		// 裁切框：畫面短邊 90% 寬、嚴格 4:3。
		const double margin = 0.10;
		final double maxW = viewerSize.width * (1 - margin);
		final double maxH = viewerSize.height * (1 - margin);
		double w, h;
		if (maxW / maxH >= 4 / 3) {
			h = maxH;
			w = h * 4 / 3;
		} else {
			w = maxW;
			h = w * 3 / 4;
		}
		final Rect cropRect = Rect.fromLTWH(
			(viewerSize.width - w) / 2,
			(viewerSize.height - h) / 2,
			w,
			h,
		);
		_cropRect = cropRect;

		// child（圖）尺寸：identity transform 下剛好 cover 裁切框。
		// 這樣 InteractiveViewer 預設「child 至少覆蓋 viewport」的邊界規則
		// 就會自然保證圖永遠覆蓋裁切框。
		final ui.Image image = _image!;
		final double iw = image.width.toDouble();
		final double ih = image.height.toDouble();
		final double imgAspect = iw / ih;
		final double cropAspect = w / h;
		double cw, ch;
		if (imgAspect >= cropAspect) {
			// 圖較寬：高填滿、寬延伸超出
			ch = h;
			cw = h * imgAspect;
		} else {
			// 圖較高：寬填滿、高延伸超出
			cw = w;
			ch = w / imgAspect;
		}
		_childSize = Size(cw, ch);
		// 1 image pixel = imgToChildScale child 邏輯點
		_imgToChildScale = cw / iw;

		// 初始 transform：把圖中心對齊裁切框中心（scale=1 cover）。
		// 只在第一次或 viewer 尺寸改變時重置；使用者已調整過的位置不被覆蓋。
		if (sizeChanged) {
			final Matrix4 init = Matrix4.identity()
				..setEntry(0, 3, w / 2 - cw / 2)
				..setEntry(1, 3, h / 2 - ch / 2);
			// 在 build 期間直接 set value 可能跟 build flow 衝突，延後到 frame 後。
			WidgetsBinding.instance.addPostFrameCallback((_) {
				if (mounted) _transform.value = init;
			});
		}
	}

	Widget _buildBody() {
		final Rect crop = _cropRect!;
		final Size viewerSize = _viewerSize!;
		final ui.Image image = _image!;
		final Size childSize = _childSize!;

		return Stack(
			children: <Widget>[
				// 底層：在「裁切框外的整張畫布」也畫上圖（隨 transform 同步），
				// 這樣裁切框外就能看到圖、再讓上面遮罩去暗化它，呈現「框外較暗」效果。
				// 用 IgnorePointer 確保 input 由上方真正的 InteractiveViewer 處理。
				Positioned.fill(
					child: IgnorePointer(
						child: AnimatedBuilder(
							animation: _transform,
							builder: (BuildContext ctx, Widget? _) {
								return CustomPaint(
									painter: _BackgroundImagePainter(
										image: image,
										cropRect: crop,
										childSize: childSize,
										transform: _transform.value,
									),
								);
							},
						),
					),
				),

				// 裁切框內的互動層：InteractiveViewer 嚴格放在裁切框位置。
				Positioned.fromRect(
					rect: crop,
					child: ClipRect(
						child: InteractiveViewer(
							transformationController: _transform,
							minScale: 1.0,
							maxScale: 4.0,
							boundaryMargin: EdgeInsets.zero,
							constrained: false,
							onInteractionUpdate: _onInteractionUpdate,
							onInteractionEnd: _onInteractionEnd,
							child: SizedBox(
								width: childSize.width,
								height: childSize.height,
								child: CustomPaint(
									painter: _ImagePainter(image: image),
								),
							),
						),
					),
				),

				// 遮罩 + 裁切框邊線 +（拖曳中）snap 中心輔助線。
				Positioned.fill(
					child: IgnorePointer(
						child: CustomPaint(
							painter: _CropMaskPainter(
								viewerSize: viewerSize,
								cropRect: crop,
								showSnapX: _showSnapX,
								showSnapY: _showSnapY,
							),
						),
					),
				),

				if (_processing)
					const Positioned.fill(
						child: ColoredBox(
							color: Colors.black54,
							child: Center(
								child: CircularProgressIndicator(color: Colors.white),
							),
						),
					),
			],
		);
	}

	/// 容差：viewport 局部座標下，距「圖中心對齊裁切框中心」多少 px 內視為 snap。
	static const double _snapTolerancePx = 8;

	/// 拖曳/縮放中：若任一軸進入容差，立即把該軸的 tx/ty 強制改寫成中心對齊
	/// （等於「黏」到中心），並顯示黃色輔助線；要拖出該軸的 snap 必須累積位移
	/// 再次超過容差。
	void _onInteractionUpdate(ScaleUpdateDetails details) {
		final _SnapStatus s = _computeSnapStatus();
		if (s.snapX || s.snapY) {
			final Rect crop = _cropRect!;
			final Size childSize = _childSize!;
			final double scale = _transform.value.getMaxScaleOnAxis();
			final Matrix4 cur = _transform.value.clone();
			if (s.snapX) {
				// 目標：viewport 中心對應到 child.width/2。
				// viewport.x = scale * child.x + tx → 設 viewport=cropW/2、child=childW/2：
				// tx' = cropW/2 - scale * childW/2
				cur.setEntry(0, 3, crop.width / 2 - scale * childSize.width / 2);
			}
			if (s.snapY) {
				cur.setEntry(1, 3, crop.height / 2 - scale * childSize.height / 2);
			}
			_transform.value = cur;
		}
		if (s.snapX != _showSnapX || s.snapY != _showSnapY) {
			setState(() {
				_showSnapX = s.snapX;
				_showSnapY = s.snapY;
			});
		}
	}

	/// 放開時：清掉輔助線。
	void _onInteractionEnd(ScaleEndDetails details) {
		if (_showSnapX || _showSnapY) {
			setState(() {
				_showSnapX = false;
				_showSnapY = false;
			});
		}
	}

	/// 用當前 transform 計算「viewport 中心」對應的 child 座標，與 child 中心
	/// 比對；任一軸距離 ≤ tolerance 視為將要 snap。容差用 viewport px 單位。
	_SnapStatus _computeSnapStatus() {
		final Rect? crop = _cropRect;
		final Size? childSize = _childSize;
		if (crop == null || childSize == null) {
			return const _SnapStatus(snapX: false, snapY: false);
		}
		final Matrix4 m = Matrix4.inverted(_transform.value);
		final Offset viewportCenter = Offset(crop.width / 2, crop.height / 2);
		final Offset childCenter =
				MatrixUtils.transformPoint(m, viewportCenter);
		final double scale = _transform.value.getMaxScaleOnAxis();
		// 距離換算回 viewport px：dx(child) * scale = dx(viewport)
		final double dxViewport =
				(childCenter.dx - childSize.width / 2).abs() * scale;
		final double dyViewport =
				(childCenter.dy - childSize.height / 2).abs() * scale;
		return _SnapStatus(
			snapX: dxViewport <= _snapTolerancePx,
			snapY: dyViewport <= _snapTolerancePx,
		);
	}

	Future<void> _onConfirm() async {
		final Rect? crop = _cropRect;
		final ui.Image? image = _image;
		final Uint8List? raw = _rawBytes;
		if (crop == null || image == null || raw == null) return;

		setState(() => _processing = true);

		// _transform.value 是 child（圖 widget）座標 ↔ viewport（= cropRect 局部
		// 座標、左上角 (0,0)）的轉換。我們要算「裁切框可見區域」在 image 像素的位置。
		//
		// viewport 局部座標：(0, 0) 到 (cropW, cropH)。
		// 反向 transform → child 座標。
		// child 座標 → image pixel：除以 _imgToChildScale。
		final Matrix4 m = Matrix4.inverted(_transform.value);
		final Offset tlChild = MatrixUtils.transformPoint(m, Offset.zero);
		final Offset brChild = MatrixUtils.transformPoint(
			m,
			Offset(crop.width, crop.height),
		);
		final Rect imgRect = Rect.fromLTRB(
			tlChild.dx / _imgToChildScale,
			tlChild.dy / _imgToChildScale,
			brChild.dx / _imgToChildScale,
			brChild.dy / _imgToChildScale,
		);

		// 夾擠到圖範圍內
		final int x = imgRect.left.clamp(0, image.width - 1).round();
		final int y = imgRect.top.clamp(0, image.height - 1).round();
		final int rawW = imgRect.width.round();
		final int rawH = imgRect.height.round();
		final int w = (x + rawW > image.width) ? image.width - x : rawW;
		final int h = (y + rawH > image.height) ? image.height - y : rawH;

		if (w < 8 || h < 8) {
			if (!mounted) return;
			setState(() => _processing = false);
			ScaffoldMessenger.of(context).showSnackBar(
				const SnackBar(content: Text(CropStrings.tooSmall)),
			);
			return;
		}

		final Uint8List? out =
				await compute<_CropJob, Uint8List?>(_cropInIsolate, _CropJob(
			raw: raw,
			x: x,
			y: y,
			w: w,
			h: h,
		));

		if (!mounted) return;
		if (out == null) {
			setState(() => _processing = false);
			ScaffoldMessenger.of(context).showSnackBar(
				const SnackBar(content: Text(CropStrings.cropFailed)),
			);
			return;
		}
		Navigator.of(context).pop(out);
	}
}

/// Snap 偵測結果（每軸是否進入容差）。
class _SnapStatus {
	const _SnapStatus({required this.snapX, required this.snapY});
	final bool snapX;
	final bool snapY;
}

/// 底層暗化用：把整張圖按當前 transform 畫到整個畫面上（含裁切框外的部分）。
///
/// 同步機制：caller 用 `AnimatedBuilder(animation: _transform)` 包這個 painter，
/// 並把當前 `transform` 傳進來。painter 內把 transform（在裁切框局部座標系內定義）
/// 平移到「裁切框在 viewer 中的左上角」，再 drawImageRect 把圖畫出來。
class _BackgroundImagePainter extends CustomPainter {
	_BackgroundImagePainter({
		required this.image,
		required this.cropRect,
		required this.childSize,
		required this.transform,
	});

	final ui.Image image;
	final Rect cropRect;
	final Size childSize;
	final Matrix4 transform;

	@override
	void paint(Canvas canvas, Size size) {
		canvas.save();
		// 把座標原點移到裁切框左上角 — 與 InteractiveViewer 內 child 的座標一致
		canvas.translate(cropRect.left, cropRect.top);
		canvas.transform(transform.storage);
		final Rect src = Rect.fromLTWH(
			0,
			0,
			image.width.toDouble(),
			image.height.toDouble(),
		);
		final Rect dst = Offset.zero & childSize;
		canvas.drawImageRect(image, src, dst, Paint());
		canvas.restore();
	}

	@override
	bool shouldRepaint(_BackgroundImagePainter oldDelegate) =>
			oldDelegate.image != image ||
			oldDelegate.cropRect != cropRect ||
			oldDelegate.childSize != childSize ||
			oldDelegate.transform != transform;
}

/// 把 `ui.Image` 畫滿 paint size（child 尺寸已經算成 cover 裁切框）。
class _ImagePainter extends CustomPainter {
	_ImagePainter({required this.image});

	final ui.Image image;

	@override
	void paint(Canvas canvas, Size size) {
		final Rect src = Rect.fromLTWH(
			0,
			0,
			image.width.toDouble(),
			image.height.toDouble(),
		);
		final Rect dst = Offset.zero & size;
		canvas.drawImageRect(image, src, dst, Paint());
	}

	@override
	bool shouldRepaint(_ImagePainter oldDelegate) => oldDelegate.image != image;
}

/// 全螢幕遮罩（裁切框外暗化）+ 邊線 + 三等分輔助線 +（snap 中）黃色中心線。
class _CropMaskPainter extends CustomPainter {
	_CropMaskPainter({
		required this.viewerSize,
		required this.cropRect,
		required this.showSnapX,
		required this.showSnapY,
	});

	final Size viewerSize;
	final Rect cropRect;
	final bool showSnapX;
	final bool showSnapY;

	@override
	void paint(Canvas canvas, Size size) {
		final Path fullPath = Path()..addRect(Offset.zero & size);
		final Path holePath = Path()..addRect(cropRect);
		final Path maskPath = Path.combine(
			PathOperation.difference,
			fullPath,
			holePath,
		);
		canvas.drawPath(maskPath, Paint()..color = Colors.black54);
		// 裁切框白色邊線
		canvas.drawRect(
			cropRect,
			Paint()
				..style = PaintingStyle.stroke
				..strokeWidth = 2
				..color = Colors.white,
		);
		// 三等分輔助線
		final Paint guide = Paint()
			..style = PaintingStyle.stroke
			..strokeWidth = 1
			..color = Colors.white.withValues(alpha: 0.6);
		final double third = cropRect.width / 3;
		final double thirdH = cropRect.height / 3;
		canvas.drawLine(
			Offset(cropRect.left + third, cropRect.top),
			Offset(cropRect.left + third, cropRect.bottom),
			guide,
		);
		canvas.drawLine(
			Offset(cropRect.left + 2 * third, cropRect.top),
			Offset(cropRect.left + 2 * third, cropRect.bottom),
			guide,
		);
		canvas.drawLine(
			Offset(cropRect.left, cropRect.top + thirdH),
			Offset(cropRect.right, cropRect.top + thirdH),
			guide,
		);
		canvas.drawLine(
			Offset(cropRect.left, cropRect.top + 2 * thirdH),
			Offset(cropRect.right, cropRect.top + 2 * thirdH),
			guide,
		);

		// Snap 黃色輔助線：水平置中 → 畫垂直線；垂直置中 → 畫水平線。
		// 規格：水平置中（snapX = X 軸對齊）就畫貫穿全畫面的垂直線在裁切框中央。
		if (showSnapX || showSnapY) {
			final Paint snap = Paint()
				..style = PaintingStyle.stroke
				..strokeWidth = 2
				..color = Colors.yellow;
			if (showSnapX) {
				final double cx = cropRect.center.dx;
				canvas.drawLine(
					Offset(cx, 0),
					Offset(cx, viewerSize.height),
					snap,
				);
			}
			if (showSnapY) {
				final double cy = cropRect.center.dy;
				canvas.drawLine(
					Offset(0, cy),
					Offset(viewerSize.width, cy),
					snap,
				);
			}
		}
	}

	@override
	bool shouldRepaint(_CropMaskPainter oldDelegate) =>
			oldDelegate.cropRect != cropRect ||
			oldDelegate.viewerSize != viewerSize ||
			oldDelegate.showSnapX != showSnapX ||
			oldDelegate.showSnapY != showSnapY;
}

/// 傳給 isolate 的工作描述。
class _CropJob {
	const _CropJob({
		required this.raw,
		required this.x,
		required this.y,
		required this.w,
		required this.h,
	});
	final Uint8List raw;
	final int x;
	final int y;
	final int w;
	final int h;
}

/// isolate worker：解碼 + crop + 縮 + 重編。
Uint8List? _cropInIsolate(_CropJob job) {
	final img.Image? decoded = img.decodeImage(job.raw);
	if (decoded == null) return null;
	final img.Image cropped = img.copyCrop(
		decoded,
		x: job.x,
		y: job.y,
		width: job.w,
		height: job.h,
	);
	const int maxSide = 1600;
	final int longSide =
			cropped.width > cropped.height ? cropped.width : cropped.height;
	final img.Image resized = (longSide <= maxSide)
			? cropped
			: cropped.width >= cropped.height
					? img.copyResize(cropped, width: maxSide)
					: img.copyResize(cropped, height: maxSide);
	return Uint8List.fromList(img.encodeJpg(resized, quality: 85));
}
