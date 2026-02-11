// tool/l10n_gen.dart
import 'dart:io';
import 'package:jaspr_l10n/jaspr_l10n.dart';

void main(List<String> args) async {
  String from = kFrom;
  String dartOut = kDartOut;
  String tsOut = kTsOut;
  String? fallbackLang;
  for (int i = 0; i < args.length; i++) {
    final param = args[i];
    final arg = args[i + 1];
    if (param == '-a' || param == '--arbs') {
      from = arg;
    } else if (param == '-d' || param == '--dart-out') {
      dartOut = arg;
    } else if (param == '-t' || param == '--ts-out') {
      tsOut = arg;
    } else if (param == '-f' || param == '--fallback-language') {
      fallbackLang = arg;
    } else {
      printHelp();
      throw ArgumentError('Unknown parameter: $param');
    }
    i++;
  }

  final arbDir = Directory(from);
  final outDart = File(dartOut);
  final outTs = File(tsOut);

  final bundles = await loadArbBundles(arbDir);
  final model = buildModel(bundles);
  validateModel(model, fallbackLang: fallbackLang);

  await outDart.create(recursive: true);
  await outTs.create(recursive: true);

  await outDart.writeAsString(generateDart(model));
  await outTs.writeAsString(generateTs(model));
}
