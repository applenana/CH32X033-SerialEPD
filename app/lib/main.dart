import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'imaging/processor.dart';
import 'imaging/palette_calibration.dart';
import 'studio_controller.dart';
import 'imaging/geometry.dart';
import 'widgets/crop_editor.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'OpenDisplay / OpenDithering DBS',
    ], await rootBundle.loadString('assets/licenses/reconstruction.txt'));
  });
  runApp(const InkStudio());
}

const ink = Color(0xff203d3b),
    paper = Color(0xfff5f4ef),
    muted = Color(0xff78817c);

class InkStudio extends StatelessWidget {
  final StudioController? controller;
  const InkStudio({super.key, this.controller});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '墨屿 · Ink Studio',
    debugShowCheckedModeBanner: false,
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: paper,
      fontFamilyFallback: const [
        'Microsoft YaHei',
        'Noto Sans CJK SC',
        'sans-serif',
      ],
      colorScheme: ColorScheme.fromSeed(
        seedColor: ink,
        surface: const Color(0xfffdfcf8),
      ),
      dividerColor: const Color(0xffe5e7df),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xfff4f5ef),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: ink,
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 19),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      sliderTheme: const SliderThemeData(
        trackHeight: 3,
        thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
      ),
    ),
    home: StudioPage(controller: controller),
  );
}

class StudioPage extends StatefulWidget {
  final StudioController? controller;
  const StudioPage({super.key, this.controller});
  @override
  State<StudioPage> createState() => _StudioPageState();
}

class _StudioPageState extends State<StudioPage> {
  late final StudioController c;
  bool _openingEditor = false;

  void _rotatePreviewFrame(int delta) {
    c.previewRotation = (c.previewRotation + delta) % 4;
    c.changed();
  }

