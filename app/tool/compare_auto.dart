import 'dart:convert';
import 'dart:io';
import 'package:ink_studio/imaging/auto_tune.dart';
import 'package:ink_studio/imaging/processor.dart';

// Software-only comparison. Does not open a port or send to the panel.
// From app: dart run tool/compare_auto.dart input.png
void main(List<String> args) {
  final source = args.isEmpty ? null : File(args.single).readAsBytesSync();
  final request = ProcessRequest(source, const ImageSettings());
  final before = processImage(request);
  final result = autoTune(request, onProgress: (p) => stdout.writeln(p.phase));
  final output = Directory('../build/auto-comparison')
    ..createSync(recursive: true);
  File('${output.path}/before.png').writeAsBytesSync(before.preview);
  File('${output.path}/after.png').writeAsBytesSync(result.image.preview);
  File('${output.path}/original.png').writeAsBytesSync(result.image.original);
  Map<String, double> metrics(AutoMetrics m) => {
    'score': m.score,
    'fine': m.fine,
    'coarse': m.coarse,
    'edge': m.edge,
    'grain': m.grain,
    'neutralInk': m.neutralInk,
    'paperSpeckles': m.paperSpeckles,
    'bias': m.bias,
  };
  final report = {
    'source': args.isEmpty ? 'builtin' : args.single,
    'kind': result.sourceKind,
    'candidates': result.candidates,
    'milliseconds': result.milliseconds,
    'settings': result.settings.toJson(),
    'baseline': metrics(result.baseline),
    'firstPass': metrics(result.firstPass),
    'finalPass': metrics(result.finalPass),
    'scope':
        'Software proxy metric only; not a panel or human-perception rating.',
  };
  final json = const JsonEncoder.withIndent('  ').convert(report);
  File('${output.path}/report.json').writeAsStringSync(json);
  stdout.writeln(json);
}
