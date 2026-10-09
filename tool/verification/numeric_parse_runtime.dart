import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp('numeric-parse-');
  try {
    final file = File('${directory.path}/main.dart');
    await file.writeAsString(_fixture);
    const expected = {
      'int_parse_malformed': 'FormatException',
      'int_try_malformed': 'null',
      'int_parse_radix_low': 'RangeError',
      'int_try_radix_high': 'RangeError',
      'big_parse_malformed': 'FormatException',
      'big_try_radix_low': 'RangeError',
      'double_parse_invalid': 'FormatException',
      'num_parse_hex': 'value:255',
      'dynamic_int_radix': 'TypeError',
    };
    await _verify(
      Platform.resolvedExecutable,
      [file.path],
      'Dart VM',
      expected,
    );
    final output = '${directory.path}/main.js';
    final compile = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'js',
      file.path,
      '-o',
      output,
    ]);
    if (compile.exitCode != 0) {
      throw StateError('JavaScript compilation failed: ${compile.stderr}');
    }
    await _verify(
      'node',
      ['-e', 'globalThis.self = globalThis; require(process.argv[1]);', output],
      'Dart JavaScript (Node)',
      expected,
    );
  } finally {
    await directory.delete(recursive: true);
  }
}

Future<void> _verify(
  String executable,
  List<String> arguments,
  String platform,
  Map<String, String> expected,
) async {
  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    throw StateError('$platform failed: ${result.stderr}');
  }
  final observed = jsonDecode((result.stdout as String).trim());
  if (jsonEncode(observed) != jsonEncode(expected)) {
    throw StateError('$platform observed $observed; expected $expected');
  }
  stdout.writeln('$platform: ${expected.length} parser observations match.');
}

const _fixture = r'''
import 'dart:convert';
String probe(Object? Function() operation) {
  try {
    final value = operation();
    return value == null ? 'null' : 'value:$value';
  } catch (error) {
    if (error is RangeError) return 'RangeError';
    if (error is FormatException) return 'FormatException';
    if (error is TypeError) return 'TypeError';
    return error.runtimeType.toString();
  }
}
void main() {
  final dynamic badRadix = '10';
  print(jsonEncode({
    'int_parse_malformed': probe(() => int.parse('bad')),
    'int_try_malformed': probe(() => int.tryParse('bad')),
    'int_parse_radix_low': probe(() => int.parse('10', radix: 1)),
    'int_try_radix_high': probe(() => int.tryParse('10', radix: 37)),
    'big_parse_malformed': probe(() => BigInt.parse('bad')),
    'big_try_radix_low': probe(() => BigInt.tryParse('10', radix: 1)),
    'double_parse_invalid': probe(() => double.parse('0xFF')),
    'num_parse_hex': probe(() => num.parse('0xFF')),
    'dynamic_int_radix': probe(() => int.parse('10', radix: badRadix)),
  }));
}
''';
