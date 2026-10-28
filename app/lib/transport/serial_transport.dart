import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
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
      for (final address in SerialPort.availablePorts) {
        final p = SerialPort(address);
        try {
          result.add(
            DevicePort(
              address,
              address,
              p.description ?? '串口设备',
              vendorId: p.vendorId,
              productId: p.productId,
            ),
          );
        } finally {
          p.dispose();
        }
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
      // Firmware VID belongs to WCH, but this device is CDC ACM, not a CH34x bridge.
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
    return DesktopTransport(device.id);
  }
}

class DesktopTransport implements SerialTransport {
  final SerialPort _port;
  final _input = StreamController<Uint8List>.broadcast();
  Timer? _timer;
  bool _closed = false;
  DesktopTransport(String path) : _port = SerialPort(path) {
    try {
      if (!_port.openReadWrite()) {
        throw StateError('端口打开失败：${SerialPort.lastError}');
      }
      final config = SerialPortConfig();
      try {
        config.baudRate = 115200;
        config.bits = 8;
        config.stopBits = 1;
        config.parity = SerialPortParity.none;
        config.setFlowControl(SerialPortFlowControl.none);
        _port.config = config;
      } finally {
        config.dispose();
      }
      // Nonblocking reads avoid waiting on the UI isolate and make disconnect immediate.
      _timer = Timer.periodic(const Duration(milliseconds: 5), (_) {
        try {
          final count = _port.bytesAvailable;
          if (count < 0) throw StateError('串口连接已失效，请重新连接');
          if (count > 0) {
            _input.add(_port.read(count.clamp(0, 4096), timeout: 0));
          }
        } catch (e, st) {
          _input.addError(e, st);
          _timer?.cancel();
        }
      });
    } catch (_) {
      _port.close();
      _port.dispose();
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
      final n = _port.write(Uint8List.sublistView(bytes, sent), timeout: 0);
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
    _port.close();
    _port.dispose();
    await _input.close();
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
