import 'dart:convert';

import 'package:crypto/crypto.dart';

const reportSchemaVersion = 2;

String fingerprint(Object value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();

Map<String, dynamic> emptyReport(String status, String code, String message) =>
    {
      'schemaVersion': reportSchemaVersion,
      'status': status,
      'analysisComplete': false,
      'files': <String>[],
      'skippedFiles': <Map<String, String>>[],
      'callables': <Map<String, dynamic>>[],
      'findings': <Map<String, dynamic>>[],
      'errors': [
        {'code': code, 'message': message},
      ],
    };

/// Baselines are full successful reports. Comparing incompatible scopes or
/// policies could turn unexamined findings into apparent resolutions.
void compareBaseline(Map<String, dynamic> report, Object? baseline) {
  if (baseline is! Map<String, dynamic> ||
      baseline['schemaVersion'] != reportSchemaVersion ||
      baseline['status'] != 'completed' ||
      baseline['sdkVersion'] != report['sdkVersion'] ||
      jsonEncode(baseline['scope']) != jsonEncode(report['scope']) ||
      jsonEncode(baseline['configuration']) !=
          jsonEncode(report['configuration']) ||
      baseline['findings'] is! List) {
    throw const FormatException(
      'Baseline schema, scope, or configuration does not match this run.',
    );
  }
  final previous = <String, Map<String, dynamic>>{};
  for (final item in baseline['findings'] as List) {
    if (item is! Map<String, dynamic> ||
        item['fingerprint'] is! String ||
        item['file'] is! String) {
      throw const FormatException('Malformed baseline finding.');
    }
    previous[item['fingerprint'] as String] = item;
  }
  final current = (report['findings'] as List).cast<Map<String, dynamic>>();
  final currentIds = current.map((item) => item['fingerprint']).toSet();
  for (final item in current) {
    item['baselineState'] = previous.containsKey(item['fingerprint'])
        ? 'existing'
        : 'new';
  }
  report['baseline'] = {
    'new': current.where((item) => item['baselineState'] == 'new').length,
    'existing': current
        .where((item) => item['baselineState'] == 'existing')
        .length,
    'resolved': previous.values
        .where((item) => !currentIds.contains(item['fingerprint']))
        .toList(),
  };
}

bool failsPolicy(Map<String, dynamic> report, String policy) {
  if (policy == 'none') return false;
  return (report['findings'] as List).cast<Map<String, dynamic>>().any((
    finding,
  ) {
    if (finding['baselineState'] == 'existing' ||
        finding['intentionalBoundary'] == true) {
      return false;
    }
    return policy == 'all' ||
        (policy == 'unknown'
            ? finding['certainty'] == 'unknown'
            : finding['certainty'] != 'unknown');
  });
}
