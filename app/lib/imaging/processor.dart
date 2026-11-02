import 'dart:math' as math;
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import '../protocol/codec.dart';
import 'geometry.dart';
import 'reconstruction.dart';
import 'color_mapping.dart';
import 'palette_calibration.dart';

enum DitherMode {
  perceptual('感知重建 · DBS', '优化观看尺度下的颜色与网点，计算较慢'),
  blueNoise('蓝噪声 · 色彩覆盖', '线性光混色，减少规则纹理与误差串色'),
  none('直接量化', '清晰文字与色块，保留干净边缘'),
  floyd('Floyd–Steinberg', '均衡细节与层次，适合大多数照片'),
  stucki('Stucki', '平滑层次，同时保留较多细节'),
  burkes('Burkes', '柔和且高效，适合人像与风景');

  final String label, description;
  const DitherMode(this.label, this.description);
}

class ImageSettings {
  final DitherMode mode;
  final double brightness,
      contrast,
      saturation,
      gamma,
      strength,
      softness,
      naturalMapping,
      paperWhite,
      dynamicRange,
      gamutCompression;
  final PaletteCalibration calibration;
  final int rotation;
  final bool cover, perceptual, serpentine;
  const ImageSettings({
    this.mode = DitherMode.perceptual,
    this.brightness = .1,
    this.contrast = 1.1,
    this.saturation = 1.1,
    this.gamma = 1,
    this.strength = 1,
    this.rotation = 0,
    this.cover = true,
    this.perceptual = true,
    this.serpentine = true,
    this.softness = 1,
    this.naturalMapping = 1,
    this.paperWhite = 0,
    this.calibration = PaletteCalibration.ideal,
    this.dynamicRange = 0,
    this.gamutCompression = 0,
  });
  ImageSettings copyWith({
    DitherMode? mode,
    double? brightness,
    double? contrast,
    double? saturation,
    double? gamma,
    double? strength,
    int? rotation,
    bool? cover,
    bool? perceptual,
    bool? serpentine,
    double? softness,
    double? naturalMapping,
    double? paperWhite,
    PaletteCalibration? calibration,
    double? dynamicRange,
    double? gamutCompression,
  }) => ImageSettings(
    mode: mode ?? this.mode,
    brightness: brightness ?? this.brightness,
    contrast: contrast ?? this.contrast,
    saturation: saturation ?? this.saturation,
    gamma: gamma ?? this.gamma,
    strength: strength ?? this.strength,
    rotation: rotation ?? this.rotation,
    cover: cover ?? this.cover,
    perceptual: perceptual ?? this.perceptual,
    serpentine: serpentine ?? this.serpentine,
    softness: softness ?? this.softness,
    naturalMapping: naturalMapping ?? this.naturalMapping,
    paperWhite: paperWhite ?? this.paperWhite,
    calibration: calibration ?? this.calibration,
    dynamicRange: dynamicRange ?? this.dynamicRange,
    gamutCompression: gamutCompression ?? this.gamutCompression,
  );
  Map<String, dynamic> toJson() => {
    'defaultsVersion': 4,
    'mode': mode.name,
    'brightness': brightness,
    'contrast': contrast,
    'saturation': saturation,
    'gamma': gamma,
    'strength': strength,
    'rotation': rotation,
    'cover': cover,
    'perceptual': perceptual,
    'serpentine': serpentine,
    'softness': softness,
    'naturalMapping': naturalMapping,
    'paperWhite': paperWhite,
    'calibration': calibration.toJson(),
    'dynamicRange': dynamicRange,
    'gamutCompression': gamutCompression,
  };
  factory ImageSettings.fromJson(Map<String, dynamic> json) {
    double value(String key, double fallback, double lo, double hi) {
      final v = json[key];
      return v is num && v.isFinite ? v.toDouble().clamp(lo, hi) : fallback;
    }

    // Migrate discontinued preferences without keeping dead algorithm paths.
    final modeName = switch (json['mode']) {
      'atkinson' => 'burkes',
      'jjn' || 'sierra' => 'stucki',
      'sierraLite' => 'floyd',
      'bayer4' || 'bayer8' => 'blueNoise',
      final name => name,
    };
    final storedVersion = json['defaultsVersion'] is num
        ? (json['defaultsVersion'] as num).toInt()
        : 0;
    final currentDefaults = storedVersion >= 2;
    final previousDefaults = !currentDefaults;
    final brightness = value('brightness', .1, -.3, .3);
    final contrast = value('contrast', 1.1, .5, 1.8);
    final saturation = value('saturation', 1.1, 0, 2);
    final storedStrength = value('strength', 1, 0, 1);
    // Versions 1–3 shipped with strength=0 as their default. That value is
    // indistinguishable from an old untouched preference, so migrate it to
    // the new full-strength default. Version 4 preserves explicit edits.
    final strength = storedVersion < 4 && storedStrength == 0
        ? 1.0
        : storedStrength;
    return ImageSettings(
      mode:
          DitherMode.values.where((m) => m.name == modeName).firstOrNull ??
          DitherMode.perceptual,
      brightness: previousDefaults && brightness == 0 ? .1 : brightness,
      contrast: previousDefaults && contrast == 1 ? 1.1 : contrast,
      saturation: previousDefaults && saturation == 1 ? 1.1 : saturation,
      gamma: value('gamma', 1, .5, 2),
      strength: strength,
      rotation: json['rotation'] is int ? (json['rotation'] as int) % 4 : 0,
      cover: currentDefaults ? json['cover'] != false : true,
      perceptual: json['perceptual'] != false,
      serpentine: json['serpentine'] != false,
      softness: currentDefaults ? value('softness', 1, 0, 1) : 1,
      naturalMapping: currentDefaults ? value('naturalMapping', 1, 0, 1) : 1,
      paperWhite: currentDefaults ? value('paperWhite', 0, 0, .15) : 0,
      calibration: PaletteCalibration.fromJson(json['calibration']),
      dynamicRange: value('dynamicRange', 0, 0, 1),
      gamutCompression: value('gamutCompression', 0, 0, 1),
    );
  }
}

