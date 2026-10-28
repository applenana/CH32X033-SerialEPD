// DBS mathematics adapted from OpenDisplay epaper-dithering dbs.rs and
// OpenDithering by Guy Sie (MIT). See assets/licenses/reconstruction.txt.
// Coverage projection and blue-noise sampling are specific to the BWYR tetrahedron.
import 'dart:math' as math;
import 'dart:typed_data';
import 'blue_noise.dart';

const _inks = [
  [0.0, 0.0, 0.0],
  [1.0, 1.0, 1.0],
  [1.0, 1.0, 0.0],
  [1.0, 0.0, 0.0],
];
double linearLight(double c) =>
    c <= .04045 ? c / 12.92 : math.pow((c + .055) / 1.055, 2.4).toDouble();

/// Weighted isotonic projection into 0 <= B <= G <= R <= 1.
/// Unlike clipping RGB channels, pooling conserves source linear luminance.
List<double> projectGamut(double r, double g, double b) {
  if (r < g) {
    r = g = (.2126 * r + .7152 * g) / .9278;
    if (g < b) {
      r = g = b = .9278 * g + .0722 * b;
    }
  } else if (g < b) {
    g = b = (.7152 * g + .0722 * b) / .7874;
    if (r < g) {
      r = g = b = .2126 * r + .7874 * g;
    }
  }
  return [r, g, b];
}

List<double> coverage(double r, double g, double b) {
  final c = projectGamut(r, g, b);
  return [1 - c[0], c[2], c[1] - c[2], c[0] - c[1]];
}

/// Linear RGB -> normalized linear opponent space (Yy,Cx,Cz).
/// Chromatic differences are averaged in light, not gamma-encoded RGB.
List<double> opponent(double r, double g, double b) {
  final x = .4124564 * r + .3575761 * g + .1804375 * b;
  final y = .2126729 * r + .7151522 * g + .0721750 * b;
  final z = .0193339 * r + .1191920 * g + .9503041 * b;
  return [y, 500 / 116 * (x / .95047 - y), 200 / 116 * (y - z / 1.08883)];
}

class Reconstruction {
  final Uint8List indices;
  final double initialError, finalError;
  final int passes;
  const Reconstruction(
    this.indices,
    this.initialError,
    this.finalError,
    this.passes,
  );
}

class _Kernel {
  final int radius;
  final List<double> line;
  late final int size = line.length;
  late final Float64List square = Float64List.fromList([
    for (final y in line)
      for (final x in line) y * x,
  ]);
  _Kernel(this.radius, this.line);
  double at(int x, int y) => square[(y + radius) * size + x + radius];
}

_Kernel _correlation(double sigma) {
  final r = (2.5 * sigma).ceil();
  final g = [
    for (var i = -r; i <= r; i++) math.exp(-i * i / (2 * sigma * sigma)),
  ];
  final sum = g.reduce((a, b) => a + b);
  for (var i = 0; i < g.length; i++) {
    g[i] /= sum;
  }
  final line = List.filled(4 * r + 1, 0.0);
  for (var d = -2 * r; d <= 2 * r; d++) {
    for (var j = 0; j < g.length; j++) {
      final k = j + d;
      if (k >= 0 && k < g.length) line[d + 2 * r] += g[j] * g[k];
    }
  }
  return _Kernel(2 * r, line);
}

Float64List _correlate(Float64List input, int w, int h, _Kernel k) {
  final tmp = Float64List(input.length),
      out = Float64List(input.length),
      r = k.radius;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var sum = 0.0;
      for (var d = math.max(-r, -x); d <= math.min(r, w - 1 - x); d++) {
        sum += input[y * w + x + d] * k.line[d + r];
      }
      tmp[y * w + x] = sum;
    }
  }
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var sum = 0.0;
      for (var d = math.max(-r, -y); d <= math.min(r, h - 1 - y); d++) {
        sum += tmp[(y + d) * w + x] * k.line[d + r];
      }
      out[y * w + x] = sum;
    }
  }
  return out;
}

List<double> _solvePaletteWeights(List<double> point, List<List<double>> inks) {
  final a = List.generate(
    4,
    (row) => [
      for (var col = 0; col < 4; col++) row == 3 ? 1.0 : inks[col][row],
    ],
  );
  final b = [...point, 1.0];
  for (var col = 0; col < 4; col++) {
    var pivot = col;
    for (var row = col + 1; row < 4; row++) {
      if (a[row][col].abs() > a[pivot][col].abs()) pivot = row;
    }
    if (a[pivot][col].abs() < 1e-8) return const [1, 0, 0, 0];
    final tmp = a[col];
    a[col] = a[pivot];
    a[pivot] = tmp;
    final bv = b[col];
    b[col] = b[pivot];
    b[pivot] = bv;
    final div = a[col][col];
    for (var j = col; j < 4; j++) {
      a[col][j] /= div;
    }
    b[col] /= div;
    for (var row = 0; row < 4; row++) {
      if (row == col) continue;
      final f = a[row][col];
      for (var j = col; j < 4; j++) {
        a[row][j] -= f * a[col][j];
      }
      b[row] -= f * b[col];
    }
  }
  return b;
}

