import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'processor.dart';
import 'reconstruction.dart' show linearLight, projectGamut;

/// Local heuristic search, not a trained model or a calibrated vision metric.
/// Each candidate is assessed at panel resolution against ONE fixed original.
class AutoProgress {
  final String phase;
  final double fraction;
  const AutoProgress(this.phase, this.fraction);
}

class AutoMetrics {
  final double fine, coarse, edge, grain, neutralInk, paperSpeckles, bias;
  const AutoMetrics(
    this.fine,
    this.coarse,
    this.edge,
    this.grain,
    this.neutralInk,
    this.paperSpeckles,
    this.bias,
  );
  double get score =>
      1.5 * fine +
      3 * coarse +
      .45 * edge +
      .008 * grain +
      .025 * neutralInk +
      .035 * paperSpeckles +
      .5 * bias * bias;
}

class AutoResult {
  final ImageSettings settings;
  final ProcessedImage image;
  final AutoMetrics baseline, firstPass, finalPass;
  final int candidates, milliseconds;
  final String sourceKind;
  const AutoResult(
    this.settings,
    this.image,
    this.baseline,
    this.firstPass,
    this.finalPass,
    this.candidates,
    this.milliseconds,
    this.sourceKind,
  );
}

double _luma(double r, double g, double b) => .2126 * r + .7152 * g + .0722 * b;

/// Normalized box filter with clamped image extents, O(pixels) per pass.
Float32List _box(Float32List input, int w, int h, int radius) {
  final tmp = Float32List(input.length), out = Float32List(input.length);
  for (var y = 0; y < h; y++) {
    final row = y * w;
    var sum = 0.0;
    for (var x = 0; x <= math.min(radius, w - 1); x++) {
      sum += input[row + x];
    }
    for (var x = 0; x < w; x++) {
      tmp[row + x] =
          sum / (math.min(w - 1, x + radius) - math.max(0, x - radius) + 1);
      if (x - radius >= 0) sum -= input[row + x - radius];
      if (x + radius + 1 < w) sum += input[row + x + radius + 1];
    }
  }
  for (var x = 0; x < w; x++) {
    var sum = 0.0;
    for (var y = 0; y <= math.min(radius, h - 1); y++) {
      sum += tmp[y * w + x];
    }
    for (var y = 0; y < h; y++) {
      out[y * w + x] =
          sum / (math.min(h - 1, y + radius) - math.max(0, y - radius) + 1);
      if (y - radius >= 0) sum -= tmp[(y - radius) * w + x];
      if (y + radius + 1 < h) sum += tmp[(y + radius + 1) * w + x];
    }
  }
  return out;
}

class AutoReference {
  final int width, height;
  final List<Float32List> target;
  final Float32List luminance, localY, flat;
  final Uint8List neutral, paper;
  final double p02, median, p98, nearWhite, colorFraction, inkFraction;
  AutoReference._(
    this.width,
    this.height,
    this.target,
    this.luminance,
    this.localY,
    this.flat,
    this.neutral,
    this.paper,
    this.p02,
    this.median,
    this.p98,
    this.nearWhite,
    this.colorFraction,
    this.inkFraction,
  );