  Future<void> _editPalette() async {
    final current = c.settings.calibration;
    final values = current.colors
        .expand((row) => row.map((v) => (v * 255).round().toString()))
        .map((v) => TextEditingController(text: v))
        .toList();
    final result = await showDialog<PaletteCalibration>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('实测色板 RGB'),
        content: StatefulBuilder(
          builder: (context, setState) => SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '输入统一拍摄条件下的黑、白、黄、红中心区域 RGB（0–255）。',
                  style: TextStyle(fontSize: 11),
                ),
                const SizedBox(height: 12),
                for (var row = 0; row < 4; row++)
                  Row(
                    children: [
                      SizedBox(
                        width: 34,
                        child: Text(['黑', '白', '黄', '红'][row]),
                      ),
                      for (var col = 0; col < 3; col++)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: TextField(
                              controller: values[row * 3 + col],
                              keyboardType: TextInputType.number,
                              decoration: InputDecoration(
                                labelText: ['R', 'G', 'B'][col],
                              ),
                              onChanged: (_) => setState(() {}),
                            ),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final rgb = values
                  .map((v) => int.tryParse(v.text.trim()) ?? -1)
                  .toList();
              if (rgb.any((v) => v < 0 || v > 255)) return;
              Navigator.pop(
                dialogContext,
                PaletteCalibration.fromRgb8(
                  black: rgb.sublist(0, 3),
                  white: rgb.sublist(3, 6),
                  yellow: rgb.sublist(6, 9),
                  red: rgb.sublist(9, 12),
                ),
              );
            },
            child: const Text('应用'),
          ),
        ],
      ),
    );
    for (final value in values) {
      value.dispose();
    }
    if (result != null) c.updateCalibration(result);
  }

  Future<void> _editCrop() async {
    if (_openingEditor) return;
    setState(() => _openingEditor = true);
    final originalSource = c.source;
    try {
      final bytes = await c.editingSource();
      if (!mounted || !identical(originalSource, c.source)) return;
      final result = await Navigator.of(context).push<CropSpec>(
        MaterialPageRoute(
          builder: (_) => CropEditor(
            source: bytes,
            initial:
                c.crop ??
                (c.settings.rotation == 0
                    ? null
                    : CropSpec(angle: c.settings.rotation * 90)),
          ),
        ),
      );
      if (result != null && identical(originalSource, c.source)) {
        c.applyCrop(result);
      }
    } catch (e) {
      c.report(e);
    } finally {
      if (mounted) setState(() => _openingEditor = false);
    }
  }

  @override
  void initState() {
    super.initState();
    c = widget.controller ?? StudioController();
    if (widget.controller == null) c.initialize();
  }

  @override
  void dispose() {
    if (widget.controller == null) c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) => LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 1150, mobile = box.maxWidth < 700;
        return Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                _header(mobile),
                Expanded(
                  child: wide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 248,
                              child: ListView(
                                padding: const EdgeInsets.fromLTRB(
                                  24,
                                  12,
                                  16,
                                  24,
                                ),
                                children: [
                                  _connection(),
                                  const SizedBox(height: 20),
                                  _guide(),
                                ],
                              ),
                            ),
                            Expanded(
                              child: ListView(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  12,
                                  20,
                                  24,
                                ),
                                children: [
                                  _canvas(mobile),
                                  const SizedBox(height: 20),
                                  _transfer(),
                                ],
                              ),
                            ),
                            SizedBox(
                              width: 310,
                              child: ListView(
                                padding: const EdgeInsets.fromLTRB(
                                  0,
                                  12,
                                  24,
                                  24,
                                ),
                                children: [_settings()],
                              ),
                            ),
                          ],
                        )
                      : ListView(
                          padding: EdgeInsets.all(mobile ? 16 : 28),
                          children: [
                            mobile ? _compactConnection() : _connection(),
                            const SizedBox(height: 20),
                            _canvas(mobile),
                            const SizedBox(height: 20),
                            _settings(compact: mobile),
                            const SizedBox(height: 20),
                            _transfer(),
                            const SizedBox(height: 16),
                            _guide(),
                          ],
                        ),
                ),
                if (c.error != null || c.notice != null) _message(),
              ],
            ),
          ),
          bottomNavigationBar: mobile
              ? SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                    child: _sendButton(),
                  ),
                )
              : null,
        );
      },
    ),
  );
  Widget _header(bool mobile) => Padding(
    padding: EdgeInsets.fromLTRB(mobile ? 20 : 32, 24, mobile ? 20 : 32, 22),
    child: Row(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: ink,
            borderRadius: BorderRadius.circular(13),
          ),
          child: const Icon(
            Icons.landscape_rounded,
            color: Color(0xfff6d56c),
            size: 28,
          ),
        ),
        const SizedBox(width: 12),
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '墨屿',
              style: TextStyle(
                fontSize: 23,
                fontWeight: FontWeight.w700,
                letterSpacing: 3,
                color: ink,
              ),
            ),
            Text(
              'INK STUDIO',
              style: TextStyle(fontSize: 9, letterSpacing: 2.4, color: muted),
            ),
          ],
        ),
        const Spacer(),
        if (!mobile)
          const Text(
            '让喜欢的画面，停留久一点。',
            style: TextStyle(color: muted, fontSize: 13),
          ),
        const SizedBox(width: 20),
        IconButton(
          tooltip: '关于与开源许可',
          icon: const Icon(Icons.info_outline_rounded, size: 18),
          onPressed: () => showAboutDialog(
            context: context,
            applicationName: '墨屿 · Ink Studio',
            applicationVersion: '0.4.0',
            children: const [
              Text(
                '面向黑 / 白 / 黄 / 红电子纸的离线图像工作台。\nSEP/1 · Windows 串口与 Android USB OTG。',
              ),
            ],
          ),
        ),
        _pill('四色电子纸', const Color(0xffe8eadf)),
      ],
    ),
  );
  Widget _card(Widget child) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: const Color(0xfffdfcf8),
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: const Color(0xffe6e7df)),
    ),
    child: child,
  );
  Widget _pill(String text, Color bg) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 11,
        color: ink,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
  Widget _title(String text, String subtitle, {IconData? icon}) => Row(
    children: [
      if (icon != null) ...[
        Icon(icon, size: 19, color: ink),
        const SizedBox(width: 8),
      ],
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              text,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: ink,
              ),
            ),
            if (subtitle.isNotEmpty) ...[
              const SizedBox(height: 5),
              Text(
                subtitle,
                style: const TextStyle(fontSize: 11, color: muted),
              ),
            ],
          ],
        ),
      ),
    ],
  );
  Widget _compactConnection() => Container(
    decoration: BoxDecoration(
      color: const Color(0xfffdfcf8),
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: const Color(0xffe6e7df)),
    ),
    child: ExpansionTile(
      shape: const Border(),
      collapsedShape: const Border(),
      leading: Icon(
        c.connected ? Icons.usb_rounded : Icons.usb_off_rounded,
        color: ink,
      ),
      title: const Text(
        '我的设备',
        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        c.connected
            ? '${c.selectedPort} · ${c.status?.label ?? '已连接'}'
            : '点击连接 USB 设备',
        style: const TextStyle(fontSize: 11, color: muted),
      ),
      children: [_connection()],
    ),
  );
  Widget _connection() => _card(
    Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _title('我的设备', 'USB CDC · 即连即用', icon: Icons.usb_rounded),
        const SizedBox(height: 18),
        if (c.connected) ...[
          _pill(c.status?.label ?? '已连接', const Color(0xffe5efe5)),
          const SizedBox(height: 12),
          Text(
            '${c.selectedPort} · 768 × 552',
            style: const TextStyle(fontSize: 12, color: muted),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: c.transferring ? null : c.queryStatus,
                  child: const Text('查询状态'),
                ),
              ),
              IconButton(
                tooltip: '断开连接',
                onPressed: c.transferring ? null : c.disconnect,
                icon: const Icon(Icons.link_off_rounded),
              ),
            ],
          ),
        ] else ...[
          DropdownButtonFormField<String>(
            initialValue: c.ports.any((p) => p.id == c.selectedPort)
                ? c.selectedPort
                : null,
            key: ValueKey(
              '${c.selectedPort}:${c.ports.map((p) => p.id).join()}',
            ),
            isExpanded: true,
            hint: Text(
              c.scanning ? '搜索设备…' : '选择 USB 设备',
              style: const TextStyle(fontSize: 12),
            ),
            items: c.ports
                .map(
                  (p) => DropdownMenuItem(
                    value: p.id,
                    child: Text(
                      '${p.recommended ? '● ' : ''}${p.name}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                )
                .toList(),
            onChanged: c.connecting
                ? null
                : (v) {
                    c.selectedPort = v;
                    c.changed();
                  },
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: c.connecting
                      ? c.cancelConnect
                      : c.selectedPort == null
                      ? null
                      : c.connect,
                  child: Text(c.connecting ? '取消连接' : '连接设备'),
                ),
              ),
              IconButton(
                tooltip: '重新搜索串口',
                onPressed: c.scanning || c.connecting ? null : c.scan,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          if (c.ports.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Text(
                '连接 USB 数据线后搜索。安卓设备需要支持 USB OTG。',
                style: TextStyle(fontSize: 11, height: 1.6, color: muted),
              ),
            ),
        ],
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Divider(),
        ),
        DropdownButtonFormField<int>(
          initialValue: c.panel,
          key: ValueKey(c.panel),
          isExpanded: true,
          decoration: const InputDecoration(labelText: '屏幕批次'),
          hint: const Text('选择 A0 / A1'),
          items: const [
            DropdownMenuItem(value: 0, child: Text('A0 批次')),
            DropdownMenuItem(value: 1, child: Text('A1 批次')),
          ],
          onChanged: c.transferring ? null : c.selectPanel,
        ),
        const SizedBox(height: 8),
        const Text(
          '按屏幕实际批次选择；两种初始化方式不同。',
          style: TextStyle(fontSize: 11, height: 1.6, color: muted),
        ),
      ],
    ),
  );
  Widget _canvas(bool mobile) => _card(
    Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: _title('画布', c.imageName)),
            TextButton.icon(
              onPressed: _openingEditor ? null : _editCrop,
              icon: const Icon(Icons.crop_rotate_rounded),
              label: const Text('裁切'),
            ),
            IconButton(
              tooltip: '旋转预览框',
              onPressed: () => _rotatePreviewFrame(1),
              icon: const Icon(Icons.screen_rotation_alt_rounded),
            ),
            PopupMenuButton<String>(
              tooltip: '导出与示例',
              onSelected: (v) {
                if (v == 'demo') {
                  c.useDemo();
                } else {
                  c.exportImage(raw: v == 'raw');
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'png',
                  enabled: c.fresh,
                  child: const Text('导出四色 PNG'),
                ),
                PopupMenuItem(
                  value: 'raw',
                  enabled: c.fresh,
                  child: const Text('导出 2bpp 原始帧'),
                ),
                const PopupMenuItem(value: 'demo', child: Text('使用内置示例')),
              ],
            ),
          ],
        ),
        const SizedBox(height: 20),
        Container(
          padding: EdgeInsets.all(mobile ? 12 : 24),
          decoration: BoxDecoration(
            color: const Color(0xffe7e9e7),
            borderRadius: BorderRadius.circular(16),
          ),
          child: AspectRatio(
            aspectRatio: c.previewRotation.isEven ? 1448 / 1086 : 1086 / 1448,
            child: RotatedBox(
              quarterTurns: c.previewRotation,
              child: LayoutBuilder(
                builder: (context, bounds) => Container(
                  key: const ValueKey('device-frame-preview'),
                  foregroundDecoration: const BoxDecoration(
                    image: DecorationImage(
                      image: AssetImage('assets/device_frame.png'),
                      fit: BoxFit.fill,
                      filterQuality: FilterQuality.high,
                    ),
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Positioned(
                        left: bounds.maxWidth * (158 / 1448),
                        top: bounds.maxHeight * (236 / 1086),
                        width: bounds.maxWidth * (980 / 1448),
                        height: bounds.maxHeight * (598 / 1086),
                        child: ClipRect(
                          child: c.image == null
                              ? const ColoredBox(
                                  color: Color(0xfff4f5f1),
                                  child: Center(
                                    child: Icon(
                                      Icons.landscape_outlined,
                                      color: muted,
                                      size: 56,
                                    ),
                                  ),
                                )
                              : InteractiveViewer(
                                  minScale: 1,
                                  maxScale: 5,
                                  child: Image.memory(
                                    c.showOriginal
                                        ? c.image!.original
                                        : c.image!.preview,
                                    gaplessPlayback: true,
                                    filterQuality: FilterQuality.medium,
                                    fit: BoxFit.cover,
                                  ),
                                ),
                        ),
                      ),
                      if (c.processing)
                        Align(
                          alignment: Alignment.topCenter,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                            margin: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: .94),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Text(
                              '正在生成四色预览…',
                              style: TextStyle(fontSize: 11, color: ink),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 12,
          children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('四色预览')),
                ButtonSegment(value: true, label: Text('原图')),
              ],
              selected: {c.showOriginal},
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              onSelectionChanged: (v) {
                c.showOriginal = v.first;
                c.changed();
              },
            ),
            const Text(
              '768 × 552  /  2 bit',
              style: TextStyle(fontSize: 11, color: muted),
            ),
          ],
        ),
        const SizedBox(height: 18),
        OutlinedButton.icon(
          onPressed: c.importImage,
          icon: const Icon(Icons.add_photo_alternate_outlined, size: 19),
          label: const Padding(
            padding: EdgeInsets.symmetric(vertical: 13),
            child: Text('导入图片'),
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          'PNG / JPG / WebP / BMP · 可缩放查看细节',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 10, color: muted),
        ),
      ],
    ),
  );
  Widget _settings({bool compact = false}) => _card(
    compact
        ? ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            initiallyExpanded: false,
            leading: const Icon(Icons.tune_rounded, color: ink),
            title: const Text(
              '更多配置',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: const Text(
              '默认参数已就绪，点击展开调节',
              style: TextStyle(fontSize: 11, color: muted),
            ),
            children: [_settingsBody()],
          )
        : _settingsBody(),
  );
  Widget _settingsBody() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _title('四色调色室', '为电子纸，找到恰好的层次。', icon: Icons.tune_rounded),
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: c.autoTuning
            ? c.cancelAuto
            : c.transferring
            ? null
            : c.autoAdjust,
        icon: Icon(
          c.autoTuning ? Icons.stop_rounded : Icons.auto_fix_high_rounded,
          size: 18,
        ),
        label: Text(c.autoTuning ? '取消 AUTO' : 'AUTO · 自动优化'),
      ),
      if (c.autoTuning) ...[
        const SizedBox(height: 8),
        LinearProgressIndicator(value: c.autoProgress),
        const SizedBox(height: 6),
        Text(
          c.autoPhase ?? '正在分析原图…',
          style: const TextStyle(fontSize: 11, color: muted),
        ),
      ] else if (c.autoReport != null) ...[
        const SizedBox(height: 8),
        Text(
          c.autoReport!,
          style: const TextStyle(fontSize: 11, color: muted, height: 1.6),
        ),
        if (c.canUndoAuto)
          TextButton(onPressed: c.undoAuto, child: const Text('撤销 AUTO')),
      ],
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: c.resetSettings,
        icon: const Icon(Icons.restart_alt_rounded, size: 18),
        label: const Text('重置所有参数'),
      ),
      const Padding(
        padding: EdgeInsets.only(top: 4, bottom: 16),
        child: Text(
          '一键恢复算法、调色和适配默认值，保留图片与裁切。',
          style: TextStyle(fontSize: 10, color: muted, height: 1.6),
        ),
      ),
      Row(
        children: [
          Expanded(child: _preset('照片', DitherMode.perceptual)),
          const SizedBox(width: 5),
          Expanded(child: _preset('插画', DitherMode.burkes)),
          const SizedBox(width: 5),
          Expanded(child: _preset('文字', DitherMode.none)),
        ],
      ),
      const SizedBox(height: 18),
      DropdownButtonFormField<DitherMode>(
        initialValue: c.settings.mode,
        key: ValueKey(c.settings.mode),
        isExpanded: true,
        decoration: const InputDecoration(labelText: '图像重建方式'),
        items: DitherMode.values
            .map(
              (m) => DropdownMenuItem(
                value: m,
                child: Text(m.label, style: const TextStyle(fontSize: 12)),
              ),
            )
            .toList(),
        onChanged: (m) {
          if (m != null) c.updateSettings(c.settings.copyWith(mode: m));
        },
      ),
      const SizedBox(height: 10),
      Text(
        c.settings.mode.description,
        style: const TextStyle(fontSize: 11, color: muted, height: 1.6),
      ),
      const SizedBox(height: 18),
      _slider(
        '亮度',
        c.settings.brightness,
        -.3,
        .3,
        (v) => c.settings.copyWith(brightness: v),
      ),
      _slider(
        '对比度',
        c.settings.contrast,
        .5,
        1.8,
        (v) => c.settings.copyWith(contrast: v),
      ),
      _slider(
        '饱和度',
        c.settings.saturation,
        0,
        2,
        (v) => c.settings.copyWith(saturation: v),
      ),
      if (c.settings.mode != DitherMode.perceptual &&
          c.settings.mode != DitherMode.blueNoise)
        _slider(
          '抖动强度',
          c.settings.strength,
          0,
          1,
          (v) => c.settings.copyWith(strength: v),
        ),
      const Divider(height: 24),
      Row(
        children: [
          const Text('画面适配', style: TextStyle(fontSize: 12)),
          const Spacer(),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('完整')),
              ButtonSegment(value: true, label: Text('铺满')),
            ],
            selected: {c.settings.cover},
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            onSelectionChanged: (v) =>
                c.updateSettings(c.settings.copyWith(cover: v.first)),
          ),
        ],
      ),
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        title: const Text('高级调节', style: TextStyle(fontSize: 12)),
        children: [
          _slider(
            'Gamma',
            c.settings.gamma,
            .5,
            2,
            (v) => c.settings.copyWith(gamma: v),
          ),
          if (c.settings.mode != DitherMode.perceptual &&
              c.settings.mode != DitherMode.blueNoise)
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('感知色彩匹配', style: TextStyle(fontSize: 12)),
              subtitle: const Text(
                'OKLab 色彩距离',
                style: TextStyle(fontSize: 10),
              ),
              value: c.settings.perceptual,
              onChanged: (v) =>
                  c.updateSettings(c.settings.copyWith(perceptual: v)),
            ),
          if (c.settings.mode != DitherMode.perceptual &&
              c.settings.mode != DitherMode.blueNoise)
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('蛇形扫描', style: TextStyle(fontSize: 12)),
              value: c.settings.serpentine,
              onChanged: (v) =>
                  c.updateSettings(c.settings.copyWith(serpentine: v)),
            ),
        ],
      ),
      const SizedBox(height: 12),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: List.generate(
          4,
          (i) => Column(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: [
                    const Color(0xff202923),
                    Colors.white,
                    const Color(0xffffd04a),
                    const Color(0xffd95040),
                  ][i],
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xffdcded6)),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                c.image == null
                    ? ['黑', '白', '黄', '红'][i]
                    : '${(c.image!.counts[i] / c.image!.indices.length * 100).round()}%',
                style: const TextStyle(fontSize: 10, color: muted),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      const Text(
        '原生黑白黄红四色；灰阶由网点混色呈现。实体颜色受光线与面板批次影响。',
        style: TextStyle(fontSize: 10, color: muted, height: 1.6),
      ),
      const Divider(height: 28),
      _slider(
        '观看柔和度',
        c.settings.softness,
        0,
        1,
        (v) => c.settings.copyWith(softness: v),
        enabled: c.settings.mode == DitherMode.perceptual,
      ),
      _slider(
        '自然映射',
        c.settings.naturalMapping,
        0,
        1,
        (v) => c.settings.copyWith(naturalMapping: v),
      ),
      _slider(
        '纸白保护',
        c.settings.paperWhite,
        0,
        .15,
        (v) => c.settings.copyWith(paperWhite: v),
        enabled:
            c.settings.mode == DitherMode.perceptual ||
            c.settings.mode == DitherMode.blueNoise,
      ),
      _slider(
        '动态范围压缩',
        c.settings.dynamicRange,
        0,
        1,
        (v) => c.settings.copyWith(dynamicRange: v),
      ),
      _slider(
        '色域压缩',
        c.settings.gamutCompression,
        0,
        1,
        (v) => c.settings.copyWith(gamutCompression: v),
        enabled:
            c.settings.mode == DitherMode.perceptual ||
            c.settings.mode == DitherMode.blueNoise,
      ),
      OutlinedButton.icon(
        onPressed: _editPalette,
        icon: Icon(
          c.settings.calibration.enabled
              ? Icons.colorize
              : Icons.palette_outlined,
          size: 17,
        ),
        label: Text(c.settings.calibration.enabled ? '编辑实测色板' : '输入实测色板'),
      ),
      if (c.settings.calibration.enabled)
        TextButton(
          onPressed: () => c.updateCalibration(PaletteCalibration.ideal),
          child: const Text('恢复理想色板'),
        ),
      const Text(
        '动态范围：温和调整暗部与高光，保留纯黑纯白。色域压缩：仅用于 DBS / 蓝噪声，保持可达亮度，降低超色域偏色；域内颜色不变。自然映射较强时，色域滑块变化可能较小。两项默认关闭，并非越高越好。',
        style: TextStyle(fontSize: 10, color: muted, height: 1.6),
      ),
    ],
  );
  Widget _preset(String name, DitherMode mode) => OutlinedButton(
    style: OutlinedButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      backgroundColor: c.settings.mode == mode ? const Color(0xffe9eddf) : null,
    ),
    onPressed: () => c.updateSettings(
      ImageSettings(
        mode: mode,
        rotation: c.settings.rotation,
        cover: c.settings.cover,
      ),
    ),
    child: Text(name, style: const TextStyle(fontSize: 12)),
  );
  Widget _slider(
    String name,
    double value,
    double min,
    double max,
    ImageSettings Function(double) update, {
    bool enabled = true,
  }) => Column(
    children: [
      Row(
        children: [
          Text(name, style: const TextStyle(fontSize: 12)),
          const Spacer(),
          Text(
            value.toStringAsFixed(2),
            style: const TextStyle(fontSize: 11, color: muted),
          ),
        ],
      ),
      Slider(
        value: value,
        min: min,
        max: max,
        onChanged: enabled ? (v) => c.updateSettings(update(v)) : null,
      ),
    ],
  );
  Future<void> _choosePanel() async {
    if (!mounted || c.transferring || !c.connected || !c.fresh) return;
    final value = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('选择屏幕批次'),
        content: RadioGroup<int>(
          groupValue: c.panel,
          onChanged: (value) => Navigator.pop(context, value),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<int>(value: 0, title: Text('A0 批次')),
              RadioListTile<int>(value: 1, title: Text('A1 批次')),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (value != null && mounted) c.selectPanel(value);
  }

  Future<void> _connectFromSend() async {
    if (!mounted || c.transferring || c.connected || !c.fresh) return;
    await c.scan();
    if (!mounted || c.ports.isEmpty) {
      if (mounted && c.ports.isEmpty) {
        c.notice = '未找到 USB 设备，请检查连接和 OTG';
        c.changed();
      }
      return;
    }
    await c.connect();
  }

  Widget _sendButton() => FilledButton.icon(
    onPressed: c.canSend
        ? c.send
        : !c.connected && c.fresh && !c.transferring
        ? _connectFromSend
        : c.connected && c.fresh && !c.transferring && c.panel == null
        ? _choosePanel
        : null,
    icon: const Icon(Icons.send_rounded, size: 18),
    label: Text(
      c.transferring
          ? c.progress?.phase ?? '正在连接设备…'
          : !c.connected
          ? '连接设备后发送'
          : c.panel == null
          ? '请先选择屏幕批次'
          : c.status?.state == 3
          ? '屏幕正在刷新'
          : '发送到墨水屏',
    ),
  );
  Widget _transfer() => _card(
    Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _title(
                c.progress?.phase ?? '把画面留在纸上',
                c.transferring
                    ? '请保持 USB 连接，刷新可能需要数分钟。'
                    : '105,984 字节 · 整帧 CRC 校验',
                icon: Icons.auto_awesome_outlined,
              ),
            ),
            if (c.transferring && !(c.progress?.committed ?? false))
              TextButton(onPressed: c.cancelTransfer, child: const Text('取消')),
          ],
        ),
        if (c.transferring) ...[
          const SizedBox(height: 16),
          LinearProgressIndicator(
            value: c.progress?.phase == '传输图像' ? c.progress!.fraction : null,
            borderRadius: BorderRadius.circular(5),
          ),
          const SizedBox(height: 8),
          Text(
            c.progress?.phase == '传输图像'
                ? '${(c.progress!.fraction * 100).round()}% · 已由设备确认'
                : '等待设备确认状态',
            style: const TextStyle(fontSize: 11, color: muted),
          ),
        ],
        const SizedBox(height: 18),
        _sendButton(),
      ],
    ),
  );
  Widget _guide() => Padding(
    padding: const EdgeInsets.all(8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '从一张图片开始',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: ink,
          ),
        ),
        const SizedBox(height: 12),
        ...['01   连接设备，选择屏幕批次', '02   导入图片，调整四色效果', '03   发送画面，等待刷新完成'].map(
          (t) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              t,
              style: const TextStyle(fontSize: 11, color: muted, height: 1.5),
            ),
          ),
        ),
        const Text(
          '离线处理 · 图片留在你的设备上',
          style: TextStyle(fontSize: 10, color: muted),
        ),
      ],
    ),
  );
  Widget _message() => Container(
    color: c.error != null ? const Color(0xffffebe4) : const Color(0xffe5eee5),
    padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
    child: Row(
      children: [
        Icon(
          c.error != null ? Icons.info_outline : Icons.check_circle_outline,
          size: 17,
          color: ink,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            c.error ?? c.notice!,
            style: const TextStyle(fontSize: 12, height: 1.5, color: ink),
          ),
        ),
        IconButton(
          tooltip: '关闭提示',
          onPressed: () {
            c.error = null;
            c.notice = null;
            c.changed();
          },
          icon: const Icon(Icons.close, size: 16),
        ),
      ],
    ),
  );
}
