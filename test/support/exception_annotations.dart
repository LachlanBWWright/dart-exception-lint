import 'dart:io';

import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';

void installExceptionAnnotations(AnalysisRuleTest test) {
  test
      .newPackage('dart_exception_lint')
      .addFile(
        'lib/dart_exception_lint.dart',
        File('lib/dart_exception_lint.dart').readAsStringSync(),
      );
  test.writeTestPackageConfig2();
}
