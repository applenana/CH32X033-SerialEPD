import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:ink_studio/imaging/auto_tune.dart';
import 'package:ink_studio/imaging/auto_tune_job.dart';
import 'package:ink_studio/imaging/processor.dart';

Uint8List picture(int w, int h, void Function(img.Image) fill) {
  final image = img.Image(width: w, height: h);
  fill(image);
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  test(
    'New defaults migrate once; manual choices survive subsequent loads',
    () {
      final migrated = ImageSettings.fromJson({
        'cover': false,
        'softness': .5,
        'naturalMapping': .65,
        'paperWhite': .07,
        'brightness': .12,
        'colorInduction': 1,
        'inductionRadius': 24,
      });
      expect(
        [migrated.softness, migrated.naturalMapping, migrated.paperWhite],
        [1, 1, 0],
      );
      expect(migrated.cover, isTrue);
      expect(migrated.brightness, .12);
      expect(migrated.toJson().containsKey('colorInduction'), isFalse);
      final manual = migrated.copyWith(
        cover: false,
        softness: .3,
        paperWhite: .04,
      );
      final loaded = ImageSettings.fromJson(manual.toJson());
      expect(loaded.toJson(), manual.toJson());
      final defaults = const ImageSettings();
      expect(defaults.cover, isTrue);
      expect(
        [
          defaults.brightness,
          defaults.contrast,
          defaults.saturation,
          defaults.strength,
        ],
        [.1, 1.1, 1.1, 1],
      );
      expect(
        [defaults.gamma, defaults.softness, defaults.naturalMapping],
        [1, 1, 1],
      );
      expect(
        [defaults.softness, defaults.naturalMapping, defaults.paperWhite],
        [1, 1, 0],
      );
      final explicitOldSetting = ImageSettings.fromJson({
        'defaultsVersion': 2,
        'mode': 'floyd',
        'strength': 0,
      });
      expect(explicitOldSetting.strength, 1);
      final explicitCurrentSetting = ImageSettings.fromJson({
        'defaultsVersion': 4,
        'mode': 'floyd',
        'strength': 0,
      });
      expect(explicitCurrentSetting.strength, 0);
      final upgraded = ImageSettings.fromJson({
        'defaultsVersion': 1,
        'brightness': 0,
        'contrast': 1,
        'saturation': 1,
        'strength': 1,
      });
      expect(
        [
          upgraded.brightness,
          upgraded.contrast,
          upgraded.saturation,
          upgraded.strength,
        ],
        [.1, 1.1, 1.1, 1],
      );
    },
  );

  test('AUTO reduces wrong flat quantization without erasing gray tone', () {
    final bytes = picture(
      32,
      24,
      (p) => img.fill(p, color: img.ColorRgb8(128, 128, 128)),
    );
    final phases = <String>[];
    final request = ProcessRequest(
      bytes,
      const ImageSettings(mode: DitherMode.none),
      width: 32,
      height: 24,
    );
    final result = autoTune(request, onProgress: (p) => phases.add(p.phase));
    expect(result.finalPass.score, lessThan(result.baseline.score));
    expect(result.image.counts[0], greaterThan(0));
    expect(result.image.counts[1] / (32 * 24), closeTo(.216, .035));
    expect(result.image.counts[2] + result.image.counts[3], 0);
    expect(phases.any((p) => p.startsWith('第二轮：微调')), isTrue);
    expect(result.candidates, inInclusiveRange(2, 10));
  });

  test('AUTO preserves thin text and exact BWYR ink regions', () {
    final bytes = picture(32, 24, (p) {
      for (var y = 0; y < 24; y++) {
        for (var x = 0; x < 32; x++) {
          final ink = palette[x == 3 || y == 9 ? 0 : x ~/ 8];
          p.setPixelRgb(x, y, ink[0] * 255, ink[1] * 255, ink[2] * 255);
        }
      }
    });
    final request = ProcessRequest(
      bytes,
      const ImageSettings(mode: DitherMode.none),
      width: 32,
      height: 24,
    );
    final initial = processImage(request);
    final result = autoTune(request);
    expect(result.image.indices, initial.indices);
    // Exact colors and text must survive, while the grain term can legitimately
    // see a small signal at a low-contrast yellow/white boundary.
    expect(result.finalPass.fine, lessThan(1e-12));
    expect(result.finalPass.coarse, lessThan(1e-12));
  });

  test(
    'Two-pass result is deterministic, bounded and matches manual rendering',
    () {
      final bytes = picture(48, 32, (p) {
        for (var y = 0; y < 32; y++) {
          for (var x = 0; x < 48; x++) {
            p.setPixelRgb(x, y, 60 + x * 4, 30 + y * 5, 20 + x * 2);
          }
        }
      });
      final request = ProcessRequest(
        bytes,
        const ImageSettings(cover: false, brightness: .2, contrast: 1.4),
        width: 48,
        height: 32,
      );
      final result = autoTune(request), again = autoTune(request);
      expect(result.finalPass.score, lessThanOrEqualTo(result.firstPass.score));
      expect(result.firstPass.score, lessThanOrEqualTo(result.baseline.score));
      expect(result.settings.cover, isFalse);
      expect(result.image.packed, again.image.packed);
      expect(result.settings.toJson(), again.settings.toJson());
      expect(
        result.image.packed,
        processImage(
          ProcessRequest(bytes, result.settings, width: 48, height: 32),
        ).packed,
      );
      expect(result.image.indices.every((c) => c >= 0 && c < 4), isTrue);
      expect(result.image.counts.reduce((a, b) => a + b), 48 * 32);
    },
  );

  test('Objective rejects blanking detailed content to eliminate grain', () {
    final bytes = picture(32, 32, (p) {
      for (var y = 0; y < 32; y++) {
        for (var x = 0; x < 32; x++) {
          final v = (x ~/ 4 + y ~/ 4).isEven ? 0 : 255;
          p.setPixelRgb(x, y, v, v, v);
        }
      }
    });
    final request = ProcessRequest(
      bytes,
      const ImageSettings(),
      width: 32,
      height: 32,
    );
    final reference = AutoReference(prepareImage(request));
    final good = evaluateAutoPixels(processImage(request).indices, reference);
    final white = evaluateAutoPixels(
      Uint8List(1024)..fillRange(0, 1024, 1),
      reference,
    );
    expect(white.score, greaterThan(good.score + .1));
  });

  test('Worker can be cancelled immediately and after real progress', () async {
    final early = AutoTuneJob(
      const ProcessRequest(null, ImageSettings(), width: 32, height: 24),
    );
    final earlyResult = expectLater(
      early.result,
      throwsA(isA<AutoCancelled>()),
    );
    early.cancel();
    early.cancel();
    await earlyResult;
    final began = Completer<void>();
    final running = AutoTuneJob(
      const ProcessRequest(null, ImageSettings()),
      onProgress: (_) {
        if (!began.isCompleted) began.complete();
      },
    );
    final cancelled = expectLater(
      running.result,
      throwsA(isA<AutoCancelled>()),
    );
    await began.future.timeout(const Duration(seconds: 10));
    running.cancel();
    await cancelled;
  });

  test(
    'Worker completes and reports malformed input without hanging',
    () async {
      final good = AutoTuneJob(
        const ProcessRequest(null, ImageSettings(), width: 32, height: 24),
      );
      final output = await good.result.timeout(const Duration(seconds: 15));
      expect(output.image.packed.length, 32 * 24 ~/ 4);
      final bad = AutoTuneJob(
        ProcessRequest(Uint8List.fromList([1, 2, 3]), const ImageSettings()),
      );
      await expectLater(
        bad.result.timeout(const Duration(seconds: 10)),
        throwsStateError,
      );
    },
  );
}
