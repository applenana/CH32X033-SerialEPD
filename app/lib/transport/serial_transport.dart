import 'dart:async';
import 'dart:typed_data';
import 'desktop_config.dart';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:usb_serial/usb_serial.dart';

class DevicePort {
  final String id, name, detail;
  final int? vendorId, productId;
  final UsbDevice? usbDevice;
  const DevicePort(
    this.id,
    this.name,
    this.detail, {
    this.vendorId,
    this.productId,
    this.usbDevice,
  });
  bool get recommended => vendorId == 0x1a86 && productId == 0xfe0c;
}

abstract class SerialTransport {
  Stream<Uint8List> get incoming;
  Future<void> write(Uint8List bytes);
  Future<void> close();
}

class SerialService {
  Future<List<DevicePort>> list() async {
    final result = <DevicePort>[];
    if (Platform.isAndroid) {
      for (final d in await UsbSerial.listDevices()) {
        result.add(
          DevicePort(
            d.deviceId.toString(),
            d.productName ?? 'USB 设备',
            d.deviceName,
            vendorId: d.vid,
            productId: d.pid,
            usbDevice: d,
          ),
        );
      }
    } else if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final worker = await DesktopTransport.start();
      try {
        final rows = await worker.call('list') as List;
        for (final row in rows) {
          result.add(
            DevicePort(
              row[0],
              row[0],
              row[1],
              vendorId: row[2],
              productId: row[3],
            ),
          );
        }
      } finally {
        await worker.close();
      }
    } else {
      throw UnsupportedError('此版本支持 Windows 与 Android USB OTG');
    }
    result.sort(
      (a, b) => a.recommended == b.recommended
          ? a.name.compareTo(b.name)
          : a.recommended
          ? -1
          : 1,
    );
    return result;
  }

  Future<SerialTransport> connect(DevicePort device) async {
    if (Platform.isAndroid) {
      final port = await device.usbDevice?.create(UsbSerial.CDC);
      if (port == null) throw StateError('无法创建 USB CDC 连接');
      try {
        if (!await port.open()) throw StateError('USB 权限未授予，或设备已被占用');
        await port.setPortParameters(
          115200,
          UsbPort.DATABITS_8,
          UsbPort.STOPBITS_1,
          UsbPort.PARITY_NONE,
        );
        await port.setDTR(true);
        await port.setRTS(true);
        return AndroidTransport(port, device.usbDevice!.deviceId);
      } catch (_) {
        await port.close();
        rethrow;
      }
    }
    final worker = await DesktopTransport.start();
    try {
      await worker.call('open', device.id);
      return worker;
    } catch (_) {
      await worker.close();
      rethrow;
    }
  }
}

// All native desktop calls, including open/configure/enumeration/close, belong
// to this worker. A UI-side deadline remains live even if a driver stalls.
class DesktopTransport implements SerialTransport {
  final _messages = ReceivePort();
  final _input = StreamController<Uint8List>.broadcast();
  final _ready = Completer<SendPort>();
  final _pending = <int, Completer<dynamic>>{};
  Isolate? _isolate;
  SendPort? _commands;
  int _next = 0;
  bool _closed = false;

  DesktopTransport._() {
    _messages.listen((message) {
      if (message is! Map) {
        _stop(StateError('串口后台已退出，请重新连接'));
      } else if (message.containsKey('ready')) {
        if (!_ready.isCompleted) _ready.complete(message['ready'] as SendPort);
      } else if (message.containsKey('data')) {
        if (!_closed) _input.add(message['data'] as Uint8List);
      } else if (message.containsKey('fault')) {
        _stop(StateError(message['fault'] as String));
      } else {
        final waiting = _pending.remove(message['id']);
        if (waiting == null) return;
        if (message.containsKey('error')) {
          waiting.completeError(StateError(message['error'] as String));
        } else {
          waiting.complete(message['result']);
        }
      }
    });
  }

  static Future<DesktopTransport> start() async {
    final worker = DesktopTransport._();
    try {
      worker._isolate = await Isolate.spawn(
        _desktopWorker,
        worker._messages.sendPort,
        onError: worker._messages.sendPort,
        onExit: worker._messages.sendPort,
      );
      worker._commands = await worker._ready.future.timeout(
        const Duration(seconds: 5),
      );
      return worker;
    } catch (e) {
      worker._stop(e);
      rethrow;
    }
  }

  Future<dynamic> call(String operation, [Object? value]) async {
    if (_closed) throw StateError('串口已断开');
    final id = ++_next, reply = Completer<dynamic>();
    _pending[id] = reply;
    _commands!.send([id, operation, value]);
    try {
      return await reply.future.timeout(
        Duration(seconds: operation == 'close' ? 2 : 5),
      );
    } on TimeoutException {
      final error = TimeoutException('串口操作超时，请检查端口或选择其他设备');
      _stop(error);
      throw error;
    } finally {
      _pending.remove(id);
    }
  }

