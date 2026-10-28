import 'dart:math' as math;

/// Measured display colors in normalized sRGB order: black, white, yellow, red.
/// Values describe the optical result of the panel, not the 2bpp wire codes.
class PaletteCalibration {
  final bool enabled;
  final List<List<double>> colors;

  const PaletteCalibration({this.enabled = false, this.colors = const [
    [0, 0, 0],
    [1, 1, 1],
    [1, 1, 0],
    [1, 0, 0],
  ]});

  static const ideal = PaletteCalibration();

  PaletteCalibration copyWith({bool? enabled, List<List<double>>? colors}) =>
      PaletteCalibration(
        enabled: enabled ?? this.enabled,
        colors: colors ?? this.colors,
      );

  List<double> color(int index) => colors[index];

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'colors': colors.map((c) => c.map((v) => v.clamp(0.0, 1.0)).toList()).toList(),
  };

  factory PaletteCalibration.fromJson(Object? value) {
    if (value is! Map) return ideal;
    final raw = value['colors'];
    final parsed = <List<double>>[];
    if (raw is List && raw.length == 4) {
      for (final row in raw) {
        if (row is! List || row.length != 3 || row.any((v) => v is! num)) {
          return ideal;
        }
        parsed.add(row.map((v) => (v as num).toDouble().clamp(0.0, 1.0)).toList());
      }
    } else {
      return ideal;
    }
    return PaletteCalibration(enabled: value['enabled'] == true, colors: parsed);
  }

  /// Prevent invalid calibration from making the four-color simplex degenerate.
  bool get valid {
    final k = colors[0], w = colors[1];
    final range = _luma(w) - _luma(k);
    return range > .04 && colors.every((c) => c.length == 3 && c.every((v) => v.isFinite));
  }

  double _luma(List<double> c) => .2126 * c[0] + .7152 * c[1] + .0722 * c[2];

  /// Creates a panel sample from 8-bit sRGB measurements.
  factory PaletteCalibration.fromRgb8({
    required List<int> black,
    required List<int> white,
    required List<int> yellow,
    required List<int> red,
    bool enabled = true,
  }) => PaletteCalibration(
    enabled: enabled,
    colors: [black, white, yellow, red]
        .map((c) => c.map((v) => (v / 255).clamp(0.0, 1.0)).toList())
        .toList(),
  );

  static double distance(List<double> a, List<double> b) => math.sqrt(
        (a[0] - b[0]) * (a[0] - b[0]) +
        (a[1] - b[1]) * (a[1] - b[1]) +
        (a[2] - b[2]) * (a[2] - b[2]),
      );
}