class ProcessRequest {
  final Uint8List? source;
  final ImageSettings settings;
  final int width, height;
  final CropSpec? crop;
  const ProcessRequest(
    this.source,
    this.settings, {
    this.width = epdWidth,
    this.height = epdHeight,
    this.crop,
  });
}

class ProcessedImage {
  final Uint8List preview, original, packed, indices;
  final List<int> counts;
  final int milliseconds;
  final Reconstruction? reconstruction;
  const ProcessedImage(
    this.preview,
    this.original,
    this.packed,
    this.indices,
    this.counts,
    this.milliseconds, [
    this.reconstruction,
  ]);
}

const palette = <List<double>>[
  [0, 0, 0],
  [1, 1, 1],
  [1, 1, 0],
  [1, 0, 0],
];

List<List<double>> effectivePalette(ImageSettings s) =>
    s.calibration.enabled && s.calibration.valid
    ? s.calibration.colors
    : palette;

// dx,dy,numerator. Error is distributed in RGB; the nearest palette entry can
// be selected in OKLab. Three retained diffusion kernels use full error weight.
const _kernels = <DitherMode, List<List<int>>>{
  DitherMode.floyd: [
    [1, 0, 7],
    [-1, 1, 3],
    [0, 1, 5],
    [1, 1, 1],
  ],
  DitherMode.stucki: [
    [1, 0, 8],
    [2, 0, 4],
    [-2, 1, 2],
    [-1, 1, 4],
    [0, 1, 8],
    [1, 1, 4],
    [2, 1, 2],
    [-2, 2, 1],
    [-1, 2, 2],
    [0, 2, 4],
    [1, 2, 2],
    [2, 2, 1],
  ],
  DitherMode.burkes: [
    [1, 0, 8],
    [2, 0, 4],
    [-2, 1, 2],
    [-1, 1, 4],
    [0, 1, 8],
    [1, 1, 4],
    [2, 1, 2],
  ],
};
const _divisors = <DitherMode, int>{
  DitherMode.floyd: 16,
  DitherMode.stucki: 42,
  DitherMode.burkes: 32,
};

double _linear(double c) => linearLight(c);
double _encodeLinear(double c) => srgbFromLinear(c);
double _adjustChannel(double source, double luminance, ImageSettings s) {
  var v = luminance + (source - luminance) * s.saturation;
  v = ((v - .5) * s.contrast + .5 + s.brightness).clamp(0, 1);
  if (s.gamma != 1) v = math.pow(v, 1 / s.gamma).toDouble();
  return linearLight(v);
}