  void _stop(Object? error) {
    if (_closed) return;
    _closed = true;
    final reason = error ?? StateError('串口已断开');
    for (final reply in _pending.values) {
      if (!reply.isCompleted) reply.completeError(reason);
    }
    _pending.clear();
    if (error != null && _input.hasListener) _input.addError(error);
    _isolate?.kill(priority: Isolate.immediate);
    _messages.close();
    unawaited(_input.close());
  }

  @override
  Stream<Uint8List> get incoming => _input.stream;
  @override
  Future<void> write(Uint8List bytes) async {
    await call('write', bytes);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    try {
      await call('close');
    } finally {
      _stop(null);
    }
  }
}

void _desktopWorker(SendPort output) {
  final commands = ReceivePort();
  _NativeDesktopTransport? port;
  StreamSubscription<Uint8List>? subscription;
  output.send({'ready': commands.sendPort});
  commands.listen((dynamic message) async {
    final id = message[0];
    try {
      dynamic result;
      switch (message[1]) {
        case 'list':
          final rows = <List<Object?>>[];
          for (final address in SerialPort.availablePorts) {
            final p = SerialPort(address);
            try {
              rows.add([
                address,
                p.description ?? '串口设备',
                p.vendorId,
                p.productId,
              ]);
            } finally {
              p.dispose();
            }
          }
          result = rows;
          break;
        case 'open':
          port = _NativeDesktopTransport(message[2] as String);
          subscription = port!.incoming.listen(
            (data) => output.send({'data': data}),
            onError: (Object e) => output.send({'fault': e.toString()}),
          );
          break;
        case 'write':
          if (port == null) throw StateError('串口未打开');
          await port!.write(message[2] as Uint8List);
          break;
        case 'close':
          await subscription?.cancel();
          await port?.close();
          commands.close();
          break;
      }
      output.send({'id': id, 'result': result});
    } catch (e) {
      output.send({'id': id, 'error': e.toString()});
    }
  });
}

class _NativeDesktopTransport implements SerialTransport {
  final SerialPort _port;
  final _input = StreamController<Uint8List>.broadcast();
  Timer? _timer;
  bool _closed = false;
  _NativeDesktopTransport(String path) : _port = SerialPort(path) {
    try {
      if (!_port.openReadWrite()) {
        throw StateError('端口打开失败：${SerialPort.lastError}');
      }
      configureDesktopPort(_port);
      // Nonblocking reads avoid waiting on the UI isolate and make disconnect immediate.
      _timer = Timer.periodic(const Duration(milliseconds: 5), (_) {
        try {
          final count = _port.bytesAvailable;
          if (count < 0) throw StateError('串口连接已失效，请重新连接');
          if (count > 0) {
            _input.add(_port.read(count.clamp(0, 4096), timeout: -1));
          }
        } catch (e, st) {
          _input.addError(e, st);
          _timer?.cancel();
        }
      });
    } catch (_) {
      try {
        _port.close();
      } finally {
        _port.dispose();
      }
      rethrow;
    }
  }
  @override
  Stream<Uint8List> get incoming => _input.stream;
  @override
  Future<void> write(Uint8List bytes) async {
    final watch = Stopwatch()..start();
    var sent = 0;
    while (sent < bytes.length) {
      if (_closed) throw StateError('串口已断开');
      final n = _port.write(Uint8List.sublistView(bytes, sent), timeout: -1);
      if (n < 0) throw StateError('串口写入失败');
      sent += n;
      if (watch.elapsed > const Duration(seconds: 3)) {
        throw TimeoutException('串口写入超时');
      }
      if (sent < bytes.length) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    try {
      _port.close();
    } finally {
      _port.dispose();
      await _input.close();
    }
  }
}

class AndroidTransport implements SerialTransport {
  final UsbPort _port;
  final _input = StreamController<Uint8List>.broadcast();
  StreamSubscription<Uint8List>? _data;
  StreamSubscription<UsbEvent>? _events;
  bool _closed = false;
  AndroidTransport(this._port, int? deviceId) {
    _data = _port.inputStream?.listen(
      _input.add,
      onError: _input.addError,
      onDone: () {
        if (!_closed) _input.addError(StateError('USB 数据连接已断开'));
      },
    );
    _events = UsbSerial.usbEventStream?.listen((event) {
      if (event.event == UsbEvent.ACTION_USB_DETACHED &&
          event.device?.deviceId == deviceId) {
        _input.addError(StateError('USB 设备已拔出'));
      }
    });
  }

  @override
  Stream<Uint8List> get incoming => _input.stream;
  @override
  Future<void> write(Uint8List bytes) async {
    if (_closed) throw StateError('USB 已断开');
    await _port.write(bytes).timeout(const Duration(seconds: 3));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _events?.cancel();
    await _data?.cancel();
    await _port.close();
    await _input.close();
  }
}
