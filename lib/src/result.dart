sealed class Result<T, E> {
  const Result();

  bool get isOk => this is Ok<T, E>;
  bool get isErr => this is Err<T, E>;

  T? get valueOrNull => switch (this) {
    Ok<T, E>(:final value) => value,
    _ => null,
  };

  E? get errorOrNull => switch (this) {
    Err<T, E>(:final error) => error,
    _ => null,
  };

  R match<R>({
    required R Function(T value) ok,
    required R Function(E error) err,
  });

  Result<R, E> map<R>(R Function(T value) transform) {
    return match(
      ok: (value) => Ok(transform(value)),
      err: (error) => Err(error),
    );
  }

  Result<R, E> flatMap<R>(Result<R, E> Function(T value) transform) {
    return match(ok: transform, err: (error) => Err(error));
  }

  T unwrapOr(T fallback) {
    return match(ok: (value) => value, err: (_) => fallback);
  }
}

final class Ok<T, E> extends Result<T, E> {
  const Ok(this.value);

  final T value;

  @override
  R match<R>({
    required R Function(T value) ok,
    required R Function(E error) err,
  }) {
    return ok(value);
  }
}

final class Err<T, E> extends Result<T, E> {
  const Err(this.error);

  final E error;

  @override
  R match<R>({
    required R Function(T value) ok,
    required R Function(E error) err,
  }) {
    return err(error);
  }
}
