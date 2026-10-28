import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_studio/studio_controller.dart';
import 'package:ink_studio/transport/serial_transport.dart';

class WrongPort extends SerialTransport {
  final input = StreamController<Uint8List>();
  int closes = 0;
  bool failWrite = false;
  @override
  Stream<Uint8List> get incoming => input.stream;
  @override
  Future<void> write(Uint8List bytes) async {
    if (failWrite) throw StateError('device unplugged');
    input.add(Uint8List.fromList([65, 66, 67, 0])); // Non-SEP device.
  }
  @override
  Future<void> close() async {
    closes++;
    await input.close();
  }
}

class WrongService extends SerialService {
  final opened = <WrongPort>[];
  bool failWrite = false;
  @override
  Future<SerialTransport> connect(DevicePort device) async {
    final port = WrongPort()..failWrite = failWrite;
    opened.add(port);
    return port;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Wrong device times out, closes once, and permits another connection', () async {
    final service = WrongService();
    final controller = StudioController(serial: service);
    controller.ports = [const DevicePort('wrong', 'wrong', '')];
    controller.selectedPort = 'wrong';
    for (var i = 0; i < 2; i++) {
      await controller.connect().timeout(const Duration(seconds: 4));
      expect(controller.connected, isFalse);
      expect(controller.connecting, isFalse);
      expect(controller.error, contains('SEP/1'));
      expect(service.opened.last.closes, 1);
    }
    service.failWrite = true;
    await controller.connect();
    expect(controller.error, contains('unplugged'));
    expect(service.opened.last.closes, 1);
    controller.dispose();
  });
}
