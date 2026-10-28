import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'imaging/processor.dart';
import 'protocol/client.dart';
import 'protocol/codec.dart';
import 'transport/serial_transport.dart';

class StudioController extends ChangeNotifier {
  final SerialService serial;
  StudioController({SerialService? serial})
    : serial = serial ?? SerialService();
  ImageSettings settings = const ImageSettings();
  Uint8List? source;
  String imageName = '日落山野 · 内置示例';
  ProcessedImage? image;
  List<DevicePort> ports = [];
  String? selectedPort;
  int? panel;
  SepClient? client;
  Capabilities? capabilities;
  DeviceStatus? status;
  String? error, notice;
  bool scanning = false,
      connecting = false,
      processing = false,
      transferring = false;
  bool showOriginal = false,
      _disposed = false,
      _running = false,
      _cancel = false;
  int _revision = 0, _renderedRevision = -1;
  Timer? _debounce;
  SharedPreferences? _prefs;
  TransferProgress? progress;
  bool get connected => client != null;
  bool get fresh => image != null && _renderedRevision == _revision;
  bool get canSend =>
      connected &&
      fresh &&
      !processing &&
      !transferring &&
      panel != null &&
      status?.state != 3;
  void changed() {
    if (!_disposed) notifyListeners();
  }

  void report(Object e) {
    error = e.toString().replaceFirst(
      RegExp(r'^(Bad state|FormatException|Exception): '),
      '',
    );
    changed();
  }

