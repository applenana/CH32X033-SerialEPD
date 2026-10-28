import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_studio/main.dart';
import 'package:ink_studio/studio_controller.dart';
import 'package:ink_studio/imaging/processor.dart';

void main() {
  testWidgets('Responsive desktop and phone layouts, with real image preview', (
    tester,
  ) async {
    final font = File('C:/Windows/Fonts/msyh.ttc');
    if (font.existsSync()) {
      for (final family in ['Microsoft YaHei', 'Roboto']) {
        final loader = FontLoader(family)
          ..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
        await loader.load();
      }
    }
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    final c = StudioController();
    c.image = processImage(const ProcessRequest(null, ImageSettings()));
    for (final size in [
      const Size(1440, 1000),
      const Size(390, 844),
      const Size(800, 1000),
      const Size(320, 700),
    ]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: InkStudio(controller: c),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => precacheImage(
          MemoryImage(c.image!.preview),
          tester.element(find.byType(StudioPage)),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('墨屿'), findsOneWidget);
      expect(find.text('我的设备'), findsOneWidget);
      if (size.width == 1440 || size.width == 390) {
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            'build/screenshots/${size.width == 1440 ? 'desktop' : 'android'}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox());
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    c.dispose();
  });
}
