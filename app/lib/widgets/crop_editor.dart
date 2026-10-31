import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../imaging/geometry.dart';

class CropEditor extends StatefulWidget {
  final Uint8List source;
  final CropSpec? initial;
  const CropEditor({super.key, required this.source, this.initial});
  @override
  State<CropEditor> createState() => _CropEditorState();
}

class _CropEditorState extends State<CropEditor> {
  ui.Image? image;
  int sourceWidth = 1, sourceHeight = 1;
  String? error;
  late double angle;
  late bool flip;
  Rect selection = const Rect.fromLTRB(0, 0, 1, 1);
  double? aspect = 768 / 552;
  final transform = TransformationController();
  int? handle;
  Offset? start;
  Rect? initialRect;
  @override
  void initState() {
    super.initState();
    angle = ((widget.initial?.angle ?? 0) + 180) % 360 - 180;
    flip = widget.initial?.flip ?? false;
    _load();
  }

  Future<void> _load() async {
    try {
      final (bytes, width, height) = await compute(
        editorPreview,
        widget.source,
      );
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() {
        image = frame.image;
        sourceWidth = width;
        sourceHeight = height;
        final c = widget.initial;
        if (c != null) {
          selection = Rect.fromLTRB(c.left, c.top, c.right, c.bottom);
          aspect = null;
        } else {
          _center();
        }
      });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  (double, double) get bounds =>
      rotatedSize(sourceWidth.toDouble(), sourceHeight.toDouble(), angle);
  void _center() {
    if (image == null) return;
    final (w, h) = bounds;
    final ratio = (aspect ?? w / h) * h / w;
    selection = Rect.fromCenter(
      center: const Offset(.5, .5),
      width: math.min(1.0, ratio),
      height: math.min(1.0, 1 / ratio),
    );
    transform.value = Matrix4.identity();
  }

  void _rotate(double value) {
    setState(() {
      angle = value;
      _center();
    });
  }

  void _start(DragStartDetails d, Size size) {
    final p = Offset(
      d.localPosition.dx / size.width,
      d.localPosition.dy / size.height,
    );
    final corners = [
      selection.topLeft,
      selection.topRight,
      selection.bottomRight,
      selection.bottomLeft,
    ];
    handle = null;
    for (var i = 0; i < 4; i++) {
      final delta = corners[i] - p;
      if (Offset(delta.dx * size.width, delta.dy * size.height).distance < 30) {
        handle = i;
        break;
      }
    }
    if (handle == null && !selection.contains(p)) return;
    start = p;
    initialRect = selection;
  }

  void _drag(DragUpdateDetails d, Size size) {
    if (start == null || initialRect == null) return;
    final p = Offset(
      (d.localPosition.dx / size.width).clamp(0, 1),
      (d.localPosition.dy / size.height).clamp(0, 1),
    );
    final r = initialRect!;
    if (handle == null) {
      final delta = p - start!;
      final dx = delta.dx.clamp(-r.left, 1 - r.right),
          dy = delta.dy.clamp(-r.top, 1 - r.bottom);
      setState(() => selection = r.shift(Offset(dx, dy)));
      return;
    }
    final anchors = [r.bottomRight, r.bottomLeft, r.topLeft, r.topRight];
    final anchor = anchors[handle!],
        sx = (handle == 0 || handle == 3) ? -1.0 : 1.0,
        sy = (handle == 0 || handle == 1) ? -1.0 : 1.0;
    var w = ((p.dx - anchor.dx) * sx).clamp(
      math.min(.01, sx < 0 ? anchor.dx : 1 - anchor.dx),
      sx < 0 ? anchor.dx : 1 - anchor.dx,
    );
    var h = ((p.dy - anchor.dy) * sy).clamp(
      math.min(.01, sy < 0 ? anchor.dy : 1 - anchor.dy),
      sy < 0 ? anchor.dy : 1 - anchor.dy,
    );
    if (aspect != null) {
      final (bw, bh) = bounds;
      final ratio = aspect! * bh / bw;
      h = w / ratio;
      final maxH = sy < 0 ? anchor.dy : 1 - anchor.dy;
      if (h > maxH) {
        h = maxH;
        w = h * ratio;
      }
    }
    final edge = Offset(anchor.dx + sx * w, anchor.dy + sy * h);
    setState(() => selection = Rect.fromPoints(anchor, edge));
  }

  @override
  void dispose() {
    // The Windows raster thread can still be painting the last frame while
    // Navigator removes this route. Releasing the native image immediately
    // races that paint and can crash in flutter_windows.dll. Keep the image
    // alive through the route transition, then release it after three frames.
    final preview = image;
    image = null;
    if (preview != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            preview.dispose();
          });
        });
      });
    }
    transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xff172b2a),
    appBar: AppBar(
      title: const Text('裁切与旋转'),
      actions: [
        TextButton(
          onPressed: image == null
              ? null
              : () {
                  final r = selection;
                  Navigator.pop(
                    context,
                    CropSpec(
                      left: r.left,
                      top: r.top,
                      right: r.right,
                      bottom: r.bottom,
                      angle: angle,
                      flip: flip,
                    ),
                  );
                },
          child: const Text('应用裁切'),
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              '拖动四角裁切，框内移动 · 双指或滚轮缩放查看',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: image == null
                  ? Center(
                      child: error == null
                          ? const CircularProgressIndicator()
                          : Text(
                              error!,
                              style: const TextStyle(color: Colors.white),
                            ),
                    )
                  : LayoutBuilder(
                      builder: (context, box) {
                        final (bw, bh) = bounds;
                        final scale = math.min(
                          box.maxWidth / bw,
                          box.maxHeight / bh,
                        );
                        final size = Size(bw * scale, bh * scale);
                        return Center(
                          child: InteractiveViewer(
                            transformationController: transform,
                            minScale: 1,
                            maxScale: 5,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              dragStartBehavior: DragStartBehavior.down,
                              onPanStart: (d) => _start(d, size),
                              onPanUpdate: (d) => _drag(d, size),
                              onPanEnd: (_) {
                                start = null;
                                initialRect = null;
                              },
                              child: CustomPaint(
                                key: const Key('crop-canvas'),
                                size: size,
                                painter: _CropPainter(
                                  image!,
                                  selection,
                                  angle,
                                  flip,
                                  sourceWidth,
                                  sourceHeight,
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
          Container(
            color: Theme.of(context).colorScheme.surface,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    ChoiceChip(
                      label: const Text('屏幕比例'),
                      selected: aspect == 768 / 552,
                      onSelected: (_) => setState(() {
                        aspect = 768 / 552;
                        _center();
                      }),
                    ),
                    ChoiceChip(
                      label: const Text('自由'),
                      selected: aspect == null,
                      onSelected: (_) => setState(() => aspect = null),
                    ),
                    ChoiceChip(
                      label: const Text('1:1'),
                      selected: aspect == 1,
                      onSelected: (_) => setState(() {
                        aspect = 1;
                        _center();
                      }),
                    ),
                    ChoiceChip(
                      label: const Text('4:3'),
                      selected: aspect == 4 / 3,
                      onSelected: (_) => setState(() {
                        aspect = 4 / 3;
                        _center();
                      }),
                    ),
                    IconButton(
                      tooltip: '逆时针 90°',
                      onPressed: () =>
                          _rotate(((angle - 90 + 180) % 360) - 180),
                      icon: const Icon(Icons.rotate_left),
                    ),
                    IconButton(
                      tooltip: '顺时针 90°',
                      onPressed: () =>
                          _rotate(((angle + 90 + 180) % 360) - 180),
                      icon: const Icon(Icons.rotate_right),
                    ),
                    IconButton(
                      tooltip: '水平镜像',
                      onPressed: () => setState(() => flip = !flip),
                      icon: const Icon(Icons.flip),
                    ),
                    TextButton(
                      onPressed: () => setState(() {
                        angle = 0;
                        flip = false;
                        aspect = null;
                        _center();
                      }),
                      child: const Text('还原全图'),
                    ),
                  ],
                ),
                Row(
                  children: [
                    SizedBox(
                      width: 64,
                      child: Text('${angle.toStringAsFixed(1)}°'),
                    ),
                    Expanded(
                      child: Slider(
                        key: const Key('crop-angle'),
                        value: angle.clamp(-180, 180),
                        min: -180,
                        max: 180,
                        divisions: 720,
                        onChanged: image == null ? null : _rotate,
                      ),
                    ),
                  ],
                ),
                const Text(
                  '旋转后裁切框重新居中；斜转空白为白色。原始文件不会被修改。',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _CropPainter extends CustomPainter {
  final ui.Image image;
  final Rect selection;
  final double angle;
  final bool flip;
  final int sourceWidth, sourceHeight;
  _CropPainter(
    this.image,
    this.selection,
    this.angle,
    this.flip,
    this.sourceWidth,
    this.sourceHeight,
  );
  @override
  void paint(Canvas canvas, Size size) {
    final (bw, bh) = rotatedSize(
      sourceWidth.toDouble(),
      sourceHeight.toDouble(),
      angle,
    );
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(size.width / bw, size.height / bh);
    canvas.rotate(angle * math.pi / 180);
    canvas.scale(flip ? -1 : 1, 1);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(
        -sourceWidth / 2,
        -sourceHeight / 2,
        sourceWidth.toDouble(),
        sourceHeight.toDouble(),
      ),
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();
    final r = Rect.fromLTRB(
      selection.left * size.width,
      selection.top * size.height,
      selection.right * size.width,
      selection.bottom * size.height,
    );
    final shade = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(r);
    canvas.drawPath(
      shade,
      Paint()..color = Colors.black.withValues(alpha: .58),
    );
    canvas.drawRect(
      r,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    final grid = Paint()
      ..color = Colors.white.withValues(alpha: .45)
      ..strokeWidth = .7;
    for (var i = 1; i < 3; i++) {
      canvas.drawLine(
        Offset(r.left + r.width * i / 3, r.top),
        Offset(r.left + r.width * i / 3, r.bottom),
        grid,
      );
      canvas.drawLine(
        Offset(r.left, r.top + r.height * i / 3),
        Offset(r.right, r.top + r.height * i / 3),
        grid,
      );
    }
    for (final p in [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight]) {
      canvas.drawCircle(p, 7, Paint()..color = Colors.white);
      canvas.drawCircle(p, 3, Paint()..color = const Color(0xff203d3b));
    }
  }

  @override
  bool shouldRepaint(covariant _CropPainter old) =>
      image != old.image ||
      selection != old.selection ||
      angle != old.angle ||
      flip != old.flip;
}
