import 'package:flutter_libserialport/flutter_libserialport.dart';

/// libserialport 0.3.0+1 transfers ownership at the start of its setter,
/// including when sp_set_config subsequently fails. Port disposal frees it.
void configureDesktopPort(
  SerialPort port, {
  SerialPortConfig Function()? createConfig,
}) {
  final config = (createConfig ?? SerialPortConfig.new)();
  var transferred = false;
  try {
    config.baudRate = 115200;
    config.bits = 8;
    config.stopBits = 1;
    config.parity = SerialPortParity.none;
    config.setFlowControl(SerialPortFlowControl.none);
    transferred = true;
    port.config = config;
  } finally {
    if (!transferred) config.dispose();
  }
}