List<double> _oklab(double r, double g, double b) {
  r = _linear(r);
  g = _linear(g);
  b = _linear(b);
  final l = cubeRoot(.4122214708 * r + .5363325363 * g + .0514459929 * b);
  final m = cubeRoot(.2119034982 * r + .6806995451 * g + .1073969566 * b);
  final s = cubeRoot(.0883024619 * r + .2817188376 * g + .6299787005 * b);
  return [
    .2104542553 * l + .793617785 * m - .0040720468 * s,
    1.9779984951 * l - 2.428592205 * m + .4505937099 * s,
    .0259040371 * l + .7827717662 * m - .808675766 * s,
  ];
}

int nearestColor(
  double r,
  double g,
  double b,
  bool perceptual, {
  double chromaPenalty = 0,
  bool monochrome = false,
  List<List<double>> colors = palette,
  List<List<double>>? labColors,
}) {
  final p = perceptual ? _oklab(r, g, b) : [r, g, b];
  final metricColors = perceptual
      ? (labColors ?? colors.map((c) => _oklab(c[0], c[1], c[2])).toList())
      : colors;
  var best = double.infinity, index = 0;
  for (var i = 0; i < 4; i++) {
    if (monochrome && i >= 2) continue;
    final c = metricColors[i];
    final a = p[0] - c[0], d = p[1] - c[1], e = p[2] - c[2];
    // Penalize chroma twice per axis so neutral gray does not become red merely
    // because the four-entry palette has a large luminance gap.
    final chromaWeight = perceptual ? 4.0 : 1.0;
    final distance =
        a * a + chromaWeight * (d * d + e * e) + (i >= 2 ? chromaPenalty : 0);
    if (distance < best) {
      best = distance;
      index = i;
    }
  }
  return index;
}

Uint8List packIndices(List<int> pixels) {
  if (pixels.length % 4 != 0) throw ArgumentError('像素总数必须为 4 的倍数');
  final out = Uint8List(pixels.length ~/ 4);
  for (var i = 0; i < pixels.length; i += 4) {
    if ((pixels[i] | pixels[i + 1] | pixels[i + 2] | pixels[i + 3]) & ~3 != 0) {
      throw ArgumentError('非法色号');
    }
    out[i ~/ 4] =
        (pixels[i] << 6) |
        (pixels[i + 1] << 4) |
        (pixels[i + 2] << 2) |
        pixels[i + 3];
  }
  return out;
}

/// Encodes the preview as a four-entry, 2-bit indexed PNG. The preview only
/// contains the panel palette, so creating a 24-bit RGB image and asking the
/// PNG encoder to rediscover that palette wastes both CPU and memory.
Uint8List _encodePreview(
  Uint8List indices,
  int w,
  int h,
  List<List<double>> inks,
) {
  final palette = img.PaletteUint8(4, 3);
  for (var i = 0; i < 4; i++) {
    palette.setRgb(
      i,
      (inks[i][0] * 255).round(),
      (inks[i][1] * 255).round(),
      (inks[i][2] * 255).round(),
    );
  }
  final output = img.Image(
    width: w,
    height: h,
    format: img.Format.uint2,
    palette: palette,
  );
  final data = output.data! as img.ImageDataUint2;
  for (var y = 0; y < h; y++) {
    final source = y * w;
    final target = y * data.rowStride;
    for (var x = 0; x < w; x += 4) {
      var packed = indices[source + x] << 6;
      if (x + 1 < w) packed |= indices[source + x + 1] << 4;
      if (x + 2 < w) packed |= indices[source + x + 2] << 2;
      if (x + 3 < w) packed |= indices[source + x + 3];
      data.data[target + (x >> 2)] = packed;
    }
  }
  return Uint8List.fromList(img.encodePng(output));
}

/// Prepared at final panel resolution, before color adjustment. Reused by AUTO.
class PreparedImage {
  final Float32List rgb;
  final Uint8List original;
  final int width, height;
  Float32List? _adjustedRgb;
  NaturalMapping? _natural;
  String? _adjustmentKey;
  PreparedImage(this.rgb, this.original, this.width, this.height);
}

