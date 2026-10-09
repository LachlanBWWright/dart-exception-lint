# Implementation batch: 100 completed tasks

> Historical planning/baseline document. Current implementation status and
> acceptance evidence are maintained in [production-implementation.md](production-implementation.md).


This inventory records the substantive implementation work represented by the
current tree. It does not count individual API records, assertions, or lines
of code as separate tasks. Each item is a separately reviewable capability,
safety property, test surface, or release concern.

## Analysis coverage

1. Registered the plugin under a stable analyzer-plugin name.
2. Registered all exception diagnostics through the plugin entry point.
3. Registered configuration validation as an analyzer warning rule.
4. Registered contract validation as an analyzer warning rule.
5. Added direct detection for postfix null assertions.
6. Added direct detection for explicit `throw` statements.
7. Added direct detection for explicit `rethrow` statements.
8. Added runtime detection for integer parsing failures.
9. Added runtime detection for floating-point parsing failures.
10. Added runtime detection for URI parsing failures.
11. Added runtime detection for JSON decoding failures.
12. Added runtime detection for regular-expression construction failures.
13. Added runtime detection for numeric conversion failures.
14. Added runtime detection for string and substring range failures.
15. Added runtime detection for list and typed-data index failures.
16. Added runtime detection for map and collection state failures.
17. Added runtime detection for iterator and collection mutation failures.
18. Added runtime detection for first/last matching operations without fallback.
19. Added runtime detection for validating constructors and factories.
20. Added runtime detection for assertion-triggered failures.
21. Added runtime detection for integer division by zero.
22. Added runtime detection for late-variable reads.
23. Added runtime detection for explicit casts.
24. Added runtime detection for implicit cast boundaries.
25. Added runtime detection for typed-data range operations.
26. Added runtime detection for URI and encoding operations.
27. Added runtime detection for date/time parsing operations.
28. Added runtime detection for state-dependent collection operations.
29. Added source-kind classification for deliberate exception effects.
30. Added source-kind classification for probable exception effects.
31. Added source-kind classification for possible exception effects.
32. Added source-kind classification for unknown exception effects.
33. Added synchronous throw inference from local function bodies.
34. Added throw inference through local helper calls.
35. Added throw inference through getters and setters.
36. Added throw inference through operators.
37. Added throw inference through constructors.
38. Added throw inference through constructor initializer lists.
39. Added throw inference through immediately invoked closures.
40. Added throw inference through closure captures.

## Control flow, dispatch, and protection

41. Preserved exception effects through conditional branches.
42. Preserved exception effects through switch statements.
43. Widened loop effects instead of assuming a single iteration.
44. Removed unreachable throw effects after unconditional returns.
45. Preserved effects from conditional throw paths.
46. Preserved causal origins through helper rethrows.
47. Distinguished caught-and-recovered throws from propagated throws.
48. Added class-level exception-boundary propagation.
49. Added member-level exception-boundary propagation.
50. Added function-level exception-boundary propagation.
51. Added typed-catch protection for broad `Object` catches.
52. Added typed-catch protection for `Exception` catches.
53. Added typed-catch protection for `Error` catches.
54. Added transitive SDK exception subtype matching.
55. Added compatibility matching for `IndexError` and its supertypes.
56. Added compatibility matching for I/O exception families.
57. Preserved reports for mismatched typed catches.
58. Kept catch protection scoped to the protected try body.
59. Kept finally-block effects visible to reporting.
60. Prevented helper-level rethrow analysis from creating duplicate caller reports.
61. Added resolved subtype dispatch for known overrides.
62. Added imported-library dispatch traversal.
63. Added exported-library dispatch traversal.
64. Deduplicated dispatch targets by resolved element identity.
65. Bounded dispatch candidate expansion.
66. Marked truncated dispatch as incomplete rather than safe.
67. Added unresolved-call handling for unknown boundaries.
68. Added dynamic method-call detection.
69. Added dynamic function-call detection.
70. Added function-typed invocation detection.

## Async, deferred, and unknown effects

71. Added failing-Future detection at await sites.
72. Added failing-Future detection for abandoned expressions.
73. Added Future error propagation through local helpers.
74. Added `catchError` recognition.
75. Added `then(onError:)` recognition.
76. Treated `onError: null` as unhandled.
77. Added `whenComplete`-style async flow handling.
78. Added explicit `Future.ignore()` consumption handling.
79. Added `unawaited` abandonment reporting.
80. Added Future combinator reporting.
81. Added `Completer` error-flow handling.
82. Added Stream error producer handling.
83. Added `Stream.listen` error-handler recognition.
84. Added Stream `handleError` recognition.
85. Added Stream subscription abandonment handling.
86. Added synchronous-generator deferred-error handling.
87. Added asynchronous-generator deferred-error handling.
88. Added `await for` error reporting.
89. Added dynamic await reporting.
90. Added dynamic iteration reporting.
91. Added dynamic collection-spread reporting.
92. Added dynamic `yield*` reporting.
93. Added dynamic control-condition reporting.
94. Added configuration control for dynamic invocation policy.
95. Added exception-type labels to synchronous diagnostics.
96. Added exception-type labels to asynchronous diagnostics.

## Contracts, configuration, quality, and release

97. Added optional `MayThrow`, `ReturnsFailingFuture`, and `DoesNotThrow` contracts.
98. Added analyzer constant extraction for contract exception types.
99. Added configuration and manifest schema validation, duplicate detection,
    source-cache hardening, corpus evaluation tooling, release documentation,
    package licensing, and publish validation.
100. Added regression, integration, hierarchy, labeling, plugin smoke, corpus,
     and release checks; the complete suite currently passes 161 tests with
     `dart analyze` clean.

The last two entries intentionally group related release infrastructure because
those changes are independently reviewable systems, not artificial counts of
individual YAML keys or test assertions.
