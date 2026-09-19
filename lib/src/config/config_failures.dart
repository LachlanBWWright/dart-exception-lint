import '../analysis/throw_summary.dart';

sealed class ManifestFailure {
  const ManifestFailure({required this.message, this.sourcePath});

  final String message;
  final String? sourcePath;
}

final class ManifestFileReadFailure extends ManifestFailure {
  ManifestFileReadFailure({required this.path, required super.message})
    : super(sourcePath: path);

  final String path;
}

final class ManifestYamlParseFailure extends ManifestFailure {
  const ManifestYamlParseFailure({required super.message, super.sourcePath});
}

final class ManifestStructureFailure extends ManifestFailure {
  const ManifestStructureFailure({required super.message, super.sourcePath});
}

final class ManifestWireParseFailure extends ManifestFailure {
  ManifestWireParseFailure({
    required this.key,
    required this.cause,
    this.entrySourcePath,
  }) : super(
         message: 'The "$key" value is unsupported: ${cause.value}.',
         sourcePath: entrySourcePath,
       );

  final String key;
  final WireParseFailure cause;
  final String? entrySourcePath;
}

sealed class ExceptionAnalysisOptionsFailure {
  const ExceptionAnalysisOptionsFailure({
    required this.message,
    this.sourcePath,
  });

  final String message;
  final String? sourcePath;
}

final class ExceptionAnalysisOptionsFileReadFailure
    extends ExceptionAnalysisOptionsFailure {
  ExceptionAnalysisOptionsFileReadFailure({
    required this.path,
    required super.message,
  }) : super(sourcePath: path);

  final String path;
}

final class ExceptionAnalysisOptionsYamlParseFailure
    extends ExceptionAnalysisOptionsFailure {
  const ExceptionAnalysisOptionsYamlParseFailure({
    required super.message,
    super.sourcePath,
  });
}

final class ExceptionAnalysisOptionsWireParseFailure
    extends ExceptionAnalysisOptionsFailure {
  ExceptionAnalysisOptionsWireParseFailure({
    required this.key,
    required this.cause,
    this.optionsSourcePath,
  }) : super(
         message: 'The "$key" value is unsupported: ${cause.value}.',
         sourcePath: optionsSourcePath,
       );

  final String key;
  final WireParseFailure cause;
  final String? optionsSourcePath;
}

final class ExceptionAnalysisOptionsValueFailure
    extends ExceptionAnalysisOptionsFailure {
  const ExceptionAnalysisOptionsValueFailure({
    required this.key,
    required this.expected,
    super.sourcePath,
  }) : super(message: 'The "$key" value must be $expected.');

  final String key;
  final String expected;
}

final class ExceptionAnalysisOptionsUnknownKeyFailure
    extends ExceptionAnalysisOptionsFailure {
  ExceptionAnalysisOptionsUnknownKeyFailure({
    required this.key,
    super.sourcePath,
  }) : super(message: 'Unsupported exception_analysis key "$key".');

  final String key;
}
