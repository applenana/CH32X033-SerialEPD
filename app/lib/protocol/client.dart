import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import '../transport/serial_transport.dart';
import 'codec.dart';

class DeviceException implements Exception {
  final DeviceStatus status;
  DeviceException(this.status);
  @override
  String toString() {
    const messages = [
      '正常',
      '协议版本不兼容',
      '未知命令',
      '参数不正确',
      '会话失效，请重新连接',
      '请求序号不同步，请查询设备状态',
      '设备状态不允许此操作',
      '图像偏移不匹配',
      '图像校验失败',
      '设备忙，请等待刷新完成',
      '屏幕通信失败，请检查接线和批次',
      '上传超时，请重新发送',
    ];
    final code = status.result != 0 ? status.result : status.error;
    return '${code < messages.length ? messages[code] : '设备错误 $code'}${status.driverError != 0 ? '（驱动 ${status.driverError}）' : ''}';
  }
}

class UploadCancelled implements Exception {}

class TransferProgress {
  final String phase;
  final double fraction;
  final bool committed;
  const TransferProgress(this.phase, this.fraction, {this.committed = false});
}

class SepClient {
  final SerialTransport transport;
  final Duration replyTimeout;
  final int retries;
  final _decoder = FrameDecoder();
  late final StreamSubscription<Uint8List> _subscription;
  Completer<Packet>? _waiting;
  Packet? _expected;
  bool _busy = false, _closed = false;
  Object? _linkError;
  int _session = 0, _sequence = 0;
  Uint8List? _uncertain;
  void Function(Object)? onLinkError;

  SepClient(
    this.transport, {
    this.replyTimeout = const Duration(milliseconds: 2500),
    this.retries = 3,
  }) {
    _subscription = transport.incoming.listen(
      (bytes) {
        for (final packet in _decoder.add(bytes)) {
          final expected = _expected;
          if (expected != null &&
              packet.flags == 1 &&
              packet.command == expected.command &&
              packet.session == expected.session &&
              packet.sequence == expected.sequence &&
              !(_waiting?.isCompleted ?? true)) {
            _waiting!.complete(packet);
          }
        }
      },
      onError: (Object e) => _fail(e),
      onDone: () => _fail(StateError('设备连接已结束')),
    );
  }

  void _fail(Object error) {
    if (_closed) return;
    _linkError = error;
    if (!(_waiting?.isCompleted ?? true)) _waiting!.completeError(error);
    onLinkError?.call(error);
  }

  Future<DeviceStatus> _exchange(Packet packet) async {
    if (_closed || _linkError != null) throw StateError('连接已中断，请重新连接设备');
    if (_busy) throw StateError('请等待当前设备操作完成');
    _busy = true;
    final wire = Uint8List.fromList([0, ...packet.encode()]);
    try {
      for (var attempt = 0; attempt <= retries; attempt++) {
        _expected = packet;
        final completer = Completer<Packet>();
        _waiting = completer;
        // Install the listener BEFORE writing; a fast response must never be lost.
        final response = completer.future.timeout(replyTimeout);
        // Prevent a transport error during write from becoming an unhandled future.
        unawaited(
          response.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
        );
        try {
          await transport.write(wire);
          return DeviceStatus(await response);
        } on TimeoutException {
          if (_linkError != null) rethrow;
          if (attempt == retries) {
            throw TimeoutException('设备未应答，结果尚不确定。请先查询状态，避免重复刷新。');
          }
        }
      }
      throw StateError('没有设备应答');
    } finally {
      _waiting = null;
      _expected = null;
      _busy = false;
    }
  }

  Future<DeviceStatus> probe([int command = Command.status]) async {
    if (command != Command.info && command != Command.status) {
      throw ArgumentError('非只读命令');
    }
    final status = await _exchange(Packet(command, 0, 0));
    if (status.result != 0) throw DeviceException(status);
    return status;
  }