  factory AutoReference(PreparedImage image) {
    final w = image.width, h = image.height, n = w * h;
    final target = List.generate(3, (_) => Float32List(n));
    final lum = Float32List(n), rawY = Float32List(n), squared = Float32List(n);
    final neutral = Uint8List(n),
        paper = Uint8List(n),
        hist = List.filled(256, 0);
    var whites = 0, colors = 0, inks = 0;
    for (var i = 0; i < n; i++) {
      final r = image.rgb[3 * i],
          g = image.rgb[3 * i + 1],
          b = image.rgb[3 * i + 2];
      final lr = linearLight(r), lg = linearLight(g), lb = linearLight(b);
      final mapped = projectGamut(lr, lg, lb);
      for (var c = 0; c < 3; c++) {
        target[c][i] = mapped[c];
      }
      lum[i] = _luma(mapped[0], mapped[1], mapped[2]);
      rawY[i] = _luma(lr, lg, lb);
      squared[i] = rawY[i] * rawY[i];
      hist[(_luma(r, g, b) * 255).round().clamp(0, 255)]++;
      final spread = math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));
      if (spread < .045) neutral[i] = 1;
      if (spread > .12) colors++;
      if (math.min(r, math.min(g, b)) > .94) {
        paper[i] = 1;
        whites++;
      }
      var nearest = double.infinity;
      for (final ink in palette) {
        nearest = math.min(
          nearest,
          (r - ink[0]).abs() + (g - ink[1]).abs() + (b - ink[2]).abs(),
        );
      }
      if (nearest < .08) inks++;
    }
    double percentile(double fraction) {
      var sum = 0;
      for (var i = 0; i < 256; i++) {
        sum += hist[i];
        if (sum >= n * fraction) return i / 255;
      }
      return 1;
    }

    final mean = _box(rawY, w, h, 1), meanSquare = _box(squared, w, h, 1);
    final flat = Float32List(n);
    for (var i = 0; i < n; i++) {
      final variance = math.max(0, meanSquare[i] - mean[i] * mean[i]);
      flat[i] = (1 - variance / .002).clamp(0.0, 1.0);
    }
    return AutoReference._(
      w,
      h,
      target,
      lum,
      _box(lum, w, h, 1),
      flat,
      neutral,
      paper,
      percentile(.02),
      percentile(.5),
      percentile(.98),
      whites / n,
      colors / n,
      inks / n,
    );
  }

  String get kind => inkFraction > .94
      ? '文字／纯色色块'
      : colorFraction < .08
      ? '灰度／低彩度图像'
      : '彩色图像';

  /// Source analysis makes a restrained seed. It never auto-crops or rotates.
  ImageSettings seed(ImageSettings current) {
    final span = p98 - p02;
    final photo = inkFraction <= .94;
    return ImageSettings(
      cover: current.cover,
      rotation: current.rotation,
      mode: photo ? DitherMode.perceptual : DitherMode.none,
      brightness: photo && median < .24 ? .025 : 0,
      contrast: photo && span > .18 && span < .70 ? 1.06 : 1,
      gamma: photo && median < .30 ? 1.08 : 1,
      saturation: colorFraction > .8 ? .96 : 1,
    );
  }
}

/// Multi-scale error balances color/tone fidelity with grain and edge detail.
/// The reference is the original projected into the representable ideal gamut,
/// not a target regenerated from each candidate's settings (which would cheat).
AutoMetrics evaluateAutoPixels(Uint8List indices, AutoReference reference) {
  final w = reference.width, h = reference.height, n = w * h;
  if (indices.length != n) throw ArgumentError('AUTO 图像尺寸不一致');
  final error = List.generate(3, (_) => Float32List(n));
  final y = Float32List(n);
  var bias = 0.0, neutralInk = 0.0, paperNoise = 0.0;
  for (var i = 0; i < n; i++) {
    final ink = palette[indices[i]];
    for (var c = 0; c < 3; c++) {
      error[c][i] = ink[c] - reference.target[c][i];
    }
    y[i] = _luma(ink[0], ink[1], ink[2]);
    bias += y[i] - reference.luminance[i];
    if (reference.neutral[i] != 0 && indices[i] >= 2) neutralInk++;
    if (reference.paper[i] != 0 && indices[i] != 1) {
      paperNoise += reference.flat[i];
    }
  }
  double colorError(int radius) {
    final blurred = [for (final channel in error) _box(channel, w, h, radius)];
    var sum = 0.0;
    for (var i = 0; i < n; i++) {
      final r = blurred[0][i], g = blurred[1][i], b = blurred[2][i];
      final dy = _luma(r, g, b), rg = r - g, gb = g - b;
      sum += dy * dy + .25 * (rg * rg + gb * gb);
    }
    return sum / n;
  }

  final fine = colorError(1), coarse = colorError(3);
  final blurredY = _box(y, w, h, 1);
  var edge = 0.0, grain = 0.0;
  var edgeCount = 0;
  for (var row = 0; row < h; row++) {
    for (var col = 0; col < w; col++) {
      final i = row * w + col;
      final high = y[i] - blurredY[i];
      grain += high * high * reference.flat[i];
      for (final step in [if (col + 1 < w) 1, if (row + 1 < h) w]) {
        final sourceDelta = reference.localY[i + step] - reference.localY[i];
        // Source edges, including antialiased thin text, must remain visible.
        if (sourceDelta.abs() > .025) {
          final delta = (blurredY[i + step] - blurredY[i]) - sourceDelta;
          edge += delta * delta;
          edgeCount++;
        }
      }
    }
  }
  return AutoMetrics(
    fine,
    coarse,
    edge / math.max(1, edgeCount),
    grain / n,
    neutralInk / n,
    paperNoise / n,
    bias / n,
  );
}

