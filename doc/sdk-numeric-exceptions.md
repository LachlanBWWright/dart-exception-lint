# Numeric runtime exceptions in the pinned SDKs

This inventory was checked against local Dart **3.11.0** and **3.13.0** sources,
with independent VM and compiled JavaScript probes. It distinguishes runtime
exceptions from NaN/infinity results and loss of numeric precision. The current
numeric model covers native `int`, `num`, and `double` truncating division,
integer modulo, shifts, compound forms, integer-returning conversions, and
the zero-argument double-returning conversion family. The BigInt extension models
its division/modulo/remainder, shifts, powers, modular arithmetic, bit-width
conversions, radix formatting, numeric construction, and nonthrowing numeric
conversions.
The model also covers primitive remainder, bit widths, modular arithmetic, clamp,
radix conversion, and numeric formatting argument constraints.
The remaining numeric families listed below are still work in the
[production checklist](production-implementation.md).

## Covered families and backend differences

The following observations agree between the two pinned SDK versions. A dash
means that the operation completed without throwing in the probe.

| Operation and condition | VM exception | JavaScript exception or result |
| --- | --- | --- |
| `int ~/ int.zero` | `IntegerDivisionByZeroException` | `UnsupportedError` |
| `int % int.zero` | `IntegerDivisionByZeroException` | NaN, no exception |
| `int ~/ double.zero`, `double ~/ zero` | `UnsupportedError` | `UnsupportedError` |
| `~/` with a NaN or infinite quotient | `UnsupportedError` | `UnsupportedError` |
| `2 ~/ 1e-308`: nonzero divisor, overflowing floating quotient | `UnsupportedError` | `UnsupportedError` |
| `double % zero`, `int % double.zero` | —; NaN result | NaN, no exception |
| `int <<`, `>>`, `>>>` with a negative count | `ArgumentError` | `ArgumentError` |
| `double`/`num` `toInt`, `truncate`, `round`, `floor`, `ceil` on NaN or an infinity | `UnsupportedError` | `UnsupportedError` |
| Those conversions on finite `1e308` | —; bounded integer result | No exception; backend-dependent result |
| `roundToDouble`, `floorToDouble`, `ceilToDouble`, `truncateToDouble` on NaN or infinity | —; NaN/infinity retained | NaN/infinity retained, no exception |
| Numeric `/` by zero | —; NaN/infinity result | NaN/infinity result, no exception |
| Primitive numeric operator with an incompatible dynamic operand | `TypeError` | `TypeError` |
| A modeled zero-argument converter invoked through a dynamic tearoff with extra/named arguments | `NoSuchMethodError` | `NoSuchMethodError` |

For `~/`, proving only that the divisor is nonzero is insufficient when a
floating operand is possible. The intermediate quotient must be finite. For
integer operands, a proven nonzero integer divisor establishes the ordinary
division precondition. Integer arithmetic overflow and rounding differences
must not be mistaken for exceptions.

`IntegerDivisionByZeroException` implements **both** `Exception` and
`UnsupportedError`; through `UnsupportedError`, it is also an `Error`. This
native hierarchy is declared at `lib/core/exceptions.dart:176` in both SDKs.
A catch for `UnsupportedError` contains both observed integer-division failures.
A catch for `Exception` contains the VM's dedicated exception but does not
contain JavaScript's plain `UnsupportedError`. A catch for only
`IntegerDivisionByZeroException` likewise cannot establish portable containment
of integer truncating division.

`toDouble` and the four `*ToDouble` converters accept nonfinite values. This
safe conversion behavior does not remove invocation checks: extra or named
arguments on a dynamically invoked zero-parameter tearoff still fail before the
method body executes.

Compound operators execute the same underlying numeric operation. Their
receiver reads, writes, and implicit type checks remain independently relevant.
Dynamic operands can add `TypeError`; catching only the arithmetic error does
not establish containment of that additional failure.

## Native declarations and proof boundaries

Paths are relative to each pinned SDK root. The listed declaration lines are
identical on Dart 3.11 and 3.13 unless two line numbers are shown.