String _adjustmentKey(ImageSettings s) =>
    '${s.brightness}|${s.contrast}|${s.saturation}|${s.gamma}|'
    '${s.dynamicRange}|${s.naturalMapping}';

({Float32List rgb, NaturalMapping? natural}) _adjustedImage(
  PreparedImage prepared,
  ImageSettings s,
) {
  final key = _adjustmentKey(s);
  if (prepared._adjustmentKey == key && prepared._adjustedRgb != null) {
    return (rgb: prepared._adjustedRgb!, natural: prepared._natural);
  }
  final w = prepared.width, h = prepared.height;
  final rgb = Float32List(prepared.rgb.length);
  for (var i = 0; i < w * h; i++) {
    final at = i * 3;
    final l =
        .2126 * prepared.rgb[at] +
        .7152 * prepared.rgb[at + 1] +
        .0722 * prepared.rgb[at + 2];
    var lr = _adjustChannel(prepared.rgb[at], l, s);
    var lg = _adjustChannel(prepared.rgb[at + 1], l, s);
    var lb = _adjustChannel(prepared.rgb[at + 2], l, s);
    if (s.dynamicRange > 0) {
      final y = .2126 * lr + .7152 * lg + .0722 * lb;
      final amount = s.dynamicRange.clamp(0.0, 1.0);
      final tone = math.sqrt(y);
      final mappedTone =
          tone + amount * .6 * tone * (1 - tone) * (1 - 2 * tone);
      final targetY = mappedTone * mappedTone;
      var scale = y < 1e-10 ? 1.0 : targetY / y;
      if (lr > y) scale = math.min(scale, (1 - targetY) / (lr - y));
      if (lg > y) scale = math.min(scale, (1 - targetY) / (lg - y));
      if (lb > y) scale = math.min(scale, (1 - targetY) / (lb - y));
      lr = (targetY + (lr - y) * scale).clamp(0.0, 1.0);
      lg = (targetY + (lg - y) * scale).clamp(0.0, 1.0);
      lb = (targetY + (lb - y) * scale).clamp(0.0, 1.0);
    }
    rgb[at] = _encodeLinear(lr).clamp(0.0, 1.0);
    rgb[at + 1] = _encodeLinear(lg).clamp(0.0, 1.0);
    rgb[at + 2] = _encodeLinear(lb).clamp(0.0, 1.0);
  }
  final natural = s.naturalMapping > 0
      ? applyNaturalMapping(rgb, s.naturalMapping)
      : null;
  prepared._adjustedRgb = rgb;
  prepared._natural = natural;
  prepared._adjustmentKey = key;
  return (rgb: rgb, natural: natural);
}

int _nearestColorFast(
  double r,
  double g,
  double b,
  bool perceptual, {
  double chromaPenalty = 0,
  bool monochrome = false,
  required List<double> colors,
  required List<double> labColors,
}) {
  var p0 = r, p1 = g, p2 = b;
  if (perceptual) {
    r = linearLight(r);
    g = linearLight(g);
    b = linearLight(b);
    final l = cubeRoot(.4122214708 * r + .5363325363 * g + .0514459929 * b);
    final m = cubeRoot(.2119034982 * r + .6806995451 * g + .1073969566 * b);
    final q = cubeRoot(.0883024619 * r + .2817188376 * g + .6299787005 * b);
    p0 = .2104542553 * l + .793617785 * m - .0040720468 * q;
    p1 = 1.9779984951 * l - 2.428592205 * m + .4505937099 * q;
    p2 = .0259040371 * l + .7827717662 * m - .808675766 * q;
  }
  var best = double.infinity, index = 0;
  final chromaWeight = perceptual ? 4.0 : 1.0;
  for (var i = 0; i < 4; i++) {
    if (monochrome && i >= 2) continue;
    final base = i * 3;
    final metrics = perceptual ? labColors : colors;
    final c0 = metrics[base], c1 = metrics[base + 1], c2 = metrics[base + 2];
    final a = p0 - c0, d = p1 - c1, e = p2 - c2;
    final distance =
        a * a + chromaWeight * (d * d + e * e) + (i >= 2 ? chromaPenalty : 0);
    if (distance < best) {
      best = distance;
      index = i;
    }
  }
  return index;
}

