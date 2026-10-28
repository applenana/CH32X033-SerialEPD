import 'dart:math' as math;
import 'dart:typed_data';
import 'color_mapping.dart';
import 'reconstruction.dart' show linearLight;

// Experimental spatial context, not an extra panel color or a validated
// perceptual model. See docs/release-0.3.4.md for intent and limitations.
double _smooth(double low, double high, double value) {
  final t = ((value - low) / (high - low)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

double _encode(double c) =>
    c <= .0031308 ? c * 12.92 : 1.055 * math.pow(c, 1 / 2.4).toDouble() - .055;

class ColorInductionPlan {
  final Float32List confidence, distance;
  final int radius;
  ColorInductionPlan(int pixels, this.radius)
    : confidence = Float32List(pixels),
      distance = Float32List(pixels);
}

/// Find blue/cyan before natural mapping removes source chroma. Distance is
/// measured inside each region, so the warm band cannot stain a white margin
/// or an adjacent skin-tone region. Canvas edges are region boundaries too.
ColorInductionPlan prepareColorInduction(
  Float32List rgb,
  int width,
  int height,
  int radius,
) {
  final plan = ColorInductionPlan(width * height, radius.clamp(2, 24).toInt());
  final limit = plan.radius + 1.0;
  final d = plan.distance;
  for (var i = 0; i < d.length; i++) {
    final r = rgb[i * 3], g = rgb[i * 3 + 1], b = rgb[i * 3 + 2];
    final spread = math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));
    final cold =
        _smooth(.025, .18, spread) *
        _smooth(.01, .18, b - r) *
        _smooth(-.02, .16, b - .7 * g - .3 * r);
    // Smooth confidence at the segmentation threshold prevents a strong
    // contour appearing as soon as a nearly gray pixel crosses the threshold.
    plan.confidence[i] = _smooth(.12, .8, cold);
    if (plan.confidence[i] == 0) continue;
    final x = i % width, y = i ~/ width;
    d[i] = x == 0 || y == 0 || x == width - 1 || y == height - 1 ? 1 : limit;
  }
  // Two-pass chamfer distance; bounded storage and O(width * height) work.
  const diagonal = 1.41421356237;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = y * width + x;
      if (d[i] == 0) continue;
      if (x > 0) d[i] = math.min(d[i], d[i - 1] + 1);
      if (y > 0) {
        d[i] = math.min(d[i], d[i - width] + 1);
        if (x > 0) d[i] = math.min(d[i], d[i - width - 1] + diagonal);
        if (x + 1 < width) d[i] = math.min(d[i], d[i - width + 1] + diagonal);
      }
    }
  }
  for (var y = height - 1; y >= 0; y--) {
    for (var x = width - 1; x >= 0; x--) {
      final i = y * width + x;
      if (d[i] == 0) continue;
      if (x + 1 < width) d[i] = math.min(d[i], d[i + 1] + 1);
      if (y + 1 < height) {
        d[i] = math.min(d[i], d[i + width] + 1);
        if (x > 0) d[i] = math.min(d[i], d[i + width - 1] + diagonal);
        if (x + 1 < width) d[i] = math.min(d[i], d[i + width + 1] + diagonal);
      }
    }
  }
  return plan;
}

/// Apply after natural mapping but before all quantization/reconstruction.
/// Core desaturation conserves linear Y. The yellow surround deliberately
/// raises Y by at most 0.10 at full strength to remain visible in dark blue.
/// Update diffusion protection so it does not suppress this intended ink.
NaturalMapping applyColorInduction(
  Float32List rgb,
  ColorInductionPlan plan,
  double strength,
  NaturalMapping? natural,
) {
  final mask = natural ?? NaturalMapping(plan.confidence.length);
  final amount = strength.clamp(0.0, 1.0);
  for (var i = 0; i < plan.confidence.length; i++) {
    final mix = amount * plan.confidence[i];
    if (mix == 0) continue;
    final at = i * 3;
    final lr = linearLight(rgb[at]),
        lg = linearLight(rgb[at + 1]),
        lb = linearLight(rgb[at + 2]);
    final y = .2126 * lr + .7152 * lg + .0722 * lb;
    final border = 1 - _smooth(0, plan.radius.toDouble(), plan.distance[i] - 1);
    final warm = mix * border;
    // Desaturate the inner blue subject without discarding its tone details.
    final retain = 1 - mix;
    final r = y + (lr - y) * retain;
    final g = y + (lg - y) * retain;
    final b = y + (lb - y) * retain;
    final surroundY = (y + .10).clamp(0.0, 1.0);
    // Maximum yellow chroma at this luminance, using only the BWYR gamut.
    final yellowRG = (surroundY / .9278).clamp(0.0, 1.0);
    final yellowB = ((surroundY - .9278) / .0722).clamp(0.0, 1.0);
    rgb[at] = _encode(r + (yellowRG - r) * warm).clamp(0.0, 1.0);
    rgb[at + 1] = _encode(g + (yellowRG - g) * warm).clamp(0.0, 1.0);
    rgb[at + 2] = _encode(b + (yellowB - b) * warm).clamp(0.0, 1.0);
    mask.protection[i] = math.max(mask.protection[i], mix) * (1 - warm);
    mask.neutral[i] = rgb[at] == rgb[at + 1] && rgb[at + 1] == rgb[at + 2]
        ? 1
        : 0;
  }
  return mask;
}
