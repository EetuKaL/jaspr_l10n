// tool/l10n_gen.dart
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

const kFrom = 'lib/l10n';
const kDartOut = 'lib/generated/l10n.g.dart';
const kJsOut = 'web/generated/l10n.js';

void printHelp() {
  print('Usage: dart tool/l10n_gen.dart');
  print('Generates Localization files from .arb bundles, one for Dart and one for TypeScript.');
  print('Parameters:');
  print(' -a/--arbs <Directory>   Source directory for .arb files (default: $kFrom)');
  print(' -d/--dart-out <File>    Output Dart file (default: $kDartOut)');
  print(' -j/--js-out <File>      Output JavaScript file (default: $kJsOut)');
  print(
    ' -f/--fallback-language  Fallback language code to use if some locale is missing a key (e.g. "en"), Otherwise arbs must have same keys, or generation will fail.',
  );
}

Future<Map<String, Map<String, dynamic>>> loadArbBundles(Directory dir) async {
  final result = <String, Map<String, dynamic>>{};
  final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.arb')).toList();

  for (final f in files) {
    final jsonMap = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    final locale = (jsonMap['@@locale'] ?? inferLocaleFromFilename(f.path)) as String;
    result[locale] = jsonMap;
  }
  return result;
}

String inferLocaleFromFilename(String path) {
  final name = path.split(Platform.pathSeparator).last;
  final m = RegExp(r'_([a-z]{2}(-[A-Z]{2})?)\.arb$').firstMatch(name);
  if (m == null) throw Exception('Cannot infer locale from: $name');
  return m.group(1)!;
}

L10nModel buildModel(Map<String, Map<String, dynamic>> bundles) {
  final locales = bundles.keys.toList()..sort();
  final entries = <String, L10nEntry>{};

  for (final locale in locales) {
    final map = bundles[locale]!;
    for (final kv in map.entries) {
      final key = kv.key;
      if (key.startsWith('@')) continue; // metadata
      final value = kv.value;
      if (value is! String) continue;

      final entry = entries.putIfAbsent(key, () => L10nEntry(key));
      entry.valuesByLocale[locale] = value;
    }
  }

  for (final locale in locales) {
    final map = bundles[locale]!;
    for (final kv in map.entries) {
      if (!kv.key.startsWith('@') || kv.key.startsWith('@@')) continue;
      final key = kv.key.substring(1);
      final meta = kv.value;
      if (meta is Map && meta['placeholders'] is Map) {
        final placeholders = (meta['placeholders'] as Map).keys.cast<String>();
        entries[key]?.placeholders.addAll(placeholders);
      }
    }
  }

  return L10nModel(locales: locales, entries: entries);
}

void validateModel(L10nModel model, {String? fallbackLang}) {
  for (final e in model.entries.values) {
    for (final loc in model.locales) {
      if (!e.valuesByLocale.containsKey(loc)) {
        if (fallbackLang != null && e.valuesByLocale.containsKey(fallbackLang)) {
          e.valuesByLocale[loc] = e.valuesByLocale[fallbackLang]!;
          continue;
        }
        throw Exception('Missing "$loc" translation for key: ${e.key}');
      }
    }
    final inferred = inferPlaceholdersFromAnyValue(e.valuesByLocale.values);
    if (e.placeholders.isEmpty) e.placeholders.addAll(inferred);
  }
}

Set<String> inferPlaceholdersFromAnyValue(Iterable<String> values) {
  final set = <String>{};
  final re = RegExp(r'\{([a-zA-Z_][a-zA-Z0-9_]*)\}');
  for (final v in values) {
    for (final m in re.allMatches(v)) {
      set.add(m.group(1)!);
    }
  }
  return set;
}

String generateDart(L10nModel model) {
  final b = StringBuffer();

  b.writeln('// GENERATED - do not edit.');
  b.writeln("import 'dart:convert';");
  b.writeln("import 'package:jaspr/jaspr.dart';");
  b.writeln("import 'package:jaspr/dom.dart';");
  b.writeln('');
  b.writeln('class L10n {');
  b.writeln('  const L10n();');
  b.writeln('');
  b.writeln('  static Component getSpan(String key, {Map<String, Object?>? params}) {');
  b.writeln('    return span(');
  b.writeln('      attributes: {');
  b.writeln("        'data-i18n': key,");
  b.writeln("        if (params != null) 'data-i18n-params': jsonEncode(params),");
  b.writeln('      },');
  b.writeln('      const [],');
  b.writeln('    );');
  b.writeln('  }');
  b.writeln('');

  // Collect keys
  final keys = model.entries.keys.toList()..sort();

  // Write getters/methods
  for (final key in keys) {
    final params = _extractParamsForKey(model, key).toList()..sort();

    final memberName = _toMemberName(key);

    if (params.isEmpty) {
      // getter
      b.writeln('  static Component get $memberName => L10n.getSpan(\'$key\');');
    } else {
      // method with named required params
      final sig = params.map((p) => 'required String? ${_toParamName(p)}').join(', ');
      final mapEntries = params.map((p) => "'$p': ${_toParamName(p)}").join(', ');
      b.writeln('  static Component $memberName({$sig}) =>');
      b.writeln('      L10n.getSpan(\'$key\', params: {$mapEntries});');
    }
    b.writeln('');
  }

  b.writeln('}');
  b.writeln('');
  b.writeln('const l10n = L10n();');

  return b.toString();
}

