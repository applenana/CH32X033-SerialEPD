import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:ink_studio/imaging/reconstruction.dart';
import 'package:ink_studio/imaging/palette_calibration.dart';
import 'package:ink_studio/imaging/geometry.dart';
import 'package:ink_studio/imaging/blue_noise.dart';
import 'package:ink_studio/imaging/processor.dart';

void main() {
  test('Measured palette round-trips and rejects degenerate white point', () {
    final measured = PaletteCalibration.fromRgb8(
      black: [18, 20, 19], white: [232, 230, 224],
      yellow: [201, 186, 74], red: [180, 62, 48],
    );
    expect(PaletteCalibration.fromJson(measured.toJson()).colors, measured.colors);
    expect(measured.valid, isTrue);
    expect(const PaletteCalibration(colors: [
      [0, 0, 0], [0.01, 0.01, 0.01], [1, 1, 0], [1, 0, 0],
    ]).valid, isFalse);
  });
  test('Dynamic and gamut compression are active without calibration', () {
    final plain = projectToPalette(.05, .25, .85, const [
      [0, 0, 0], [1, 1, 1], [1, 1, 0], [1, 0, 0],
    ], 0);
    final compressed = projectToPalette(.05, .25, .85, const [
      [0, 0, 0], [1, 1, 1], [1, 1, 0], [1, 0, 0],
    ], 1);
    expect(compressed, isNot(plain));
  });
  test('Compact algorithm list and legacy preference migration', () {
    expect(DitherMode.values.map((m) => m.name).toSet(), {
      'none',
      'floyd',
      'burkes',
      'stucki',
      'perceptual',
      'blueNoise',
    });
    for (final entry in {
      'atkinson': 'burkes',
      'jjn': 'stucki',
      'sierra': 'stucki',
      'sierraLite': 'floyd',
      'bayer4': 'blueNoise',
      'bayer8': 'blueNoise',
    }.entries) {
      final settings = ImageSettings.fromJson({
        'mode': entry.key,
        'brightness': .1,
      });
      expect(settings.mode.name, entry.value);
      expect(settings.brightness, .1);
      expect(ImageSettings.fromJson(settings.toJson()).mode, settings.mode);
    }
    expect(
      ImageSettings.fromJson({'mode': 'unrecognized'}).mode,
      DitherMode.perceptual,
    );
  });
  test('Void-cluster ranks are a full deterministic permutation', () {
    final ranks = blueNoiseRanks.toList()..sort();
    expect(ranks, List.generate(128 * 128, (i) => i));
  });
  test('Gamut projection retains linear luminance and valid coverage', () {
    for (final c in [
      [0.0, 1.0, 0.0],
      [0.0, 0.0, 1.0],
      [.2, .8, .4],
      [.8, .2, .6],
      [.3, .3, .3],
    ]) {
      final p = projectGamut(c[0], c[1], c[2]);
      expect(p[0], greaterThanOrEqualTo(p[1]));
      expect(p[1], greaterThanOrEqualTo(p[2]));
      expect(
        .2126 * p[0] + .7152 * p[1] + .0722 * p[2],
        closeTo(.2126 * c[0] + .7152 * c[1] + .0722 * c[2], 1e-10),
      );
      final weights = coverage(c[0], c[1], c[2]);
      expect(weights.every((v) => v >= 0 && v <= 1), true);
      expect(weights.reduce((a, b) => a + b), closeTo(1, 1e-10));
    }
  });
  test(
    'Linear-light gray is reconstructed with appropriate white coverage',
    () {
      final rgb = Float32List(128 * 128 * 3)..fillRange(0, 128 * 128 * 3, .5);
      final result = reconstruct(rgb, 128, 128, paperWhite: 0);
      final fraction = result.indices.where((i) => i == 1).length / (128 * 128);
      expect(fraction, closeTo(linearLight(.5), .001));
      expect(result.indices.every((i) => i == 0 || i == 1), true);
    },
  );
  test('DBS monotonically improves its stated visual objective', () {
    const w = 48, h = 32;
    final rgb = Float32List(w * h * 3);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = (y * w + x) * 3;
        rgb[i] = .5 + x / w * .45;
        rgb[i + 1] = .2 + y / h * .6;
        rgb[i + 2] = .1 + x / w * .25;
      }
    }
    final result = reconstruct(
      rgb,
      w,
      h,
      optimize: true,
      paperWhite: 0,
      maxPasses: 3,
    );
    expect(result.finalError, lessThan(result.initialError * .95));
    final blue = reconstruct(rgb, w, h, paperWhite: 0);
    for (var ink = 0; ink < 4; ink++) {
      expect(
        result.indices.where((i) => i == ink).length,
        blue.indices.where((i) => i == ink).length,
      );
    }
    expect(result.passes, greaterThan(0));
    expect(
      result.indices,
      reconstruct(
        rgb,
        w,
        h,
        optimize: true,
        paperWhite: 0,
        maxPasses: 3,
      ).indices,
    );
  });
  test('DBS cannot introduce chromatic specks in neutral gray', () {
    final rgb = Float32List(64 * 32 * 3)..fillRange(0, 64 * 32 * 3, .6);
    final out = reconstruct(rgb, 64, 32, optimize: true);
    expect(out.indices.every((i) => i < 2), true);
  });
  test('Paper-white protection can be turned off', () {
    final rgb = Float32List(32 * 32 * 3)..fillRange(0, 32 * 32 * 3, .97);
    expect(
      reconstruct(
        rgb,
        32,
        32,
        paperWhite: .07,
        optimize: true,
      ).indices.every((i) => i == 1),
      true,
    );
    expect(reconstruct(rgb, 32, 32, paperWhite: 0).indices.contains(0), true);
  });
  test(
    'Crop region and clockwise rotation map to the selected source pixels',
    () {
      final source = img.Image(width: 8, height: 8);
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          source.setPixelRgb(x, y, x < 4 ? 255 : 0, y < 4 ? 255 : 0, 0);
        }
      }
      final region = frameImage(
        source,
        const CropSpec(left: .5, top: 0, right: 1, bottom: .5),
        4,
        4,
        cover: false,
      );
      expect(region.getPixel(1, 1).g, 255);
      expect(region.getPixel(1, 1).r, 0);
      final rotated = frameImage(
        source,
        const CropSpec(angle: 90),
        8,
        8,
        cover: false,
      );
      expect(rotated.getPixel(1, 1).r, 255);
      expect(rotated.getPixel(1, 1).g, 0);
      final flipped = frameImage(
        source,
        const CropSpec(flip: true),
        8,
        8,
        cover: false,
      );
      expect(flipped.getPixel(1, 1).r, 0);
    },
  );
  test('Arbitrary rotation handles white corners without large allocation', () {
    final source = img.Image(width: 100, height: 100);
    img.fill(source, color: img.ColorRgb8(255, 0, 0));
    final result = frameImage(
      source,
      const CropSpec(angle: 45),
      32,
      32,
      cover: false,
    );
    expect(result.getPixel(0, 0).g, 255);
    expect(result.getPixel(16, 16).g, 0);
    expect(
      () => frameImage(
        source,
        const CropSpec(left: 1, right: 0),
        32,
        32,
        cover: false,
      ),
      throwsArgumentError,
    );
  });
}
