import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ink_studio/studio_controller.dart';
import 'package:ink_studio/imaging/processor.dart';
import 'package:ink_studio/transport/serial_transport.dart';

class EmptySerial extends SerialService {
  @override
  Future<List<DevicePort>> list() async => [];
}

Future<void> settled(StudioController c, {int timeoutMs = 20000}) async {
  final clock = Stopwatch()..start();
  while (c.processing) {
    if (clock.elapsedMilliseconds > timeoutMs) {
      throw TimeoutException('processor');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'AUTO cancel/manual edit cannot publish a stale frame; reset uses new defaults',
    () async {
      SharedPreferences.setMockInitialValues({});
      final c = StudioController(serial: EmptySerial());
      final input = img.Image(width: 8, height: 8);
      img.fill(input, color: img.ColorRgb8(255, 255, 255));
      c.source = Uint8List.fromList(img.encodePng(input));
      c.updateSettings(const ImageSettings(mode: DitherMode.none));
      await settled(c);
      c.autoAdjust();
      while (c.autoProgress == 0 && c.autoTuning) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      c.updateSettings(
        const ImageSettings(
          mode: DitherMode.none,
          brightness: -.3,
          cover: false,
        ),
      );
      await settled(c);
      expect(c.autoTuning, false);
      expect(c.autoReport, isNull);
      expect(c.settings.brightness, -.3);
      expect(c.settings.cover, false);
      expect(c.fresh, true);
      c.autoAdjust();
      c.cancelAuto();
      await settled(c);
      expect(c.canUndoAuto, false);
      expect(c.settings.brightness, -.3);
      c.resetSettings();
      await settled(c);
      expect(c.settings.toJson(), const ImageSettings().toJson());
      c.dispose();
    },
  );
  test(
    'Completed AUTO applies settings and supports one-step undo',
    () async {
      SharedPreferences.setMockInitialValues({});
      final c = StudioController(serial: EmptySerial());
      final input = img.Image(width: 8, height: 8);
      img.fill(input, color: img.ColorRgb8(0, 0, 0));
      c.source = Uint8List.fromList(img.encodePng(input));
      const previous = ImageSettings(
        mode: DitherMode.none,
        brightness: .1,
        cover: false,
      );
      c.updateSettings(previous);
      await settled(c);
      c.autoAdjust();
      await settled(c, timeoutMs: 90000);
      expect(c.autoReport, isNotNull);
      expect(c.autoTuning, false);
      expect(c.canUndoAuto, true);
      expect(c.settings.cover, false);
      expect(c.fresh, true);
      c.undoAuto();
      await settled(c);
      expect(c.settings.toJson(), previous.toJson());
      expect(c.canUndoAuto, false);
      expect(c.fresh, true);
      c.dispose();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'Rapid setting changes produce only the latest frame; bad file clears stale result',
    () async {
      SharedPreferences.setMockInitialValues({});
      final c = StudioController(serial: EmptySerial());
      await c.initialize();
      await settled(c);
      expect(c.fresh, true);
      expect(c.canSend, false);
      final input = img.Image(width: 8, height: 8);
      img.fill(input, color: img.ColorRgb8(0, 0, 0));
      c.source = Uint8List.fromList(img.encodePng(input));
      c.updateSettings(
        const ImageSettings(mode: DitherMode.none, brightness: .3, cover: true),
      );
      c.updateSettings(const ImageSettings(mode: DitherMode.none, cover: true));
      expect(c.fresh, false);
      await settled(c);
      expect(c.image!.counts[0], 768 * 552);
      expect(c.fresh, true);
      c.source = Uint8List.fromList([1, 2, 3]);
      c.scheduleProcess(immediate: true);
      await settled(c);
      expect(c.image, isNull);
      expect(c.canSend, false);
      expect(c.error, isNotNull);
      c.dispose();
    },
  );
  test('Very thin input uses bounded center crop in cover mode', () {
    final input = img.Image(width: 1, height: 24000);
    img.fill(input, color: img.ColorRgb8(255, 0, 0));
    final result = processImage(
      ProcessRequest(
        Uint8List.fromList(img.encodePng(input)),
        const ImageSettings(cover: true),
        width: 32,
        height: 24,
      ),
    );
    expect(result.counts, [0, 0, 0, 768]);
  });
}