List<double> paletteCoverage(List<double> point, List<List<double>> inks) {
  final weights = _solvePaletteWeights(
    point,
    inks,
  ).map((v) => math.max(0, v)).toList();
  final sum = weights.fold(0.0, (a, b) => a + b);
  if (sum <= 1e-8) return [1, 0, 0, 0];
  return weights.map((v) => v / sum).toList();
}

double _luminance(List<double> c) => .2126 * c[0] + .7152 * c[1] + .0722 * c[2];

/// Map in linear light. Compression interpolates toward a hue ray clipped at
/// the measured simplex boundary, with a constant attainable luminance.
List<double> projectToPalette(
  double r,
  double g,
  double b,
  List<List<double>> inks,
  double compression,
) {
  final original = [r, g, b];
  final raw = _solvePaletteWeights(original, inks);
  if (raw.every((v) => v >= -1e-10)) return original;
  final levels = inks.map(_luminance).toList();
  var low = 0, high = 0;
  for (var i = 1; i < 4; i++) {
    if (levels[i] < levels[low]) low = i;
    if (levels[i] > levels[high]) high = i;
  }
  final y = _luminance(original).clamp(levels[low], levels[high]);
  final weights = paletteCoverage(original, inks);
  final currentY = List.generate(
    4,
    (i) => weights[i] * levels[i],
  ).reduce((a, b) => a + b);
  // Correct the clipped projection by a convex mixture, never RGB clipping.
  final end = currentY < y ? high : low;
  final delta = levels[end] - currentY;
  final correction = delta.abs() < 1e-12
      ? 0.0
      : ((y - currentY) / delta).clamp(0.0, 1.0);
  for (var i = 0; i < 4; i++) {
    weights[i] = weights[i] * (1 - correction) + (i == end ? correction : 0);
  }
  final span = levels[high] - levels[low];
  final white = span < 1e-12 ? 0.0 : (y - levels[low]) / span;
  final anchor = List.filled(4, 0.0);
  anchor[low] = 1 - white;
  anchor[high] += white;
  // The line from the panel neutral axis to the source hits a face when a
  // barycentric weight becomes zero. No arbitrary 90% desaturation factor.
  var extent = 1.0;
  for (var i = 0; i < 4; i++) {
    if (raw[i] < 0) extent = math.min(extent, anchor[i] / (anchor[i] - raw[i]));
  }
  final amount = compression.clamp(0.0, 1.0);
  // For unreachable luminance use the attainable endpoint, not the raw ray.
  if ((_luminance(original) - y).abs() < 1e-10) {
    for (var i = 0; i < 4; i++) {
      final ray = anchor[i] + extent * (raw[i] - anchor[i]);
      weights[i] = weights[i] * (1 - amount) + ray * amount;
    }
  }
  return [
    for (var c = 0; c < 3; c++)
      List.generate(4, (i) => weights[i] * inks[i][c]).reduce((a, b) => a + b),
  ];
}