/// Two passes, at most ten unique full-resolution renders. Call in an isolate.
AutoResult autoTune(
  ProcessRequest request, {
  void Function(AutoProgress)? onProgress,
}) {
  final watch = Stopwatch()..start();
  void progress(String phase, double fraction) =>
      onProgress?.call(AutoProgress(phase, fraction));
  progress('分析原图：明暗、彩度和细节…', .02);
  final prepared = prepareImage(request);
  final reference = AutoReference(prepared);
  // Source is prepared only once, all settings use this same geometry.
  return _search(prepared, reference, request.settings, watch, progress);
}

AutoResult _search(
  PreparedImage prepared,
  AutoReference reference,
  ImageSettings original,
  Stopwatch watch,
  void Function(String, double) progress,
) {
  final seen = <String>{};
  var count = 0;
  late ImageSettings bestSettings;
  late ProcessedImage bestImage;
  late AutoMetrics bestMetrics;
  AutoMetrics? baseline;
  void candidate(ImageSettings settings, String label, double fraction) {
    if (!seen.add(jsonEncode(settings.toJson()))) return;
    progress(label, fraction);
    final output = processPrepared(prepared, settings);
    final metrics = evaluateAutoPixels(output.indices, reference);
    count++;
    baseline ??= metrics;
    if (count == 1 || metrics.score < bestMetrics.score - 1e-9) {
      bestSettings = settings;
      bestImage = output;
      bestMetrics = metrics;
    }
  }

  candidate(original, '第一轮：记录当前参数的四色结果…', .10);
  final seed = reference.seed(original);
  candidate(seed, '第一轮：按原图生成初调方案…', .20);
  candidate(
    ImageSettings(cover: original.cover, rotation: original.rotation),
    '第一轮：比较默认保细节方案…',
    .30,
  );
  final first = bestMetrics, start = bestSettings;
  progress('第二轮：分析四色图的颗粒、彩点与边缘…', .40);
  final correction = (-first.bias * .35).clamp(-.025, .025);
  final candidates = [
    start.copyWith(
      mode: DitherMode.perceptual,
      softness: 1,
      naturalMapping: 1,
      saturation: first.neutralInk > .001
          ? math.min(start.saturation, .92)
          : start.saturation,
    ),
    start.copyWith(
      mode: DitherMode.perceptual,
      softness: .65,
      paperWhite: 0,
      naturalMapping: reference.colorFraction > .15 ? .8 : 1,
    ),
    start.copyWith(
      brightness: (start.brightness + correction).clamp(-.12, .12),
      gamma: (start.gamma - first.bias * .3).clamp(.85, 1.15),
    ),
    start.copyWith(mode: DitherMode.blueNoise, paperWhite: 0),
    start.copyWith(
      mode: DitherMode.burkes,
      strength: .9,
      perceptual: true,
      serpentine: true,
    ),
    if (reference.nearWhite > .08 && first.paperSpeckles > .002)
      start.copyWith(
        mode: DitherMode.perceptual,
        paperWhite: math.min(.04, math.max(.015, first.paperSpeckles * .2)),
      ),
    if (reference.inkFraction > .75)
      start.copyWith(
        mode: DitherMode.none,
        brightness: 0,
        contrast: 1,
        gamma: 1,
      ),
  ];
  for (var i = 0; i < candidates.length; i++) {
    candidate(
      candidates[i],
      '第二轮：微调并复评 ${i + 1}/${candidates.length}',
      .45 + .5 * i / candidates.length,
    );
  }
  progress('已选取综合评分较优方案', 1);
  return AutoResult(
    bestSettings,
    bestImage,
    baseline!,
    first,
    bestMetrics,
    count,
    watch.elapsedMilliseconds,
    reference.kind,
  );
}
