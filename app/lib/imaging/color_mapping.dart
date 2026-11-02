import 'dart:math' as math;
import 'dart:typed_data';
import 'reconstruction.dart' show linearLight, srgbFromLinear;

// Inspired by the smooth neutral/cool protection in ink-nfc-lab's
// ResearchQuantizer.java. This is a BWYR-specific implementation: mix toward
// neutral in linear light, preserving Y before the existing gamut projection.
// The thresholds are heuristics, not measurements of the Huawei panel.
double _smooth(double low, double high, double value) {
  final t = ((value - low) / (high - low)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

double _encode(double c) => srgbFromLinear(c);

/// Confidence that source chroma should receive red/yellow ink. Evaluate on
/// the unquantized source, never on pixels polluted by diffusion errors.
double warmInkAffinity(double r, double g, double b) {
  final spread = math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));
  final chromatic = _smooth(.015, .16, spread);
  final cool =
      _smooth(.01, .18, b - r) * _smooth(-.02, .16, b - .7 * g - .3 * r);
  return chromatic * (1 - cool);
}

class NaturalMapping {
  final Float32List protection;
  final Uint8List neutral;
  NaturalMapping(int pixels)
    : protection = Float32List(pixels),
      neutral = Uint8List(pixels);
}

/// Modifies adjusted sRGB in place. The convex blend preserves linear Y and
/// stays in [0,1]. Fully saturated red/yellow and exact black/white are kept.
/// Returns immutable source masks for the legacy diffusion path.
NaturalMapping applyNaturalMapping(Float32List rgb, double strength) {
  final mask = NaturalMapping(rgb.length ~/ 3);
  final amount = strength.clamp(0.0, 1.0);
  for (var i = 0; i < mask.protection.length; i++) {
    final at = i * 3;
    final r = rgb[at], g = rgb[at + 1], b = rgb[at + 2];
    final protection = amount * (1 - warmInkAffinity(r, g, b));
    mask.protection[i] = protection;
    if (r == g && g == b) mask.neutral[i] = 1;
    if (protection == 0 || mask.neutral[i] == 1) continue;
    final lr = linearLight(r), lg = linearLight(g), lb = linearLight(b);
    final y = .2126 * lr + .7152 * lg + .0722 * lb;
    final retain = 1 - protection;
    rgb[at] = _encode(y + (lr - y) * retain).clamp(0.0, 1.0);
    rgb[at + 1] = _encode(y + (lg - y) * retain).clamp(0.0, 1.0);
    rgb[at + 2] = _encode(y + (lb - y) * retain).clamp(0.0, 1.0);
  }
  return mask;
}
