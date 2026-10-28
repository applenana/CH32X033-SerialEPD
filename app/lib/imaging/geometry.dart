import 'dart:math' as math;
import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// Non-destructive selection in the normalized bounding box of the rotated image.
class CropSpec {
  final double left, top, right, bottom, angle;
  final bool flip;
  const CropSpec({
    this.left = 0,
    this.top = 0,
    this.right = 1,
    this.bottom = 1,
    this.angle = 0,
    this.flip = false,
  });
  double get width => right - left;
  double get height => bottom - top;
  bool get valid =>
      [left, top, right, bottom, angle].every((v) => v.isFinite) &&
      left >= 0 &&
      top >= 0 &&
      right <= 1 &&
      bottom <= 1 &&
      width > 0 &&
      height > 0;
}

img.Image decodeSource(Uint8List data) {
  if (data.length > 25 * 1024 * 1024) {
    throw const FormatException('图片文件超过 25 MB，请先缩小');
  }
  final decoder = img.findDecoderForData(data),
      info = decoder?.startDecode(data);
  if (info == null) {
    throw const FormatException('无法读取图片，请使用 PNG、JPEG、WebP 或 BMP');
  }
  if (info.width <= 0 ||
      info.height <= 0 ||
      info.width * info.height > 24000000) {
    throw const FormatException('图片超过 2400 万像素或尺寸无效');
  }
  final decoded = decoder!.decodeFrame(0);
  if (decoded == null) throw const FormatException('图片解码失败');
  return img.bakeOrientation(decoded);
}

(double, double) rotatedSize(double width, double height, double angle) {
  final a = angle * math.pi / 180, c = math.cos(a).abs(), s = math.sin(a).abs();
  return (width * c + height * s, width * s + height * c);
}

/// Inverse affine sampling avoids allocating a full-resolution rotated bitmap.
/// Coordinates match the Flutter editor's translate/rotate/flip painter exactly.
img.Image frameImage(
  img.Image source,
  CropSpec crop,
  int width,
  int height, {
  required bool cover,
}) {
  if (!crop.valid) throw ArgumentError('无效裁切区域');
  final (bw, bh) = rotatedSize(
    source.width.toDouble(),
    source.height.toDouble(),
    crop.angle,
  );
  final cw = bw * crop.width, ch = bh * crop.height;
  final scale = cover
      ? math.max(width / cw, height / ch)
      : math.min(width / cw, height / ch);
  final dw = cw * scale,
      dh = ch * scale,
      ox = (width - dw) / 2,
      oy = (height - dh) / 2;
  final angle = crop.angle * math.pi / 180,
      cos = math.cos(angle),
      sin = math.sin(angle);
  final output = img.Image(width: width, height: height, numChannels: 3);
  img.fill(output, color: img.ColorRgb8(255, 255, 255));
  // Supersample reductions up to 4x4. This suppresses aliasing without decoding
  // another rotated source; every output pixel is still bounded work.
  final samples = (1 / scale).ceil().clamp(1, 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      var red = 0.0, green = 0.0, blue = 0.0;
      for (var sy = 0; sy < samples; sy++) {
        for (var sx = 0; sx < samples; sx++) {
          final px = x + (sx + .5) / samples, py = y + (sy + .5) / samples;
          if (px < ox || px >= ox + dw || py < oy || py >= oy + dh) {
            red += 255;
            green += 255;
            blue += 255;
            continue;
          }
          final rx = (px - ox) / scale + crop.left * bw - bw / 2,
              ry = (py - oy) / scale + crop.top * bh - bh / 2;
          var ix = cos * rx + sin * ry;
          final iy = -sin * rx + cos * ry + source.height / 2 - .5;
          if (crop.flip) ix = -ix;
          ix += source.width / 2 - .5;
          if (ix < -.5 ||
              iy < -.5 ||
              ix >= source.width - .5 ||
              iy >= source.height - .5) {
            red += 255;
            green += 255;
            blue += 255;
            continue;
          }
          final p = source.getPixelInterpolate(
            ix.clamp(0, source.width - 1).toDouble(),
            iy.clamp(0, source.height - 1).toDouble(),
            interpolation: img.Interpolation.linear,
          );
          final alpha = p.aNormalized;
          red += p.rNormalized * 255 * alpha + 255 * (1 - alpha);
          green += p.gNormalized * 255 * alpha + 255 * (1 - alpha);
          blue += p.bNormalized * 255 * alpha + 255 * (1 - alpha);
        }
      }
      final count = samples * samples;
      output.setPixelRgb(
        x,
        y,
        (red / count).round(),
        (green / count).round(),
        (blue / count).round(),
      );
    }
  }
  return output;
}

(Uint8List, int, int) editorPreview(Uint8List data) {
  var source = decodeSource(data);
  final width = source.width, height = source.height;
  if (math.max(source.width, source.height) > 1600) {
    source = img.copyResize(
      source,
      width: source.width >= source.height ? 1600 : null,
      height: source.height > source.width ? 1600 : null,
      interpolation: img.Interpolation.average,
    );
  }
  return (Uint8List.fromList(img.encodePng(source)), width, height);
}