/// Soft photo reproduction: gamut-map first, sample a spatial blue-noise rank
/// distribution, optionally minimize a visual error by neighbor swaps.
/// Swaps preserve the initial ink coverage, avoiding unconstrained DBS tone
/// drift. No random state; identical input always gives same bits.
Reconstruction reconstruct(
  Float32List rgb,
  int w,
  int h, {
  bool optimize = false,
  double softness = 1,
  double paperWhite = 0,
  int maxPasses = 3,
  List<List<double>> inks = _inks,
  double dynamicRange = 0,
  double gamutCompression = 0,
}) {
  final n = w * h,
      indices = Uint8List(n),
      pinned = Uint8List(n),
      allowed = Uint8List(n),
      target = Float64List(n * 3);
  final inkLinear = inks
      .map((v) => [linearLight(v[0]), linearLight(v[1]), linearLight(v[2])])
      .toList();
  final inkOpponent = inkLinear.map((v) => opponent(v[0], v[1], v[2])).toList();
  for (var i = 0; i < n; i++) {
    final r = rgb[i * 3].clamp(0.0, 1.0),
        g = rgb[i * 3 + 1].clamp(0.0, 1.0),
        b = rgb[i * 3 + 2].clamp(0.0, 1.0);
    final lr = linearLight(r), lg = linearLight(g), lb = linearLight(b);
    var exact = -1;
    for (var j = 0; j < 4; j++) {
      final c = inkLinear[j];
      if ((lr - c[0]).abs() + (lg - c[1]).abs() + (lb - c[2]).abs() < .00001) {
        exact = j;
        break;
      }
    }
    if (exact < 0 &&
        paperWhite > 0 &&
        math.min(r, math.min(g, b)) >= 1 - paperWhite) {
      exact = 1;
    }
    if (exact >= 0) {
      indices[i] = exact;
      pinned[i] = 1;
      target.setRange(i * 3, i * 3 + 3, inkOpponent[exact]);
      continue;
    }
    final mapped = projectToPalette(lr, lg, lb, inkLinear, gamutCompression);
    final weights = paletteCoverage(mapped, inkLinear);
    for (var j = 0; j < 4; j++) {
      if (weights[j] > 1e-7) allowed[i] |= 1 << j;
    }
    // Sort along luminance: K,R,Y,W. One threshold for a convex mixture avoids
    // independent channel noise and cannot invent a fifth display color.
    final t =
        (blueNoiseRanks[(i ~/ w % blueNoiseSize) * blueNoiseSize +
                i % w % blueNoiseSize] +
            .5) /
        (blueNoiseSize * blueNoiseSize);
    var cumulative = 0.0, index = 1;
    for (final k in const [0, 3, 2, 1]) {
      cumulative += weights[k];
      if (t < cumulative) {
        index = k;
        break;
      }
    }
    indices[i] = index;
    target.setRange(
      i * 3,
      i * 3 + 3,
      opponent(mapped[0], mapped[1], mapped[2]),
    );
  }
  if (!optimize) return Reconstruction(indices, 0, 0, 0);
  final lum = _correlation(.55 + .30 * softness),
      chroma = _correlation(.85 + .50 * softness);
  final ks = [lum, chroma, chroma];
  final error = List.generate(
    3,
    (ch) => Float64List.fromList([
      for (var i = 0; i < n; i++)
        inkOpponent[indices[i]][ch] - target[i * 3 + ch],
    ]),
  );
  final corr = List.generate(3, (ch) => _correlate(error[ch], w, h, ks[ch]));
  var objective = 0.0;
  for (var ch = 0; ch < 3; ch++) {
    for (var i = 0; i < n; i++) {
      objective += error[ch][i] * corr[ch][i];
    }
  }
  final initial = objective;
  final deltas = [
    for (var old = 0; old < 4; old++)
      for (var next = 0; next < 4; next++)
        [
          for (var ch = 0; ch < 3; ch++)
            inkOpponent[next][ch] - inkOpponent[old][ch],
        ],
  ];
  final self = ks.map((k) => k.at(0, 0)).toList();
  const neighbors = [
    [-1, -1],
    [0, -1],
    [1, -1],
    [-1, 0],
    [1, 0],
    [-1, 1],
    [0, 1],
    [1, 1],
  ];
  final swapCost = [
    for (final d in neighbors)
      [
        for (final a in deltas)
          2 *
              (a[0] * a[0] * (self[0] - lum.at(d[0], d[1])) +
                  (a[1] * a[1] + a[2] * a[2]) *
                      (self[1] - chroma.at(d[0], d[1]))),
      ],
  ];
  void update(int x, int y, List<double> a, double sign) {
    for (var ch = 0; ch < 3; ch++) {
      final delta = a[ch] * sign;
      if (delta == 0) continue;
      final k = ks[ch], r = k.radius, buffer = corr[ch];
      for (var dy = math.max(-r, -y); dy <= math.min(r, h - 1 - y); dy++) {
        final start = math.max(-r, -x),
            end = math.min(r, w - 1 - x),
            base = (y + dy) * w + x,
            kbase = (dy + r) * k.size + r;
        for (var dx = start; dx <= end; dx++) {
          buffer[base + dx] += delta * k.square[kbase + dx];
        }
      }
    }
  }

  var passes = 0;
  for (var pass = 0; pass < maxPasses; pass++) {
    var accepted = 0;
    for (var step = 0; step < n; step++) {
      final i = pass.isEven ? step : n - 1 - step;
      if (pinned[i] != 0) continue;
      final x = i % w, y = i ~/ w, old = indices[i];
      var best = -1e-10, newInk = -1, swap = -1, bestX = 0, bestY = 0;
      final e0 = corr[0][i], e1 = corr[1][i], e2 = corr[2][i];
      for (var k = 0; k < neighbors.length; k++) {
        final nx = x + neighbors[k][0], ny = y + neighbors[k][1];
        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
        final ni = ny * w + nx, next = indices[ni];
        if (next == old ||
            pinned[ni] != 0 ||
            (allowed[i] & (1 << next)) == 0 ||
            (allowed[ni] & (1 << old)) == 0) {
          continue;
        }
        final di = old * 4 + next, a = deltas[di];
        final cost =
            swapCost[k][di] +
            2 *
                (a[0] * (e0 - corr[0][ni]) +
                    a[1] * (e1 - corr[1][ni]) +
                    a[2] * (e2 - corr[2][ni]));
        if (cost < best) {
          best = cost;
          newInk = next;
          swap = ni;
          bestX = nx;
          bestY = ny;
        }
      }
      if (newInk < 0) continue;
      final delta = deltas[old * 4 + newInk];
      update(x, y, delta, 1);
      indices[i] = newInk;
      if (swap >= 0) {
        update(bestX, bestY, delta, -1);
        indices[swap] = old;
      }
      objective += best;
      accepted++;
    }
    passes++;
    if (accepted == 0) break;
  }
  return Reconstruction(indices, initial, math.max(0, objective), passes);
}