/// Runs in a background isolate; no Flutter widgets or native plugins.
ProcessedImage processImage(ProcessRequest request) {
  final clock = Stopwatch()..start();
  final prepared = prepareImage(request);
  return processPrepared(
    prepared,
    request.settings,
    preparationMilliseconds: clock.elapsedMilliseconds,
  );
}

PreparedImage prepareImage(ProcessRequest request) {
  final s = request.settings, w = request.width, h = request.height;
  if (w <= 0 || h <= 0 || w % 4 != 0 || w * h > 2000000) {
    throw ArgumentError('输出尺寸不合法');
  }
  img.Image source;
  if (request.source == null) {
    source = demoImage();
  } else {
    source = decodeSource(request.source!);
  }
  if (s.rotation != 0) source = img.copyRotate(source, angle: 90 * s.rotation);
  if (request.crop != null) {
    source = frameImage(source, request.crop!, w, h, cover: s.cover);
  }
  // Crop before resizing: a 1 x 24000 panorama must not allocate a gigantic
  // intermediate image in cover mode.
  if (s.cover) {
    final cropWidth = math.min(
      source.width,
      math.max(1, (source.height * w / h).round()),
    );
    final cropHeight = math.min(
      source.height,
      math.max(1, (source.width * h / w).round()),
    );
    source = img.copyCrop(
      source,
      x: (source.width - cropWidth) ~/ 2,
      y: (source.height - cropHeight) ~/ 2,
      width: cropWidth,
      height: cropHeight,
    );
  }
  final ratio = math.min(w / source.width, h / source.height);
  final resized = img.copyResize(
    source,
    width: s.cover ? w : math.max(1, (source.width * ratio).round()),
    height: s.cover ? h : math.max(1, (source.height * ratio).round()),
    interpolation: img.Interpolation.average,
  );
  final rgb = Float32List(w * h * 3);
  final original = img.Image(width: w, height: h, numChannels: 3);
  final dx = ((w - resized.width) / 2).floor(),
      dy = ((h - resized.height) / 2).floor();
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final sx = x - dx, sy = y - dy;
      var r = 1.0, g = 1.0, b = 1.0;
      if (sx >= 0 && sy >= 0 && sx < resized.width && sy < resized.height) {
        final p = resized.getPixel(sx, sy);
        final a = p.aNormalized.toDouble();
        r = p.rNormalized * a + 1 - a;
        g = p.gNormalized * a + 1 - a;
        b = p.bNormalized * a + 1 - a;
      }
      original.setPixelRgb(
        x,
        y,
        (r * 255).round(),
        (g * 255).round(),
        (b * 255).round(),
      );
      final at = (y * w + x) * 3;
      rgb[at] = r;
      rgb[at + 1] = g;
      rgb[at + 2] = b;
    }
  }
  return PreparedImage(rgb, Uint8List.fromList(img.encodePng(original)), w, h);
}

