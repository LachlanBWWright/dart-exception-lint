# Explicit SDK error producers

This inventory records public SDK operations that explicitly deliver a supplied
error value, for the `no_manual_throw` rule. It was checked against the local
Dart **3.11.0** and **3.13.0** SDK sources. It does not inventory every operation
that can fail at runtime; that larger task remains in the
[production implementation checklist](production-implementation.md).

`throw` and `rethrow` remain prohibited independently of this SDK inventory.
Calling a producer remains a policy violation inside a catch or an exception
boundary, and when the supplied error came from an existing error handler.
Forwarding an error with `completeError`, `addError`, or `handleUncaughtError`
still explicitly delivers an exception. Merely constructing an error object is
allowed.

## Reviewed declarations

Paths below are relative to each pinned SDK directory. Line numbers identify
native declarations, not documentation examples or private calls within SDK
implementations.

| Native API | Error delivery purpose | SDK source | 3.11 line | 3.13 line |
| --- | --- | --- | ---: | ---: |
| `Error.throwWithStackTrace` | Throw the supplied error with a supplied stack trace | `lib/core/errors.dart` | 117 | 117 |
| `Future.error` | Construct a Future that completes with the supplied error | `lib/async/future.dart` | 392 | 392 |
| `Stream.error` | Construct a Stream containing the supplied error event | `lib/async/stream.dart` | 212 | 212 |
| `Completer.completeError` | Complete the completer's Future with the supplied error | `lib/async/future.dart` | 1335 | 1356 |
| `EventSink.addError` | Send the supplied error event to a sink | `lib/async/stream.dart` | 2298 | 2298 |
| `StreamController.addError` | Enqueue or deliver the supplied error event | `lib/async/stream_controller.dart` | 252 | 252 |
| `SynchronousStreamController.addError` | Deliver the supplied error event through a synchronous controller | `lib/async/stream_controller.dart` | 396 | 396 |
| `MultiStreamController.addErrorSync` | Attempt immediate delivery of the supplied error event | `lib/async/stream.dart` | 2801 | 2801 |
| `Zone.handleUncaughtError` | Report the supplied uncaught error to the zone's handler | `lib/async/zone.dart` | 103 | 187 |
| `ZoneDelegate.handleUncaughtError` | Forward the supplied uncaught error to a delegated zone handler | `lib/async/zone_delegate.dart` | 29 | 29 |
| `IOSink.addError` | Pass the supplied error to the target consumer | `lib/io/io_sink.dart` | 99 | 99 |
| `Socket.addError` | Unsupported inherited error-delivery operation | `lib/io/socket.dart` | 972 | 993 |
| `Stdout.addError` | Forward the supplied error through the output sink | `lib/io/stdio.dart` | 469 | 471 |

`StreamSink.addError` is inherited from `EventSink`; `MultiStreamController`
inherits ordinary `addError` through `StreamController`. In native resolution,
`Stdout.addError` resolves to the private SDK `_StdSink` implementation. A
classifier must recognize that SDK implementation's sink contract rather than
requiring the enclosing declaration to have the public receiver's name.

This policy classifier establishes operation identity only. It does not attach
an exception channel or prove the complete runtime delivery behavior. For example,
controller state checks can throw synchronously, synchronous delivery has
additional preconditions, and I/O sinks can surface errors through their `done`
Future. The SDK documents `Socket.addError` as unsupported; the stdout contract
warns of an unhandled asynchronous error when `done` has no error handler.
Those cases still invoke an explicit error API and remain prohibited by this
rule.

## Operations outside this producer classification

| Operation | Classification |
| --- | --- |
| `Error`, `Exception`, `ArgumentError`, and other error constructors | Construct an ordinary value; construction alone does not throw or deliver that value |
| `AsyncError` | Store an error and stack trace as a value (`lib/async/async_error.dart:16` on both SDKs) |
| `Zone.errorCallback`, `ZoneDelegate.errorCallback` | Intercept or replace an existing error value; do not themselves deliver it |
| `Future.then`, `catchError`, `onError`, `whenComplete` | Register transformations or handlers; callback bodies and existing error effects require separate analysis |
| `Future.value`, `Completer.complete` | May adopt an existing Future's failure; not an explicit supplied-error operation |
| `Stream.fromFuture`, `fromFutures`, sink `addStream` | Forward source effects; require ordinary effect and ownership analysis |
| `StreamTransformer.fromHandlers`, `Stream.multi`, `ZoneSpecification` | Register callbacks; explicit producer calls inside callbacks are still prohibited |
| `ArgumentError.checkNotNull` | Conditional validation helper (`lib/core/errors.dart:220` on both SDKs) |
| `RangeError.checkValueInInterval`, `checkValidIndex`, `checkValidRange`, `checkNotNegative` | Conditional validation helpers (`lib/core/errors.dart:316`, `344`, `375`, `408` on both SDKs) |
| `IndexError.check` | Conditional validation helper (`lib/core/errors.dart:510` on both SDKs) |
| `Isolate.addErrorListener` | Register a receiver for existing isolate errors; not explicit error creation |
| `Isolate.exit`, process `exit` | Terminate execution; a `Never` return type alone does not establish an exception producer |

Conditional validators and normal fallible operations still belong in the
runtime exception analysis. Excluding them from the explicit producer rule is
not a claim that they cannot throw.

## Native identity and callable forms

Producer identity uses the native SDK library, enclosing declaration, and
member, after normalizing to `baseElement`. A same-named user declaration,
including a user implementation of a sink interface, does not establish SDK
producer identity.

The policy must follow proven callable values, including generic constructor
references, immutable aliases, conditional joins, supported record/constant
collection extraction, returned SDK references, explicit function `.call`, and
native `Function.apply` forwarding. The `Function.apply` check must identify
`dart:core`'s actual static `Function.apply` declaration and inspect the function
argument it invokes; a same-named user operation is not sufficient. Creating a
tearoff alone is not invoking a producer.

Nested native `Function.apply` forwarding can follow fresh or parenthesized
literal argument lists. This producer projection is bounded to 16 forwarding
levels, 256 traversal steps and 64 targets. Stored or opaque argument lists,
collection control elements and exhausted budgets retain uncertainty; the
projection does not model general `Function.apply` exception effects.

The native classifier matrix in
[`test/explicit_error_producers_test.dart`](../test/explicit_error_producers_test.dart)
checks SDK calls, inherited members, constructor references, ordinary error
values, validation/interception helpers, and user lookalikes. Rule and runtime
fixtures verify invocation paths separately. Mutable aliases, heap storage,
opaque callbacks, and other unresolved values must remain uncertainty in the
effect rules; they must not become stale proofs of safety or definite SDK
producer identity. Those remaining value-flow obligations keep checklist item
24 open.

## Local evidence

The reviewed SDK roots in this workspace are
`/home/lachl/sdks/flutter/bin/cache/dart-sdk` (3.13.0) and
`.dart_tool/minimum-sdk/dart-sdk` (3.11.0). Source locations and SDK versions were
read locally, without relying on current online documentation. The inventory
needs another SDK-source review when either supported SDK range or producer
policy changes.
