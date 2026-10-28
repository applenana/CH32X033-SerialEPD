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

Future<void> settled(StudioController c) async {
  final clock = Stopwatch()..start();
  while (c.processing) {
    if (clock.elapsedMilliseconds > 20000) throw TimeoutException('processor');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