  Future<void> initialize() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      final saved = _prefs!.getString('imageSettings');
      if (saved != null) {
        settings = ImageSettings.fromJson(
          jsonDecode(saved) as Map<String, dynamic>,
        );
      }
      final savedPanel = _prefs!.getInt('panel');
      if (savedPanel == 0 || savedPanel == 1) panel = savedPanel;
    } catch (_) {
      /* Invalid old preferences must not prevent startup. */
    }
    if (_disposed) return;
    scheduleProcess(immediate: true);
    await scan();
  }

  void updateSettings(ImageSettings value) {
    settings = value;
    unawaited(_saveSettings());
    scheduleProcess();
  }

  Future<void> _saveSettings() async {
    try {
      await _prefs?.setString('imageSettings', jsonEncode(settings.toJson()));
    } catch (_) {
      /* Preferences are optional. */
    }
  }

  void selectPanel(int? value) {
    panel = value;
    if (value != null) {
      unawaited(_savePanel(value));
    }
    changed();
  }

  Future<void> _savePanel(int value) async {
    try {
      await _prefs?.setInt('panel', value);
    } catch (_) {
      /* Optional. */
    }
  }

  void scheduleProcess({bool immediate = false}) {
    _revision++;
    processing = true;
    error = null;
    _debounce?.cancel();
    _debounce = Timer(
      Duration(milliseconds: immediate ? 0 : 200),
      _processLatest,
    );
    changed();
  }

  Future<void> _processLatest() async {
    if (_running || _disposed) return;
    _running = true;
    // Only one worker at a time. Slider changes replace pending work, never
    // accumulate isolates or allow an old preview to overwrite a newer one.
    while (!_disposed) {
      final revision = _revision;
      try {
        final result = await compute(
          processImage,
          ProcessRequest(source, settings),
        );
        if (_disposed) break;
        if (revision == _revision) {
          image = result;
          _renderedRevision = revision;
        }
      } catch (e) {
        if (revision == _revision) {
          error = e.toString();
          image = null;
        }
      }
      if (revision == _revision) break;
    }
    _running = false;
    processing = false;
    changed();
  }

  Future<void> importImage() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['png', 'jpg', 'jpeg', 'webp', 'bmp'],
        withData: false,
      );
      if (result == null || _disposed) return;
      final file = result.files.single;
      if (file.size > 25 * 1024 * 1024) {
        throw const FormatException('图片超过 25 MB，请先缩小');
      }
      final bytes = file.bytes ?? await File(file.path!).readAsBytes();
      if (_disposed) return;
      source = bytes;
      imageName = file.name;
      settings = settings.copyWith(rotation: 0);
      scheduleProcess(immediate: true);
    } catch (e) {
      report(e);
    }
  }

  void useDemo() {
    source = null;
    imageName = '日落山野 · 内置示例';
    scheduleProcess(immediate: true);
  }

  Future<void> exportImage({bool raw = false}) async {
    if (!fresh) return;
    try {
      final extension = raw ? 'epd' : 'png';
      final bytes = raw ? image!.packed : image!.preview;
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '导出四色图像',
        fileName: 'ink-studio.$extension',
        type: FileType.custom,
        allowedExtensions: [extension],
        bytes: bytes,
      );
      if (path != null) {
        notice = '已导出 ${raw ? '2bpp 原始帧' : '四色 PNG'}';
        changed();
      }
    } catch (e) {
      report(e);
    }
  }

  Future<void> scan() async {
    if (scanning || connecting || connected) return;
    scanning = true;
    changed();
    try {
      ports = await serial.list();
      if (!ports.any((p) => p.id == selectedPort)) {
        selectedPort = ports.firstOrNull?.id;
      }
    } catch (e) {
      report(e);
    }
    scanning = false;
    changed();
  }

  Future<void> connect() async {
    if (connecting || connected || selectedPort == null) return;
    connecting = true;
    error = null;
    changed();
    SepClient? candidate;
    try {
      final port = ports.firstWhere((p) => p.id == selectedPort);
      candidate = SepClient(await serial.connect(port));
      final info = await candidate.probe(Command.info);
      final caps = Capabilities(info.extra);
      if (!caps.compatible) throw StateError('设备并非兼容的 SEP/1 四色墨水屏');
      final current = await candidate.probe();
      if (_disposed) {
        await candidate.close();
        return;
      }
      client = candidate;
      capabilities = caps;
      status = current;
      candidate.onLinkError = (e) {
        report(e);
        unawaited(disconnect());
      };
      notice = '设备已连接 · 固件 ${caps.version}';
    } catch (e) {
      await candidate?.close();
      report(e);
    } finally {
      connecting = false;
      changed();
    }
  }

  Future<void> disconnect() async {
    final old = client;
    client = null;
    capabilities = null;
    status = null;
    await old?.close();
    changed();
  }

  Future<void> queryStatus() async {
    if (client == null || transferring) return;
    try {
      status = await client!.probe();
      notice = '设备状态：${status!.label}';
      changed();
    } catch (e) {
      report(e);
    }
  }

  Future<void> send() async {
    if (!canSend) return;
    transferring = true;
    _cancel = false;
    error = null;
    notice = null;
    progress = null;
    changed();
    final target = client!;
    final frame = image!.packed, batch = panel!, caps = capabilities!;
    try {
      await _keepAwake(true);
      await target.upload(
        frame,
        batch,
        caps,
        progress: (p) {
          progress = p;
          changed();
        },
        cancel: () => _cancel,
      );
      status = await target.probe();
      notice = '屏幕已确认刷新完成';
    } on UploadCancelled {
      notice = '已取消上传，可重新发送';
    } catch (e) {
      report(e);
    } finally {
      // A lost COMMIT reply may still mean a successful refresh. Query only;
      // never silently resend the frame or start another refresh.
      if (client == target) {
        try {
          status = await target.probe();
        } catch (_) {}
      }
      await _keepAwake(false);
      transferring = false;
      changed();
    }
  }

  void cancelTransfer() {
    if (transferring && !(progress?.committed ?? false)) {
      _cancel = true;
      notice = '正在取消…';
      changed();
    }
  }

  Future<void> _keepAwake(bool enabled) async {
    if (!Platform.isAndroid) return;
    try {
      await const MethodChannel(
        'io.serialepd/power',
      ).invokeMethod<void>('keepScreenOn', enabled);
    } on PlatformException catch (e) {
      report(e);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    unawaited(_keepAwake(false));
    unawaited(client?.close() ?? Future.value());
    super.dispose();
  }
}