/// Union of {placeholders} across all locales for a given key.
Iterable<String> _extractParamsForKey(L10nModel model, String key) sync* {
  final entry = model.entries[key];
  if (entry == null) return;

  final seen = <String>{};
  final re = RegExp(r'\{([a-zA-Z_][a-zA-Z0-9_]*)\}');

  for (final loc in model.locales) {
    final s = entry.valuesByLocale[loc];
    if (s == null) continue;

    for (final m in re.allMatches(s)) {
      final name = m.group(1);
      if (name != null && seen.add(name)) yield name;
    }
  }
}

String _toMemberName(String key) {
  // e.g. "welcome.message" -> "welcomeMessage"
  final pascal = _toPascalCase(_sanitizeParts(key));
  final camel = pascal.isEmpty ? 'key' : (pascal[0].toLowerCase() + pascal.substring(1));
  return _avoidReserved(camel);
}

String _toParamName(String p) => _avoidReserved(_toMemberName(p));

List<String> _sanitizeParts(String s) {
  // Split on non-identifier chars
  final parts = s.split(RegExp(r'[^a-zA-Z0-9_]+')).where((x) => x.isNotEmpty).toList();
  if (parts.isEmpty) return ['key'];
  // If starts with digit, prefix
  if (RegExp(r'^\d').hasMatch(parts.first)) parts[0] = 'k${parts.first}';
  return parts;
}

String _toPascalCase(List<String> parts) {
  return parts.map((p) {
    if (p.isEmpty) return '';
    final lower = p.toLowerCase();
    return lower[0].toUpperCase() + lower.substring(1);
  }).join();
}

String _avoidReserved(String name) {
  const reserved = {
    'class',
    'enum',
    'extends',
    'with',
    'implements',
    'import',
    'export',
    'library',
    'part',
    'return',
    'if',
    'else',
    'for',
    'while',
    'do',
    'switch',
    'case',
    'default',
    'break',
    'continue',
    'try',
    'catch',
    'finally',
    'throw',
    'new',
    'const',
    'var',
    'final',
    'static',
    'void',
    'true',
    'false',
    'null',
    'this',
    'super',
    'in',
    'is',
    'as',
    'assert',
    'async',
    'await',
    'yield',
    'get',
    'set',
    'operator',
    'mixin',
    'on',
    'typedef',
    'late',
    'required',
  };
  return reserved.contains(name) ? '${name}_' : name;
}

String generateJs(L10nModel model) {
  final b = StringBuffer();
  b.writeln('// GENERATED - do not edit.');

  // locales array
  b.writeln('export const locales = [${model.locales.map((l) => "'$l'").join(', ')}];');

  final keys = model.entries.keys.toList()..sort();

  // strings object
  b.writeln('const strings = {');
  for (final key in keys) {
    b.writeln("  '$key': {");
    for (final loc in model.locales) {
      final v = escapeJs(model.entries[key]!.valuesByLocale[loc]!);
      b.writeln("    '$loc': '$v',");
    }
    b.writeln('  },');
  }
  b.writeln('};');

  // createT(locale) -> (key, params) => string
  b.writeln('export function createT(locale) {');
  b.writeln('  const loc = (locales.includes(locale) ? locale : "en");');
  b.writeln('  return function t(key, params = {}) {');
  b.writeln(
    '    const s = (strings[key] && strings[key][loc])'
    ' || (strings[key] && strings[key]["en"])'
    ' || key;',
  );
  b.writeln('    return interpolate(s, params);');
  b.writeln('  };');
  b.writeln('}');

  b.writeln('function interpolate(s, params) {');
  b.writeln(
    '  return String(s).replace(/\\{([a-zA-Z_][a-zA-Z0-9_]*)\\}/g, (_, k) => String((params && params[k] != null) ? params[k] : ""));',
  );
  b.writeln('}');
  return b.toString();
}

Future<File> packageFileFromLib(String libPath) async {
  const packageName = 'static_jaspr_l10n';

  final uri = await Isolate.resolvePackageUri(Uri.parse('package:$packageName/$libPath'));

  if (uri == null) {
    throw StateError('Could not resolve package:$packageName/$libPath');
  }

  return File.fromUri(uri);
}

String toSafeDartIdentifier(String key) {
  final cleaned = key.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
  if (RegExp(r'^[0-9]').hasMatch(cleaned)) return 'k_$cleaned';
  return cleaned;
}

String escapeDart(String s) => s.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll('\n', r'\n');

String escapeJs(String s) => s.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll('\n', r'\n');

class L10nModel {
  final List<String> locales;
  final Map<String, L10nEntry> entries;
  L10nModel({required this.locales, required this.entries});
}

class L10nEntry {
  final String key;
  final Map<String, String> valuesByLocale = {};
  final Set<String> placeholders = {};
  L10nEntry(this.key);
}