  Future<DeviceStatus> open() async {
    _session = Random.secure().nextInt(0xffffffff) + 1;
    _sequence = 0;
    final status = await _exchange(Packet(Command.open, 0, _session));
    if (status.result != 0) throw DeviceException(status);
    _sequence = 1;
    _uncertain = null;
    return status;
  }

  Future<DeviceStatus> request(int command, [List<int> data = const []]) async {
    if (_session == 0 || _sequence == 0) throw StateError('需要先创建会话');
    final packet = Packet(command, _sequence, _session, payload: data);
    final bytes = packet.encode();
    if (_uncertain != null && !_same(_uncertain!, bytes)) {
      throw StateError('上一条请求结果不确定，请先查询状态或重新建立会话');
    }
    _uncertain = bytes;
    final status = await _exchange(packet);
    _uncertain = null;
    if (![1, 4, 5].contains(status.result) &&
        status.nextSequence == ((_sequence + 1) & 0xffffffff)) {
      _sequence = status.nextSequence;
    }
    if (status.result != 0) throw DeviceException(status);
    return status;
  }

  bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _wait(
    int target,
    Duration timeout,
    bool Function() cancel,
  ) async {
    final watch = Stopwatch()..start();
    while (watch.elapsed < timeout) {
      if (cancel()) throw UploadCancelled();
      final status = await probe();
      if (status.failed) throw DeviceException(status);
      if (status.state == target) return;
      if (status.state == 0) throw StateError('事务已取消，设备可能发生了复位或被其他客户端接管');
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw TimeoutException('等待设备状态超时，请查询状态后再操作');
  }

  Future<void> upload(
    Uint8List frame,
    int panel,
    Capabilities caps, {
    required void Function(TransferProgress) progress,
    required bool Function() cancel,
  }) async {
    if (!caps.compatible ||
        panel < 0 ||
        panel > 1 ||
        frame.length != frameBytes ||
        (caps.panelMask & (1 << panel)) == 0) {
      throw StateError('设备能力与当前图像或面板批次不匹配');
    }
    var committed = false;
    try {
      final status = await open();
      if (status.state == 3) throw StateError('屏幕仍在刷新，请等待完成');
      final begin = ByteData(16)
        ..setUint8(0, panel)
        ..setUint8(1, 1)
        ..setUint16(2, epdWidth, Endian.little)
        ..setUint16(4, epdHeight, Endian.little)
        ..setUint32(8, frame.length, Endian.little)
        ..setUint32(12, crc32(frame), Endian.little);
      progress(const TransferProgress('准备屏幕', 0));
      await request(Command.begin, begin.buffer.asUint8List());
      await _wait(2, const Duration(seconds: 420), cancel);
      final chunk = (min(caps.chunk, 768) ~/ 192) * 192;
      for (var offset = 0; offset < frame.length; offset += chunk) {
        if (cancel()) throw UploadCancelled();
        final count = min(chunk, frame.length - offset);
        final data = Uint8List(count + 4);
        ByteData.sublistView(data).setUint32(0, offset, Endian.little);
        data.setRange(4, data.length, frame, offset);
        final reply = await request(Command.data, data);
        if (reply.offset != offset + count) throw StateError('设备确认的图像长度不一致');
        progress(TransferProgress('传输图像', (offset + count) / frame.length));
      }
      if (cancel()) throw UploadCancelled();
      // Once COMMIT is sent its outcome can be uncertain. Never abort or re-upload automatically.
      committed = true;
      progress(const TransferProgress('正在刷新墨水屏', 1, committed: true));
      await request(Command.commit);
      await _wait(4, const Duration(seconds: 240), () => false);
      progress(const TransferProgress('画面已更新', 1, committed: true));
    } on UploadCancelled {
      if (!committed) await request(Command.abort);
      rethrow;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!(_waiting?.isCompleted ?? true)) {
      _waiting!.completeError(StateError('连接已关闭'));
    }
    await _subscription.cancel();
    await transport.close();
  }
}
