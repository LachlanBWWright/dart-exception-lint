/// Public annotations understood by `dart_exception_lint`.
library;

/// Marks a callable as an intentional exception-propagation boundary.
///
/// The linter does not require effects reaching this callable to be caught
/// locally. Direct syntax rules such as `no_manual_throw` still apply.
class ExceptionBoundary {
  const ExceptionBoundary();
}

/// Declares synchronous exception behavior for an API whose implementation
/// is unavailable to the analyzer.
class MayThrow {
  const MayThrow(this.exceptionTypes);

  final List<Type> exceptionTypes;
}

/// Declares that an API surfaces failure through its returned Future or Stream.
class ReturnsFailingFuture {
  const ReturnsFailingFuture(this.exceptionTypes);

  final List<Type> exceptionTypes;
}

/// Declares that the API is intended not to expose an exception effect.
class DoesNotThrow {
  const DoesNotThrow();
}