| API | Source declaration |
| --- | --- |
| `num.%`, `num.~/` | `lib/core/num.dart:152`, `172` |
| `double.%`, `double.~/` | `lib/core/double.dart:39`, `43` |
| `int.<<`, `int.>>`, `int.>>>` | `lib/core/int.dart:159`, `177`, `193` |
| `num.round`, `floor`, `ceil`, `truncate`, `toInt` | `lib/core/num.dart:319`, `331`, `343`, `355`, `421` |
| `double.round`, `floor`, `ceil`, `truncate` | `lib/core/double.dart:70`, `86`, `102`, `119` |
| `num.roundToDouble`, `floorToDouble`, `ceilToDouble`, `truncateToDouble` | `lib/core/num.dart:369`, `378`, `387`, `398` |
| `int.round`, `floor`, `ceil`, `truncate` | 3.11: `lib/core/int.dart:328`, `331`, `334`, `337`; 3.13: `368`, `371`, `374`, `377` |

The model requires native SDK declaration identity. A user class named `num`,
a same-named conversion method, or an overloaded operator is analyzed through
its own implementation and must not be assigned builtin numeric semantics.
Literal and native const values can establish a safe operand. An ordinary local
initializer cannot establish a persistent value after mutation or external
calls. When an alias loses the receiver of a conversion method, the operation
must remain possibly fallible rather than inheriting a stale finite-value proof.

The direct native model matrix is in
[`test/numeric_checks_test.dart`](../test/numeric_checks_test.dart). Effect and
runtime fixtures exercise propagation and catch matching separately. These
checks do not complete generic, mutation, alias, platform, or resource analysis.

## BigInt runtime contracts

The following BigInt declaration lines are identical in both SDKs. Independent
VM and JavaScript probes agree on the exception families, including the dedicated
`IntegerDivisionByZeroException` for BigInt division on JavaScript.

| API and condition | Both runtimes | Native declaration |
| --- | --- | --- |
| `~/`, `%`, `remainder` with zero divisor | `IntegerDivisionByZeroException` | `lib/core/bigint.dart:204`, `223`, `238` |
| `<<`, `>>` with negative count | `ArgumentError` | `lib/core/bigint.dart:250`, `259` |
| `pow` with negative exponent | `ArgumentError`; exponent zero accepted | `lib/core/bigint.dart:384` |
| `modPow` with negative exponent or nonpositive modulus | `ArgumentError` | `lib/core/bigint.dart:390` |
| `modInverse` with nonpositive modulus | `ArgumentError` | `lib/core/bigint.dart:399` |
| `modInverse` when no inverse exists | `Exception`; positive modulus alone cannot prove safety | `lib/core/bigint.dart:399` |
| `from` with NaN/infinity | `ArgumentError`; finite `1e308` accepted | `lib/core/bigint.dart:143` |
| `toUnsigned` with negative width | `ArgumentError`; zero width accepted | `lib/core/bigint.dart:447` |
| `toSigned` with nonpositive width | `ArgumentError` | `lib/core/bigint.dart:481` |
| `toRadixString` with radix outside 2–36 | `RangeError`; radixes 2 and 36 succeed | `lib/core/bigint.dart:567` |
| `toInt`, `toDouble` with huge receiver | No exception; output may lose precision or be infinite | `lib/core/bigint.dart:514`, `527` |

For `(BigInt.one << 10000).toInt()`, the VM returns `9223372036854775807`,
while compiled JavaScript returns infinity. `toDouble()` returns infinity on
both runtimes. These results are not exceptions and must not be assigned a
conversion failure merely because the returned value is nonfinite. They also
show why static `int` typing cannot establish a finite input to `BigInt.from`:
JavaScript `BigInt.from(1 % zero)` throws `ArgumentError` after integer modulo
produces NaN, while the VM throws earlier during modulo. An unknown integer
input must retain the constructor's finiteness check.

BigInt numeric divisors and modular operands require **BigInt**, while shifts,
`pow`, and width conversions require **int**. Incompatible dynamic arguments add
`TypeError` independently of arithmetic failures. Missing, extra, or unexpected
named arguments on dynamically invoked tearoffs cause `NoSuchMethodError`
before the method executes. Native `BigInt.zero`, `one`, and `two` are external
getters (`lib/core/bigint.dart:46`, `49`, `52`), not const variables; their value
proofs require SDK getter identity rather than a matching name or local alias.

The implementations were reviewed in `lib/_internal/vm_shared/lib/bigint_patch.dart`
and `lib/_internal/js_runtime/lib/bigint_patch.dart`, including constructor
finiteness checks, modular preconditions, width checks, and `toInt` conversion.
Parsing is separately deferred: `BigInt.parse` and `tryParse` with radix 1 both
throw `RangeError`; malformed text throws `FormatException` for `parse` but
returns null for `tryParse` (`lib/core/bigint.dart:100`, `133`). Resource exhaustion
from unbounded shifts and powers remains outside these ordinary precondition
proofs; no exhaustion probes were run.

