import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_studio/widgets/crop_editor.dart';
import 'package:ink_studio/imaging/processor.dart';
import 'package:ink_studio/imaging/geometry.dart';

Future<void> loaded(WidgetTester tester) async {
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();
    if (find.byKey(const Key('crop-canvas')).evaluate().isNotEmpty) return;
  }
  fail('Editor preview failed to load');
}

void main() {
  testWidgets(
    'Crop handles, move, free angle, reset and apply work on phone and desktop',
    (tester) async {
      final font = File('C:/Windows/Fonts/msyh.ttc');
      if (font.existsSync()) {
        final loader = FontLoader('Roboto')
          ..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
        await loader.load();
      }
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
      for (final size in [
        const Size(1200, 900),
        const Size(390, 844),
        const Size(320, 700),
      ]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        CropSpec? result;
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundaryKey,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(
                colorScheme: ColorScheme.fromSeed(
                  seedColor: const Color(0xff203d3b),
                ),
              ),
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () async {
                      result = await Navigator.push<CropSpec>(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              CropEditor(source: sampleSource(null)),
                        ),
                      );
                    },
                    child: const Text('edit'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('edit'));
        await tester.pump();
        await loaded(tester);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('自由'));
        await tester.pump();
        final rect = tester.getRect(find.byKey(const Key('crop-canvas')));
        await tester.dragFrom(
          rect.topLeft + const Offset(4, 4),
          Offset(rect.width * .2, rect.height * .2),
        );
        await tester.pump();
        await tester.dragFrom(
          rect.center,
          Offset(rect.width * .06, rect.height * .06),
        );
        await tester.pumpAndSettle();
        if (size.width == 1200) {
          await tester.runAsync(() async {
            final b =
                boundaryKey.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final im = await b.toImage();
            final data = await im.toByteData(format: ui.ImageByteFormat.png);
            final file = File('build/screenshots/crop-editor.png');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(data!.buffer.asUint8List());
            im.dispose();
          });
        }
        await tester.tap(find.text('应用裁切'));
        await tester.pumpAndSettle();
        expect(result, isNotNull);
        expect(result!.valid, true);
        expect(result!.left, greaterThan(.05));
        expect(result!.width, lessThan(.95));
        await tester.tap(find.text('edit'));
        await tester.pump();
        await loaded(tester);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('顺时针 90°'));
        await tester.pump();
        await tester.tap(find.text('应用裁切'));
        await tester.pumpAndSettle();
        expect(result!.angle, 90);
        await tester.tap(find.text('edit'));
        await tester.pump();
        await loaded(tester);
        await tester.pumpAndSettle();
        final slider = tester.getRect(find.byKey(const Key('crop-angle')));
        await tester.tapAt(
          Offset(slider.left + slider.width * .65, slider.center.dy),
        );
        await tester.tap(find.byTooltip('水平镜像'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('应用裁切'));
        await tester.pumpAndSettle();
        expect(result!.angle, inExclusiveRange(1, 89));
        expect(result!.flip, true);
        await tester.tap(find.text('edit'));
        await tester.pump();
        await loaded(tester);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('顺时针 90°'));
        await tester.tap(find.text('还原全图'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('应用裁切'));
        await tester.pumpAndSettle();
        expect(result!.angle, 0);
        expect(result!.width, 1);
        expect(result!.height, 1);
        await tester.tap(find.text('edit'));
        await tester.pump();
        await loaded(tester);
        await tester.pumpAndSettle();
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(result, isNull);
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      }
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    },
  );
}
