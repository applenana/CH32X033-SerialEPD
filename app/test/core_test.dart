import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_studio/protocol/codec.dart';
import 'package:ink_studio/imaging/processor.dart';
import 'package:image/image.dart' as img;

Uint8List unhex(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);
void main() {
  test(
    'CRC-32 standard check',
    () => expect(crc32('123456789'.codeUnits), 0xcbf43926),
  );
  test('SEP/1 vectors match production Python and C specification', () {
    final vectors =
        jsonDecode(
              File('../docs/protocol-vectors.json').readAsStringSync(),
            )['vectors']
            as List;
    for (final v in vectors) {
      final p = Packet(
        v['command'],
        v['sequence'],
        v['session'],
        payload: unhex(v['payload_hex']),
      );
      expect(p.encode(), unhex(v['wire_hex']), reason: v['name']);
      final q = Packet.decode(p.encode().sublist(0, p.encode().length - 1));
      expect(q.payload, p.payload);
    }
  });
  test('Fragmentation, corrupt frames and oversize resynchronization', () {
    final p = Packet(2, 0, 0).encode(), d = FrameDecoder();
    expect(d.add(List.filled(1000, 5)), isEmpty);
    expect(d.add([0, ...p]), hasLength(1));
    final broken = Uint8List.fromList(p);
    broken[3] ^= 5;
    expect(d.add(broken), isEmpty);
    expect(d.add(p.sublist(0, 4)), isEmpty);
    expect(d.add(p.sublist(4)), hasLength(1));
  });
  test('COBS handles zeros and full blocks', () {
    for (final length in [0, 1, 253, 254, 255, 772]) {
      final source = List.generate(length, (i) => i % 256);
      expect(cobsDecode(cobsEncode(source)), source);
    }
  });
  test('MSB-first four-color packing', () {
    expect(packIndices([0, 1, 2, 3, 3, 2, 1, 0]), [0x1b, 0xe4]);
    expect(() => packIndices([4, 0, 0, 0]), throwsArgumentError);
  });
  test('Bayer matrices contain each threshold exactly once', () {
    for (final n in [4, 8]) {
      final all = bayerMatrix(n).expand((r) => r).toList()..sort();
      expect(all, List.generate(n * n, (i) => i));
    }
  });
  for (final mode in DitherMode.values) {
    test(
      '${mode.name}: exact palette preserved; PNG and packed frame agree',
      () {
        final input = img.Image(width: 8, height: 4, numChannels: 4);
        for (var y = 0; y < 4; y++) {
          for (var x = 0; x < 8; x++) {
            final p = palette[x % 4];
            input.setPixelRgba(x, y, p[0] * 255, p[1] * 255, p[2] * 255, 255);
          }
        }
        final out = processImage(
          ProcessRequest(
            Uint8List.fromList(img.encodePng(input)),
            ImageSettings(mode: mode),
            width: 8,
            height: 4,
          ),
        );
        expect(out.packed, List.filled(8, 0x1b));
        expect(out.counts, [8, 8, 8, 8]);
        final preview = img.decodePng(out.preview)!;
        for (var i = 0; i < 32; i++) {
          final index = (out.packed[i ~/ 4] >> (6 - 2 * (i % 4))) & 3;
          expect(index, out.indices[i]);
          final p = preview.getPixel(i % 8, i ~/ 8);
          expect([p.r, p.g, p.b], palette[index].map((c) => c * 255).toList());
        }
      },
    );
  }
  test('Transparent input composites on white', () {
    final input = img.Image(width: 4, height: 4, numChannels: 4);
    final out = processImage(
      ProcessRequest(
        Uint8List.fromList(img.encodePng(input)),
        const ImageSettings(),
        width: 4,
        height: 4,
      ),
    );
    expect(out.packed, List.filled(4, 0x55));
  });
  test('All diffusion algorithms actually alter midtones', () {
    final input = img.Image(width: 32, height: 16);
    img.fill(input, color: img.ColorRgb8(128, 128, 128));
    final bytes = Uint8List.fromList(img.encodePng(input));
    final plain = processImage(
      ProcessRequest(
        bytes,
        const ImageSettings(mode: DitherMode.none),
        width: 32,
        height: 16,
      ),
    );
    for (final mode in DitherMode.values.skip(1)) {
      final out = processImage(
        ProcessRequest(bytes, ImageSettings(mode: mode), width: 32, height: 16),
      );
      expect(out.packed, isNot(plain.packed), reason: mode.name);
      expect(out.counts[0], greaterThan(0));
      expect(out.counts[1], greaterThan(0));
    }
  });
  test('Invalid and excessive images are rejected', () {
    expect(
      () => processImage(
        ProcessRequest(Uint8List.fromList([1, 2, 3]), const ImageSettings()),
      ),
      throwsFormatException,
    );
    expect(
      () => processImage(
        const ProcessRequest(null, ImageSettings(), width: 3, height: 4),
      ),
      throwsArgumentError,
    );
  });
}