## Primitive numeric methods and formatting

| API and condition | VM | Compiled JavaScript | Native declaration |
| --- | --- | --- | --- |
| Integral `remainder(0)` | `IntegerDivisionByZeroException` | NaN, no exception | `lib/core/num.dart:210` |
| Floating `remainder(0)` | NaN, no exception | NaN, no exception | `lib/core/double.dart:31` |
| `int.toUnsigned` negative width; `toSigned` nonpositive width | `ArgumentError` | `ArgumentError` | 3.11: `lib/core/int.dart:278`, `305`; 3.13: `318`, `345` |
| `int.modPow` negative exponent or nonpositive modulus | `RangeError` | `RangeError` | `lib/core/int.dart:199` |
| `int.modPow` receiver, exponent, or modulus above `2^53 - 1`, with nonzero exponent | Probed values accepted | `RangeError` | Same declaration |
| `int.modInverse` nonpositive modulus / non-coprime operands | `RangeError` / `Exception` | `RangeError` / `Exception` | `lib/core/int.dart:207` |
| `num.clamp` bounds reversed by `compareTo` | `ArgumentError` | `ArgumentError` | `lib/core/num.dart:416` |
| `int.toRadixString` radix outside 2–36 | `RangeError` | `RangeError` | 3.11: `lib/core/int.dart:383`; 3.13: `423` |
| `BigInt.toRadixString` radix outside 2–36 | `RangeError` | `RangeError` | VM shared patch validates with `RangeError.range`; JS patch has the same bounds check |
| `toStringAsFixed`, `toStringAsExponential` digits outside 0–20 | `RangeError` | `RangeError` | `lib/core/num.dart:454`, `476` |
| `toStringAsPrecision` precision outside 1–21 | `RangeError` | `RangeError` | `lib/core/num.dart:498` |

`RangeError` extends `ArgumentError`, which extends `Error`; a catch for
`ArgumentError` contains range failures, while a catch for `Exception` does not.
The non-coprime inverse failure is a plain `Exception`, so catching range errors
alone does not contain it. A positive modulus does not prove that an inverse
exists. Modular pure proofs must respect JavaScript's representable integer
range rather than performing a VM-only greatest-common-divisor calculation on
large literals. For `modPow`, exponent zero returns before the JavaScript size
guards, after exponent/modulus validation; modulus one likewise returns early
for `modInverse`.

Clamp uses `compareTo` ordering: NaN is greatest, and negative zero sorts before
positive zero. Consequently `(NaN, finite)` and `(+0.0, -0.0)` bounds throw, but
`(finite, NaN)`, `(NaN, NaN)`, and `(-0.0, +0.0)` are accepted. Ordinary numeric
`<` comparisons cannot substitute for this ordering in a safe proof.

Formatting checks argument ranges before returning strings for NaN/infinity.
The exponential method accepts an omitted argument or explicit null; other
formatters require their positional argument. Dynamic tearoffs still retain
arity and argument checks independently of range proofs.

A JavaScript value statically typed `int` can hold NaN after integral modulo.
A direct probe using `final int nan = 1 % 0` observed these outcomes in both
pinned JavaScript SDKs:

| Operation supplied with that static-int NaN | Observed outcome |
| --- | --- |
| `int.toUnsigned`, `int.toSigned`, `int.modPow` exponent | No exception |
| `toStringAsFixed`, `toStringAsExponential` | No exception |
| `int.toRadixString`, `toStringAsPrecision` | `ArgumentError` |
| `BigInt.toUnsigned`, `BigInt.toSigned`, BigInt shift count | `UnsupportedError` |
| `BigInt.pow` exponent | No exception |
| `int.modInverse` modulus | Public `Exception` |

`BigInt.modPow` takes BigInt arguments, so this integer-artifact probe does not
apply to its exponent or modulus. The VM throws during the initial modulo and
cannot execute the subsequent calls with that artifact.

