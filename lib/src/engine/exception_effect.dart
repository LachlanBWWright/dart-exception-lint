import '../analysis/throw_summary.dart';

/// Failure delivery and certainty are independent dimensions. An unknown
/// source is retained alongside known failures instead of replacing them.
enum ExceptionChannel { synchronous, future, stream, deferred, scheduled }

enum ExceptionCertainty { definite, possible, unknown }

final class ExceptionEffect {
  const ExceptionEffect({
    required this.channel,
    required this.certainty,
    required this.source,
  });

  final ExceptionChannel channel;
  final ExceptionCertainty certainty;
  final ThrowSource source;

  factory ExceptionEffect.fromSource(ThrowSource source) => ExceptionEffect(
    channel:
        source.channel ??
        switch (source.effectiveTiming) {
          ThrowTiming.synchronous => ExceptionChannel.synchronous,
          ThrowTiming.asynchronous => ExceptionChannel.future,
          ThrowTiming.deferred => ExceptionChannel.deferred,
        },
    certainty:
        source.certainty ??
        switch (source.confidence) {
          ThrowConfidence.definiteThrow => ExceptionCertainty.definite,
          ThrowConfidence.unknown => ExceptionCertainty.unknown,
          _ => ExceptionCertainty.possible,
        },
    source: source,
  );
}
