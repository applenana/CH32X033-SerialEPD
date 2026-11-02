import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'imaging/processor.dart';
import 'imaging/palette_calibration.dart';
import 'imaging/geometry.dart';
import 'imaging/auto_tune_job.dart';
import 'imaging/process_worker.dart';
import 'protocol/client.dart';
import 'protocol/codec.dart';
import 'transport/serial_transport.dart';

class StudioController extends ChangeNotifier {
  final SerialService serial;
  StudioController({SerialService? serial})
    : serial = serial ?? SerialService();
  ImageSettings settings = const ImageSettings();
  Uint8List? source;
  CropSpec? crop;
  String imageName = '日落山野 · 内置示例';
  int previewRotation = 0;
  ProcessedImage? image;
  bool autoTuning = false, _autoRequested = false;
  String? autoPhase, autoReport;
  double autoProgress = 0;
  AutoTuneJob? _autoJob;
  final ImageProcessWorker _processWorker = ImageProcessWorker();
  ImageSettings? _beforeAuto;
  bool get canUndoAuto => _beforeAuto != null && !autoTuning && !transferring;
  List<DevicePort> ports = [];
  String? selectedPort;
  int? panel;
  SepClient? client;
  SepClient? _connectingClient;
  int _connectGeneration = 0;
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
  int _preparationRevision = 0;
  int? _workerPreparationRevision;
  Uint8List? _workerSource;
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
        final json = jsonDecode(saved) as Map<String, dynamic>;
        settings = ImageSettings.fromJson(json);
      }
      final savedPanel = _prefs!.getInt('panel');
      if (savedPanel == 0 || savedPanel == 1) panel = savedPanel;
    } catch (_) {
      /* Invalid old preferences must not prevent startup. */
    }
    if (_disposed) return;
    unawaited(_saveSettings()); // Persist the one-time defaults migration.
    scheduleProcess(immediate: true);
    await scan();
  }

  void updateSettings(ImageSettings value) {
    if (value.rotation != settings.rotation || value.cover != settings.cover) {
      _preparationRevision++;
    }
    settings = value;
    unawaited(_saveSettings());
    scheduleProcess();
  }

  void resetSettings() {
    if (settings.rotation != 0 || settings.cover) _preparationRevision++;
    settings = const ImageSettings();
    notice = '全部图像参数已重置，已保留图片和裁切结果';
    unawaited(_saveSettings());
    scheduleProcess(immediate: true);
  }

  void updateCalibration(PaletteCalibration value) =>
      updateSettings(settings.copyWith(calibration: value));

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

  void scheduleProcess({bool immediate = false, bool forAuto = false}) {
    if (!forAuto) {
      _stopAuto();
      _beforeAuto = null;
      autoReport = null;
    }
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
        final prepare =
            _workerPreparationRevision != _preparationRevision ||
            !identical(_workerSource, source);
        final request = ProcessRequest(
          prepare ? source : null,
          settings,
          crop: prepare ? crop : null,
        );
        if (_autoRequested) {
          _autoRequested = false;
          final job = AutoTuneJob(
            request,
            onProgress: (p) {
              if (!_disposed && revision == _revision && autoTuning) {
                autoPhase = p.phase;
                autoProgress = p.fraction;
                changed();
              }
            },
          );
          _autoJob = job;
          final result = await job.result;
          if (_disposed) break;
          if (revision == _revision) {
            settings = result.settings;
            image = result.image;
            _renderedRevision = revision;
            autoTuning = false;
            _autoJob = null;
            autoReport =
                '${result.sourceKind} · 两轮比较 ${result.candidates} 组参数\n'
                '已选择 ${settings.mode.label}，可继续微调或撤销。';
            notice = 'AUTO 已完成：原图初调 → 四色图复评微调';
            unawaited(_saveSettings());
          }
        } else {
          // Publish a useful full-resolution preview quickly, then finish the
          // selected algorithm using the same prepared source. This keeps the
          // first visible result fast for every algorithm without changing the
          // final frame that can be sent to the panel.
          if (prepare && settings.mode != DitherMode.blueNoise) {
            final quick = await _processWorker.process(
              ProcessRequest(
                source,
                settings.copyWith(mode: DitherMode.blueNoise),
                crop: crop,
              ),
              preparationRevision: _preparationRevision,
              prepare: true,
            );
            if (_disposed) break;
            if (revision == _revision) {
              image = quick;
              _renderedRevision = -1;
              changed();
            }
          }
          final result = await _processWorker.process(
            request,
            preparationRevision: _preparationRevision,
            // The quick pass above prepared the same source and dimensions.
            // Reuse it; when the selected mode is blue-noise the first pass is
            // already the final pass and this branch is skipped.
            prepare: prepare && settings.mode == DitherMode.blueNoise,
          );
          if (prepare) {
            _workerPreparationRevision = _preparationRevision;
            _workerSource = source;
          }
          if (_disposed) break;
          if (revision == _revision) {
            image = result;
            _renderedRevision = revision;
          }
        }
      } on AutoCancelled {
        // The new revision (manual edit, cancel or import) is processed below.
      } catch (e) {
        if (revision == _revision) {
          error = e.toString();
          if (autoTuning) {
            _stopAuto();
            _beforeAuto = null;
            // Settings were not applied yet; restore the current preview.
            _revision++;
          } else {
            image = null;
          }
        }
      }
      if (revision == _revision) break;
    }
    _running = false;
    processing = false;
    changed();
  }

  void autoAdjust() {
    if (_disposed || autoTuning || transferring) return;
    _beforeAuto = settings;
    autoReport = null;
    autoTuning = true;
    _autoRequested = true;
    autoPhase = _running ? '等待当前图像处理完成…' : '准备分析原图…';
    autoProgress = 0;
    notice = null;
    scheduleProcess(immediate: true, forAuto: true);
  }

  void _stopAuto() {
    _autoRequested = false;
    _autoJob?.cancel();
    _autoJob = null;
    autoTuning = false;
    autoPhase = null;
    autoProgress = 0;
  }

  void cancelAuto() {
    if (!autoTuning) return;
    notice = '已取消 AUTO，保留原参数';
    scheduleProcess(immediate: true);
  }

  void undoAuto() {
    if (!canUndoAuto) return;
    final previous = _beforeAuto!;
    notice = '已恢复 AUTO 之前的参数';
    updateSettings(previous);
  }

  Future<void> importImage() async {
    try {
      Uint8List bytes;
      String name;
      if (Platform.isAndroid) {
        final picked = await const MethodChannel(
          'io.serialepd/gallery',
        ).invokeMapMethod<String, Object?>('pickImage');
        if (picked == null || _disposed) return;
        final imageBytes = picked['bytes'];
        if (imageBytes is! Uint8List) {
          throw const FormatException('无法读取所选图片');
        }
        if (imageBytes.length > 25 * 1024 * 1024) {
          throw const FormatException('图片超过 25 MB，请先缩小');
        }
        bytes = imageBytes;
        name = picked['name'] as String? ?? '相册图片';
      } else {
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
        bytes = file.bytes ?? await File(file.path!).readAsBytes();
        name = file.name;
      }
      if (_disposed) return;
      source = bytes;
      _preparationRevision++;
      _workerPreparationRevision = null;
      _workerSource = null;
      crop = null;
      imageName = name;
      previewRotation = 0;
      settings = settings.copyWith(rotation: 0);
      scheduleProcess(immediate: true);
    } catch (e) {
      report(e);
    }
  }

  void useDemo() {
    source = null;
    _preparationRevision++;
    _workerPreparationRevision = null;
    _workerSource = null;
    crop = null;
    imageName = '日落山野 · 内置示例';
    scheduleProcess(immediate: true);
  }

  Future<Uint8List> editingSource() async =>
      source ?? await compute(sampleSource, null);
  void applyCrop(CropSpec value) {
    crop = value;
    _preparationRevision++;
    _workerPreparationRevision = null;
    _workerSource = null;
    settings = settings.copyWith(rotation: 0);
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
    final generation = ++_connectGeneration;
    error = null;
    changed();
    SepClient? candidate;
    try {
      final port = ports.firstWhere((p) => p.id == selectedPort);
      candidate = SepClient(await serial.connect(port));
      if (_disposed || generation != _connectGeneration) {
        await candidate.close();
        return;
      }
      _connectingClient = candidate;
      final info = await candidate.identify();
      final caps = Capabilities(info.extra);
      if (!caps.compatible) throw StateError('设备并非兼容的 SEP/1 四色墨水屏');
      final current = await candidate.probe().timeout(
        const Duration(seconds: 3),
      );
      if (_disposed || generation != _connectGeneration) {
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
      try {
        await candidate?.close();
      } catch (_) {}
      if (generation == _connectGeneration) report(e);
    } finally {
      if (generation == _connectGeneration) {
        _connectingClient = null;
        connecting = false;
        changed();
      }
    }
  }

  void cancelConnect() {
    ++_connectGeneration;
    connecting = false;
    final pending = _connectingClient;
    _connectingClient = null;
    if (pending != null) unawaited(pending.close().catchError((Object _) {}));
    notice = '已取消连接，可以重新选择端口';
    changed();
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
    _stopAuto();
    cancelConnect();
    _debounce?.cancel();
    unawaited(_keepAwake(false));
    unawaited(_processWorker.close());
    unawaited(client?.close() ?? Future.value());
    super.dispose();
  }
}