The earlier method audit used a mutable captured integer, initialized to zero
and assigned `1 % zero` inside a try statement. Its closure calls reported
`TypeError` for `modPow`, `modInverse`, and fixed formatting. Those observations
must not be generalized to every statically typed integer: the direct-final
probe above demonstrates different compiler lowering. Incompatible dynamic or
non-integer arguments retain their runtime checks separately. Neither a static
integer subtype nor a single probe shape proves all JavaScript numeric values
finite; the specific argument and implementation checks require modeling.

Implementation evidence is in `lib/_internal/vm/lib/integers.dart`,
`lib/_internal/vm/lib/double.dart`, and
`lib/_internal/js_runtime/lib/js_number.dart` in each SDK. These sources expose
the modular precision guards, plain inverse exception, signed-width shifts,
clamp ordering, and formatting checks. No resource-exhaustion probes were used.

## Numeric parsing

| API | Input/radix condition | Exception effect |
| --- | --- | --- |
| `int.parse`, `BigInt.parse` | Malformed text | `FormatException` |
| `int.parse`, `BigInt.parse`, and both `tryParse` variants | Radix outside 2–36 | `RangeError`, including from `tryParse` |
| `double.parse`, `num.parse` | Malformed text | `FormatException` |
| `double.tryParse`, `num.tryParse`, and integer `tryParse` with valid radix | Malformed text | Returns `null` |
| Numeric parser called with incompatible dynamic text/radix | Runtime argument type mismatch | `TypeError` |

The catalog includes these SDK-identity checked effects. Constant valid source
strings and valid radixes suppress parse/range effects; unknown text retains
`FormatException` only for throwing `parse` methods, while unknown integer
radixes retain `RangeError` for both `parse` and `tryParse`. On the VM,
`int.parse` can also throw `FormatException` for values outside the native
integer range; JavaScript may return a rounded integer instead. `BigInt` has no
corresponding fixed-width overflow.

## Additional numeric families audited

These additional observations were checked on both pinned SDKs and both
runtimes. They are inventory evidence, not a claim that the current numeric
model covers them.

| Family | Observed failure or behavior | Native declarations |
| --- | --- | --- |
| `Random.secure()` when the platform has no cryptographically secure source | `UnsupportedError`; supported host used in the differential fixture succeeds | `lib/math/random.dart:41–45` |
| `Random.nextInt` | `max <= 0` or `max > 2^32`: `RangeError` | `lib/math/random.dart:56` |
| `sqrt`, `log`, `asin`, floating `pow` | The probed invalid domains yield NaN/infinity rather than throwing; later integer conversion can still fail | `lib/math/math.dart` |

Further work includes modular arithmetic constraints beyond the sampled
boundaries, numeric methods invoked through
aliases, generic numeric bounds, platform-specific implementations, and effects
from dynamic dispatch or implicit casts. Arbitrarily large BigInt operations
also require a defined policy for resource failures and analysis budgets.
No unsafe exhaustion or out-of-memory probes were run. Other native/platform
failure families remain separate boundary work.

`Random.nextInt` is an abstract interface method and can be overridden by user
implementations. Its `RangeError` model is applied only when the receiver is a
direct SDK `Random()` or `Random.secure()` factory result; other abstract or
custom dispatch remains under the unresolved-call analysis. Both pinned SDKs'
VM and JavaScript implementations accept `1..2^32` and reject values outside
that range. The direct `Random.secure()` factory call retains a possible
`UnsupportedError` from platforms without a cryptographically secure source;
supported VM and Node fixtures return normally.

## Local verification evidence

Independent audit probes exercised 100 cases per runtime on each SDK:
400 observations across the VM and JavaScript. A separate 39-case BigInt
audit ran on each SDK/backend combination, adding 156 observations. Another
39-case primitive-method audit added 156 observations across those combinations. Exception families were identical
between Dart 3.11 and 3.13 for those cases; the VM/JavaScript differences above
were retained. This sample is not an exhaustive runtime-exception proof.

The workspace logs are `.dart_tool/numeric-audit-vm.jsonl`,
`numeric-audit-js.jsonl`, `numeric-extra-audit-vm.jsonl`, and
`numeric-extra-audit-js.jsonl`, and `bigint-audit-vm.jsonl` /
`bigint-audit-js.jsonl`, plus `numeric-method-audit-vm.jsonl` /
`numeric-method-audit-js.jsonl`, with corresponding `minimum-` logs. Sources were
read from `/home/lachl/sdks/flutter/bin/cache/dart-sdk` and
`.dart_tool/minimum-sdk/dart-sdk`. Supported SDK changes require another source
and runtime review.