ProcessedImage processPrepared(
  PreparedImage prepared,
  ImageSettings s, {
  int preparationMilliseconds = 0,
}) {
  final clock = Stopwatch()..start();
  final w = prepared.width, h = prepared.height;
  final adjusted = _adjustedImage(prepared, s);
  // Diffusion modifies its working buffer. DBS and blue-noise only read it,
  // so they can use the cached adjusted image directly.
  final rgb = s.mode == DitherMode.perceptual || s.mode == DitherMode.blueNoise
      ? adjusted.rgb
      : Float32List.fromList(adjusted.rgb);
  final inks = effectivePalette(s);
  final colors = <double>[for (final c in inks) ...c];
  final labColors = <double>[for (final c in inks) ..._oklab(c[0], c[1], c[2])];
  final natural = adjusted.natural;
  final indices = Uint8List(w * h), counts = List.filled(4, 0);
  if (s.mode == DitherMode.perceptual || s.mode == DitherMode.blueNoise) {
    final result = reconstruct(
      rgb,
      w,
      h,
      optimize: s.mode == DitherMode.perceptual,
      // DBS is a global neighbourhood search. One pass gives most of its
      // visual benefit at panel resolution while keeping interactive edits in
      // the one-second class on slower CPUs; small images retain full quality.
      maxPasses: w * h > 100000 ? 1 : 3,
      softness: s.softness,
      paperWhite: s.paperWhite,
      // reconstruct performs the single sRGB -> linear conversion.
      inks: inks,
      gamutCompression: s.gamutCompression,
    );
    for (var i = 0; i < w * h; i++) {
      final index = result.indices[i];
      counts[index]++;
    }
    return ProcessedImage(
      _encodePreview(result.indices, w, h, inks),
      prepared.original,
      packIndices(result.indices),
      result.indices,
      counts,
      clock.elapsedMilliseconds + preparationMilliseconds,
      result,
    );
  }
  final kernel = _kernels[s.mode];
  final divisor = (_divisors[s.mode] ?? 1).toDouble();
  final protection = natural?.protection;
  final neutral = natural?.neutral;
  for (var y = 0; y < h; y++) {
    final reverse = s.serpentine && y.isOdd && kernel != null;
    for (var step = 0; step < w; step++) {
      final x = reverse ? w - 1 - step : step, at = (y * w + x) * 3;
      final r = rgb[at].clamp(0.0, 1.0),
          g = rgb[at + 1].clamp(0.0, 1.0),
          b = rgb[at + 2].clamp(0.0, 1.0);
      final pixel = y * w + x;
      final index = _nearestColorFast(
        r,
        g,
        b,
        s.perceptual,
        chromaPenalty: .25 * (protection?[pixel] ?? 0),
        monochrome: neutral?[pixel] == 1,
        colors: colors,
        labColors: labColors,
      );
      final color = inks[index];
      indices[pixel] = index;
      counts[index]++;
      if (kernel != null && s.strength > 0) {
        final er = r - color[0], eg = g - color[1], eb = b - color[2];
        final luminanceError = .2126 * er + .7152 * eg + .0722 * eb;
        for (final weight in kernel) {
          final nx = x + (reverse ? -weight[0] : weight[0]), ny = y + weight[1];
          if (nx < 0 || nx >= w || ny >= h) continue;
          final target = (ny * w + nx) * 3,
              amount = weight[2] / divisor * s.strength;
          // Preserve encoded-RGB error luminance while reducing color leakage
          // into neutral/cool neighbors. The original kernels are unchanged.
          final neighbor = ny * w + nx;
          final retain = 1 - (protection?[neighbor] ?? 0);
          final tr = natural == null
              ? er
              : luminanceError + (er - luminanceError) * retain;
          final tg = natural == null
              ? eg
              : luminanceError + (eg - luminanceError) * retain;
          final tb = natural == null
              ? eb
              : luminanceError + (eb - luminanceError) * retain;
          rgb[target] += tr * amount;
          rgb[target + 1] += tg * amount;
          rgb[target + 2] += tb * amount;
        }
      }
    }
  }
  return ProcessedImage(
    _encodePreview(indices, w, h, inks),
    prepared.original,
    packIndices(indices),
    indices,
    counts,
    clock.elapsedMilliseconds + preparationMilliseconds,
  );
}

/// Local geometric sample, generated without a network or bundled photo license.
Uint8List sampleSource(Object? _) =>
    Uint8List.fromList(img.encodePng(demoImage()));
img.Image demoImage() {
  const w = 768, h = 552;
  final image = img.Image(width: w, height: h, numChannels: 3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final t = y / h;
      var r = 248 - 20 * t, g = 231 - 34 * t, b = 192 - 39 * t;
      if (math.pow(x - 530, 2) + math.pow(y - 170, 2) < math.pow(74, 2)) {
        r = 218;
        g = 85;
        b = 52;
      }
      final ridge1 = 310 + 44 * math.sin(x / 112) + 26 * math.sin(x / 47);
      final ridge2 = 375 + 34 * math.sin(x / 95 + 2) + 19 * math.cos(x / 31);
      final ridge3 = 460 + 32 * math.sin(x / 133 + 4);
      if (y > ridge1) {
        r = 175;
        g = 143;
        b = 111;
      }
      if (y > ridge2) {
        r = 92;
        g = 106;
        b = 95;
      }
      if (y > ridge3) {
        r = 36;
        g = 57;
        b = 52;
      }
      if (x < 28 || x >= w - 28 || y < 28 || y >= h - 28) {
        r = 250;
        g = 247;
        b = 238;
      }
      image.setPixelRgb(x, y, r.round(), g.round(), b.round());
    }
  }
  return image;
}
