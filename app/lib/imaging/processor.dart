import 'dart:math' as math;
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import '../protocol/codec.dart';
import 'geometry.dart';
import 'reconstruction.dart';

enum DitherMode {
  perceptual('感知重建 · DBS', '优化观看尺度下的颜色与网点，计算较慢'),
  blueNoise('蓝噪声 · 色彩覆盖', '线性光混色，减少规则纹理与误差串色'),
  none('直接量化', '清晰文字与色块，保留干净边缘'),
  floyd('Floyd–Steinberg', '均衡细节与层次，适合大多数照片'),
  atkinson('Atkinson', '轻盈颗粒与鲜明对比，适合插画'),
  jjn('Jarvis–Judice–Ninke', '大范围扩散，柔和呈现渐变'),
  stucki('Stucki', '平滑层次，同时保留较多细节'),
  burkes('Burkes', '柔和且高效，适合人像与风景'),
  sierra('Sierra', '细腻均匀的误差扩散'),
  sierraLite('Sierra Lite', '轻量扩散，适合线条与图标'),
  bayer4('Bayer 4×4', '规则网点，带有复古印刷质感'),
  bayer8('Bayer 8×8', '更细的有序网点与稳定纹理');

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
      paperWhite;
  final int rotation;
  final bool cover, perceptual, serpentine;
  const ImageSettings({
    this.mode = DitherMode.perceptual,
    this.brightness = 0,
    this.contrast = 1,
    this.saturation = 1,
    this.gamma = 1,
    this.strength = 1,
    this.rotation = 0,
    this.cover = false,
    this.perceptual = true,
    this.serpentine = true,
    this.softness = .5,
    this.paperWhite = .07,
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
    double? paperWhite,
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
    paperWhite: paperWhite ?? this.paperWhite,
  );
  Map<String, dynamic> toJson() => {
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
    'paperWhite': paperWhite,
  };
  factory ImageSettings.fromJson(Map<String, dynamic> json) {
    double value(String key, double fallback, double lo, double hi) {
      final v = json[key];
      return v is num && v.isFinite ? v.toDouble().clamp(lo, hi) : fallback;
    }

    return ImageSettings(
      mode:
          DitherMode.values.where((m) => m.name == json['mode']).firstOrNull ??
          DitherMode.perceptual,
      brightness: value('brightness', 0, -.3, .3),
      contrast: value('contrast', 1, .5, 1.8),
      saturation: value('saturation', 1, 0, 2),
      gamma: value('gamma', 1, .5, 2),
      strength: value('strength', 1, 0, 1),
      rotation: json['rotation'] is int ? (json['rotation'] as int) % 4 : 0,
      cover: json['cover'] == true,
      perceptual: json['perceptual'] != false,
      serpentine: json['serpentine'] != false,
      softness: value('softness', .5, 0, 1),
      paperWhite: value('paperWhite', .07, 0, .15),
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
// dx,dy,numerator. Error is distributed in RGB; the nearest palette entry can
// be selected in OKLab. Atkinson intentionally propagates only 6/8 of error.
const _kernels = <DitherMode, List<List<int>>>{
  DitherMode.floyd: [
    [1, 0, 7],
    [-1, 1, 3],
    [0, 1, 5],
    [1, 1, 1],
  ],
  DitherMode.atkinson: [
    [1, 0, 1],
    [2, 0, 1],
    [-1, 1, 1],
    [0, 1, 1],
    [1, 1, 1],
    [0, 2, 1],
  ],
  DitherMode.jjn: [
    [1, 0, 7],
    [2, 0, 5],
    [-2, 1, 3],
    [-1, 1, 5],
    [0, 1, 7],
    [1, 1, 5],
    [2, 1, 3],
    [-2, 2, 1],
    [-1, 2, 3],
    [0, 2, 5],
    [1, 2, 3],
    [2, 2, 1],
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
  DitherMode.sierra: [
    [1, 0, 5],
    [2, 0, 3],
    [-2, 1, 2],
    [-1, 1, 4],
    [0, 1, 5],
    [1, 1, 4],
    [2, 1, 2],
    [-1, 2, 2],
    [0, 2, 3],
    [1, 2, 2],
  ],
  DitherMode.sierraLite: [
    [1, 0, 2],
    [-1, 1, 1],
    [0, 1, 1],
  ],
};
const _divisors = <DitherMode, int>{
  DitherMode.floyd: 16,
  DitherMode.atkinson: 8,
  DitherMode.jjn: 48,
  DitherMode.stucki: 42,
  DitherMode.burkes: 32,
  DitherMode.sierra: 32,
  DitherMode.sierraLite: 4,
};

double _linear(double c) =>
    c <= .04045 ? c / 12.92 : math.pow((c + .055) / 1.055, 2.4).toDouble();
List<double> _oklab(double r, double g, double b) {
  r = _linear(r);
  g = _linear(g);
  b = _linear(b);
  final l = math
      .pow(.4122214708 * r + .5363325363 * g + .0514459929 * b, 1 / 3)
      .toDouble();
  final m = math
      .pow(.2119034982 * r + .6806995451 * g + .1073969566 * b, 1 / 3)
      .toDouble();
  final s = math
      .pow(.0883024619 * r + .2817188376 * g + .6299787005 * b, 1 / 3)
      .toDouble();
  return [
    .2104542553 * l + .793617785 * m - .0040720468 * s,
    1.9779984951 * l - 2.428592205 * m + .4505937099 * s,
    .0259040371 * l + .7827717662 * m - .808675766 * s,
  ];
}

final _labPalette = palette.map((c) => _oklab(c[0], c[1], c[2])).toList();

int nearestColor(double r, double g, double b, bool perceptual) {
  final p = perceptual ? _oklab(r, g, b) : [r, g, b];
  final colors = perceptual ? _labPalette : palette;
  var best = double.infinity, index = 0;
  for (var i = 0; i < 4; i++) {
    final c = colors[i];
    final a = p[0] - c[0], d = p[1] - c[1], e = p[2] - c[2];
    // Penalize chroma twice per axis so neutral gray does not become red merely
    // because the four-entry palette has a large luminance gap.
    final chromaWeight = perceptual ? 4.0 : 1.0;
    final distance = a * a + chromaWeight * (d * d + e * e);
    if (distance < best) {
      best = distance;
      index = i;
    }
  }
  return index;
}

List<List<int>> bayerMatrix(int size) {
  var matrix = <List<int>>[
    [0],
  ];
  while (matrix.length < size) {
    final n = matrix.length;
    final next = List.generate(n * 2, (_) => List.filled(n * 2, 0));
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        final v = matrix[y][x] * 4;
        next[y][x] = v;
        next[y][x + n] = v + 2;
        next[y + n][x] = v + 3;
        next[y + n][x + n] = v + 1;
      }
    }
    matrix = next;
  }
  return matrix;
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

/// Runs in a background isolate; no Flutter widgets or native plugins used here.
ProcessedImage processImage(ProcessRequest request) {
  final clock = Stopwatch()..start();
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
      final l = .2126 * r + .7152 * g + .0722 * b;
      final channels = [r, g, b];
      for (var c = 0; c < 3; c++) {
        var v = l + (channels[c] - l) * s.saturation;
        v = ((v - .5) * s.contrast + .5 + s.brightness).clamp(0, 1);
        rgb[(y * w + x) * 3 + c] = math.pow(v, 1 / s.gamma).toDouble();
      }
    }
  }
  final indices = Uint8List(w * h), counts = List.filled(4, 0);
  final output = img.Image(width: w, height: h, numChannels: 3);
  if (s.mode == DitherMode.perceptual || s.mode == DitherMode.blueNoise) {
    final result = reconstruct(
      rgb,
      w,
      h,
      optimize: s.mode == DitherMode.perceptual,
      softness: s.softness,
      paperWhite: s.paperWhite,
    );
    for (var i = 0; i < w * h; i++) {
      final index = result.indices[i], color = palette[index];
      counts[index]++;
      output.setPixelRgb(
        i % w,
        i ~/ w,
        (color[0] * 255).round(),
        (color[1] * 255).round(),
        (color[2] * 255).round(),
      );
    }
    return ProcessedImage(
      Uint8List.fromList(img.encodePng(output)),
      Uint8List.fromList(img.encodePng(original)),
      packIndices(result.indices),
      result.indices,
      counts,
      clock.elapsedMilliseconds,
      result,
    );
  }
  final kernel = _kernels[s.mode];
  final divisor = (_divisors[s.mode] ?? 1).toDouble();
  final ordered = s.mode == DitherMode.bayer4 || s.mode == DitherMode.bayer8;
  final matrix = bayerMatrix(s.mode == DitherMode.bayer8 ? 8 : 4);
  for (var y = 0; y < h; y++) {
    final reverse = s.serpentine && y.isOdd && kernel != null;
    for (var step = 0; step < w; step++) {
      final x = reverse ? w - 1 - step : step, at = (y * w + x) * 3;
      final threshold = ordered
          ? ((matrix[y % matrix.length][x % matrix.length] + .5) /
                        (matrix.length * matrix.length) -
                    .5) *
                .6 *
                s.strength
          : 0.0;
      double adjusted(double v) {
        // Taper ordered noise at gamut corners, preserving exact BWYR pixels.
        final noise = threshold * 4 * v.clamp(0, 1) * (1 - v.clamp(0, 1));
        return (v + noise).clamp(0.0, 1.0);
      }

      final r = adjusted(rgb[at]),
          g = adjusted(rgb[at + 1]),
          b = adjusted(rgb[at + 2]);
      final index = nearestColor(r, g, b, s.perceptual);
      final color = palette[index];
      indices[y * w + x] = index;
      counts[index]++;
      output.setPixelRgb(
        x,
        y,
        (color[0] * 255).round(),
        (color[1] * 255).round(),
        (color[2] * 255).round(),
      );
      if (kernel != null && s.strength > 0) {
        final error = [r - color[0], g - color[1], b - color[2]];
        for (final weight in kernel) {
          final nx = x + (reverse ? -weight[0] : weight[0]), ny = y + weight[1];
          if (nx < 0 || nx >= w || ny >= h) continue;
          final target = (ny * w + nx) * 3,
              amount = weight[2] / divisor * s.strength;
          for (var c = 0; c < 3; c++) {
            rgb[target + c] += error[c] * amount;
          }
        }
      }
    }
  }
  return ProcessedImage(
    Uint8List.fromList(img.encodePng(output)),
    Uint8List.fromList(img.encodePng(original)),
    packIndices(indices),
    indices,
    counts,
    clock.elapsedMilliseconds,
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
