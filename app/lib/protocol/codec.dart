import 'dart:typed_data';

const epdWidth = 768;
const epdHeight = 552;
const frameBytes = 105984;
const maxPayload = 772;

abstract final class Command {
  static const open = 1, info = 2, status = 3;
  static const begin = 16, data = 17, commit = 18, abort = 19;
}

int crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final b in bytes) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      crc = (crc >>> 1) ^ ((crc & 1) != 0 ? 0xedb88320 : 0);
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

Uint8List cobsEncode(List<int> data) {
  final out = <int>[0];
  var start = 0, code = 1;
  for (final b in data) {
    if (b == 0) {
      out[start] = code;
      start = out.length;
      out.add(0);
      code = 1;
    } else {
      out.add(b);
      code++;
      if (code == 255) {
        out[start] = code;
        start = out.length;
        out.add(0);
        code = 1;
      }
    }
  }
  out[start] = code;
  return Uint8List.fromList(out);
}

Uint8List cobsDecode(List<int> bytes) {
  final out = <int>[];
  var i = 0;
  while (i < bytes.length) {
    final code = bytes[i++];
    if (code == 0 || i + code - 1 > bytes.length) {
      throw const FormatException('COBS 数据不完整');
    }
    for (var j = 1; j < code; j++) {
      final b = bytes[i++];
      if (b == 0) throw const FormatException('COBS 内含分隔符');
      out.add(b);
    }
    if (code != 255 && i < bytes.length) out.add(0);
  }
  return Uint8List.fromList(out);
}

class Packet {
  final int command, sequence, session, flags;
  final Uint8List payload;
  Packet(
    this.command,
    this.sequence,
    this.session, {
    List<int> payload = const [],
    this.flags = 0,
  }) : payload = Uint8List.fromList(payload);

  Uint8List encode() {
    if (payload.length > maxPayload) throw ArgumentError('数据块过大');
    final raw = Uint8List(20 + payload.length);
    final view = ByteData.sublistView(raw);
    view.setUint8(0, 1);
    view.setUint8(1, command);
    view.setUint16(2, flags, Endian.little);
    view.setUint32(4, sequence, Endian.little);
    view.setUint32(8, session, Endian.little);
    view.setUint16(12, payload.length, Endian.little);
    raw.setRange(16, 16 + payload.length, payload);
    view.setUint32(
      raw.length - 4,
      crc32(raw.sublist(0, raw.length - 4)),
      Endian.little,
    );
    return Uint8List.fromList([...cobsEncode(raw), 0]);
  }

  factory Packet.decode(List<int> bytes) {
    final raw = cobsDecode(bytes);
    if (raw.length < 20) throw const FormatException('短帧');
    final view = ByteData.sublistView(raw);
    final n = view.getUint16(12, Endian.little);
    final flags = view.getUint16(2, Endian.little);
    if (raw[0] != 1 ||
        flags > 1 ||
        view.getUint16(14, Endian.little) != 0 ||
        n > maxPayload ||
        raw.length != 20 + n ||
        crc32(raw.sublist(0, raw.length - 4)) !=
            view.getUint32(raw.length - 4, Endian.little)) {
      throw const FormatException('帧头或 CRC 错误');
    }
    return Packet(
      raw[1],
      view.getUint32(4, Endian.little),
      view.getUint32(8, Endian.little),
      payload: raw.sublist(16, raw.length - 4),
      flags: flags,
    );
  }
}

class FrameDecoder {
  final _bytes = <int>[];
  bool _dropping = false;
  Iterable<Packet> add(List<int> bytes) sync* {
    for (final b in bytes) {
      if (b == 0) {
        Packet? packet;
        if (_bytes.isNotEmpty && !_dropping) {
          try {
            packet = Packet.decode(_bytes);
          } on FormatException {
            /* await next delimiter */
          }
        }
        _bytes.clear();
        _dropping = false;
        if (packet != null) yield packet;
      } else if (!_dropping) {
        _bytes.add(b);
        if (_bytes.length >= 797) {
          _bytes.clear();
          _dropping = true;
        }
      }
    }
  }
}

class DeviceStatus {
  final int result, state, error, driverError, offset, nextSequence;
  final Uint8List extra;
  DeviceStatus(Packet p)
    : result = _check(p)[0],
      state = p.payload[1],
      error = p.payload[2],
      driverError = p.payload[3],
      offset = ByteData.sublistView(p.payload).getUint32(4, Endian.little),
      nextSequence = ByteData.sublistView(
        p.payload,
      ).getUint32(8, Endian.little),
      extra = Uint8List.sublistView(p.payload, 12);
  static Uint8List _check(Packet p) {
    if (p.flags != 1 || p.payload.length < 12) {
      throw const FormatException('应答数据不完整');
    }
    return p.payload;
  }

  String get label => switch (state) {
    0 => '待机',
    1 => '正在准备屏幕',
    2 => '等待图像',
    3 => '屏幕刷新中',
    4 => '刷新完成',
    _ => '设备异常',
  };
  bool get failed => state == 5 || error != 0;
}

class Capabilities {
  int width = 0, height = 0, chunk = 0, panelMask = 0, format = 0, bytes = 0;
  String version = '未知';
  Capabilities(List<int> tlvs) {
    var i = 0;
    while (i < tlvs.length) {
      if (i + 2 > tlvs.length || i + 2 + tlvs[i + 1] > tlvs.length) {
        throw const FormatException('能力信息不完整');
      }
      final tag = tlvs[i], n = tlvs[i + 1];
      final v = Uint8List.fromList(tlvs.sublist(i + 2, i + 2 + n));
      final d = ByteData.sublistView(v);
      if (tag == 1 && n == 4) {
        width = d.getUint16(0, Endian.little);
        height = d.getUint16(2, Endian.little);
      }
      if (tag == 2 && n == 4) chunk = d.getUint32(0, Endian.little);
      if (tag == 3 && n == 2) {
        panelMask = v[0];
        format = v[1];
      }
      if (tag == 4 && n == 3) version = v.join('.');
      if (tag == 5 && n == 4) bytes = d.getUint32(0, Endian.little);
      i += 2 + n;
    }
  }
  bool get compatible =>
      width == epdWidth &&
      height == epdHeight &&
      format == 1 &&
      bytes == frameBytes &&
      chunk >= 192;
}
