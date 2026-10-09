import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

/// A bounded set of possible callable values, retaining unresolved alternatives.
final class CallbackValue {
  CallbackValue({
    Iterable<ExecutableElement> targets = const [],
    this.hasUnknown = false,
  }) : targets = Set.unmodifiable(targets.map((target) => target.baseElement));

  factory CallbackValue.unknown() => CallbackValue(hasUnknown: true);

  final Set<ExecutableElement> targets;
  final bool hasUnknown;

  @override
  bool operator ==(Object other) =>
      other is CallbackValue &&
      hasUnknown == other.hasUnknown &&
      targets.length == other.targets.length &&
      targets.containsAll(other.targets);

  @override
  int get hashCode => Object.hash(hasUnknown, Object.hashAllUnordered(targets));
}

/// Resolves native callback values without assuming that storage is immutable.
///
/// Local initializer aliases are usable only if their resolved unit contains no
/// writes to that variable, including writes inside nested closures. Unsupported
/// values and exhausted budgets keep an unknown alternative.
/// Stored list/map selection requires const literal identity; record selection
/// uses immutable fields. Factory return resolution excludes local functions
/// whose captured invocation environments are not represented by this model.
final class CallbackValueResolver {
  CallbackValueResolver({
    required Map<String, CompilationUnit> resolvedUnits,
    Map<FormalParameterElement, CallbackValue> parameterBindings = const {},
    this.returnedExpressions,
    this.maxAliasDepth = 64,
    this.maxTargets = 64,
    this.maxResolutionSteps = 4096,
  }) : _resolvedUnits = resolvedUnits,
       _bindings = {
         for (final entry in parameterBindings.entries)
           entry.key.baseElement: entry.value,
       } {
    _refreshUnits();
  }

  void _refreshUnits() {
    for (final unit in _resolvedUnits.values) {
      // Parsed-only ASTs cannot establish native element identity or writes.
      if (unit.declaredFragment == null || !_indexedUnits.add(unit)) continue;
      unit.accept(_ValueIndex(_initializers, _written));
    }
  }

  final int maxAliasDepth;
  final int maxTargets;
  final int maxResolutionSteps;

  /// Native own-return expressions for synchronous non-generator factories.
  /// `null` indicates unavailable or incomplete factory return analysis.
  final Iterable<Expression>? Function(ExecutableElement)? returnedExpressions;
  int _remainingSteps = 0;
  final Map<String, CompilationUnit> _resolvedUnits;
  final Set<CompilationUnit> _indexedUnits = Set.identity();
  final Map<FormalParameterElement, CallbackValue> _bindings;
  final Map<LocalVariableElement, Expression?> _initializers = {};
  final Set<Element> _written = {};

  CallbackValue resolve(Expression expression) {
    _refreshUnits();
    _remainingSteps = maxResolutionSteps;
    return _resolve(expression, {}, 0);
  }

  CallbackValue forElement(Element? element) {
    _refreshUnits();
    _remainingSteps = maxResolutionSteps;
    return _element(element, {}, 0);
  }

  /// Resolves the value actually invoked, including record fields and `.call`.
  CallbackValue resolveInvocation(AstNode node) {
    _refreshUnits();
    _remainingSteps = maxResolutionSteps;
    return _invocationTargets(node, {}, 0);
  }

  CallbackValue _invocationTargets(
    AstNode node,
    Set<Element> active,
    int depth,
  ) => switch (node) {
    MethodInvocation(realTarget: final target)
        when target != null &&
            node.methodName.name == 'call' &&
            target.staticType is! RecordType &&
            (node.methodName.element == null ||
                target.staticType is FunctionType ||
                _isNativeFunctionCall(node.methodName.element)) =>
      _resolve(target, active, depth + 1),
    MethodInvocation(realTarget: final target) when target != null => _property(
      target,
      node.methodName.name,
      node.methodName.element,
      active,
      depth + 1,
    ),
    MethodInvocation() => _element(node.methodName.element, active, depth + 1),
    FunctionExpressionInvocation() => _resolve(
      node.function,
      active,
      depth + 1,
    ),
    InstanceCreationExpression() => _element(
      node.constructorName.element,
      active,
      depth + 1,
    ),
    _ => CallbackValue.unknown(),
  };

  CallbackValue _bounded(CallbackValue value) {
    if (value.targets.length <= maxTargets) return value;
    return CallbackValue(
      targets: value.targets.take(maxTargets < 0 ? 0 : maxTargets),
      hasUnknown: true,
    );
  }

  CallbackValue _join(Iterable<CallbackValue> values) {
    final targets = <ExecutableElement>{};
    var unknown = false;
    var nonempty = false;
    for (final value in values) {
      nonempty = true;
      unknown |= value.hasUnknown;
      for (final target in value.targets) {
        if (targets.length < maxTargets || targets.contains(target)) {
          targets.add(target);
        } else {
          unknown = true;
        }
      }
    }
    return CallbackValue(targets: targets, hasUnknown: unknown || !nonempty);
  }

  CallbackValue _resolve(
    Expression expression,
    Set<Element> active,
    int depth,
  ) {
    if (depth > maxAliasDepth || _remainingSteps-- <= 0) {
      return CallbackValue.unknown();
    }
    final value = expression.argumentExpression;
    return switch (value) {
      ParenthesizedExpression() => _resolve(
        value.expression,
        active,
        depth + 1,
      ),
      FunctionExpression() => _element(
        value.declaredFragment?.element,
        active,
        depth,
      ),
      SimpleIdentifier() => _element(value.element, active, depth),
      PrefixedIdentifier() => _property(
        value.prefix,
        value.identifier.name,
        value.identifier.element,
        active,
        depth,
      ),
      PropertyAccess() => _property(
        value.realTarget,
        value.propertyName.name,
        value.propertyName.element,
        active,
        depth,
      ),
      IndexExpression() => _indexed(value, active, depth),
      PostfixExpression() when value.operator.lexeme == '!' => _resolve(
        value.operand,
        active,
        depth + 1,
      ),
      ConstructorReference() => _element(
        value.constructorName.element,
        active,
        depth,
      ),
      FunctionReference() => _resolve(value.function, active, depth + 1),
      MethodInvocation() || FunctionExpressionInvocation() => _returned(
        _invocationTargets(value, active, depth + 1),
        active,
        depth,
      ),
      ConditionalExpression() => _join([
        _resolve(value.thenExpression, active, depth + 1),
        _resolve(value.elseExpression, active, depth + 1),
      ]),
      SwitchExpression() => _join(
        value.cases.map(
          (branch) => _resolve(branch.expression, active, depth + 1),
        ),
      ),
      _ => CallbackValue.unknown(),
    };
  }

  CallbackValue _returned(
    CallbackValue factories,
    Set<Element> active,
    int depth,
  ) {
    final values = <CallbackValue>[];
    if (factories.hasUnknown) values.add(CallbackValue.unknown());
    for (final factory in factories.targets) {
      if (depth > maxAliasDepth ||
          _remainingSteps-- <= 0 ||
          !(factory is TopLevelFunctionElement ||
              factory is MethodElement && factory.isStatic) ||
          !active.add(factory.baseElement)) {
        values.add(CallbackValue.unknown());
        continue;
      }
      final expressions = returnedExpressions?.call(factory);
      // The collector can synchronously resolve a dependency library.
      _refreshUnits();
      final returned = expressions == null
          ? CallbackValue.unknown()
          : _join(
              expressions.map(
                (expression) => _resolve(expression, active, depth + 1),
              ),
            );
      active.remove(factory.baseElement);
      // Nested functions retain their factory invocation's capture environment.
      // A bare executable identity cannot describe that environment yet.
      values.add(
        CallbackValue(
          targets: returned.targets.where(
            (target) => !_capturesEnvironment(target),
          ),
          hasUnknown:
              returned.hasUnknown || returned.targets.any(_capturesEnvironment),
        ),
      );
    }
    return _join(values);
  }

  static bool _capturesEnvironment(ExecutableElement target) =>
      target is LocalFunctionElement ||
      target.enclosingElement is ExecutableElement;

  CallbackValue _property(
    Expression receiver,
    String name,
    Element? element,
    Set<Element> active,
    int depth,
  ) {
    final nativeFunctionCall = _isNativeFunctionCall(element);
    if (name == 'call' &&
        (receiver.staticType is FunctionType ||
            element == null ||
            nativeFunctionCall)) {
      final value = _resolve(receiver, active, depth + 1);
      if (value.targets.isNotEmpty ||
          receiver.staticType is FunctionType ||
          nativeFunctionCall) {
        return value;
      }
    }
    if (receiver.staticType is! RecordType) {
      return _element(element, active, depth);
    }
    final aggregate = _aggregate(receiver, active, depth + 1, stored: false);
    if (aggregate is! RecordLiteral) return CallbackValue.unknown();
    var position = 0;
    for (final field in aggregate.fields) {
      if (_remainingSteps-- <= 0) return CallbackValue.unknown();
      if (field is RecordLiteralNamedField) {
        if (field.name.lexeme == name) {
          return _resolve(field.fieldExpression, active, depth + 1);
        }
      } else {
        position++;
        if (name == '\$$position') {
          return _resolve(field.fieldExpression, active, depth + 1);
        }
      }
    }
    return CallbackValue.unknown();
  }

  static bool _isNativeFunctionCall(Element? element) =>
      element is MethodElement &&
      element.library.isInSdk &&
      element.library.uri.toString() == 'dart:core' &&
      element.enclosingElement?.name == 'Function' &&
      element.name == 'call';

  CallbackValue _indexed(
    IndexExpression expression,
    Set<Element> active,
    int depth,
  ) {
    final method = expression.element;
    if (expression.isCascaded ||
        expression.isNullAware ||
        method?.library.uri.toString() != 'dart:core' ||
        method?.name != '[]') {
      return CallbackValue.unknown();
    }
    final aggregate = _aggregate(
      expression.realTarget,
      active,
      depth + 1,
      stored: false,
    );
    final key = _constantKey(expression.index, active, depth + 1);
    if (identical(key, _unsupportedKey)) return CallbackValue.unknown();
    if (aggregate is ListLiteral && key is int) {
      if (key < 0 || key >= aggregate.elements.length) {
        return CallbackValue.unknown();
      }
      for (final element in aggregate.elements) {
        if (_remainingSteps-- <= 0 || element is! Expression) {
          return CallbackValue.unknown();
        }
      }
      return _resolve(aggregate.elements[key] as Expression, active, depth + 1);
    }
    if (aggregate is SetOrMapLiteral && aggregate.isMap) {
      Expression? selected;
      for (final entry in aggregate.elements) {
        if (_remainingSteps-- <= 0 ||
            entry is! MapLiteralEntry ||
            entry.keyQuestion != null ||
            entry.valueQuestion != null) {
          return CallbackValue.unknown();
        }
        final candidate = _constantKey(entry.key, active, depth + 1);
        if (identical(candidate, _unsupportedKey)) {
          return CallbackValue.unknown();
        }
        if (candidate == key) selected = entry.value;
      }
      if (selected != null) return _resolve(selected, active, depth + 1);
    }
    return CallbackValue.unknown();
  }

  // Collections reached through local storage require const identity. A final
  // list/map remains mutable through aliases and escaped references. A fresh
  // literal indexed immediately has no intervening mutation; records are
  // immutable regardless of whether their fields were created in const context.
  Expression? _aggregate(
    Expression expression,
    Set<Element> active,
    int depth, {
    required bool stored,
  }) {
    if (depth > maxAliasDepth ||
        _remainingSteps-- <= 0 ||
        expression.staticType == null) {
      return null;
    }
    if (expression is ParenthesizedExpression) {
      return _aggregate(
        expression.expression,
        active,
        depth + 1,
        stored: stored,
      );
    }
    if (expression is RecordLiteral ||
        expression is ListLiteral && (!stored || expression.isConst) ||
        expression is SetOrMapLiteral && (!stored || expression.isConst)) {
      return expression;
    }
    if (expression is SimpleIdentifier) {
      final element = expression.element?.baseElement;
      if (element is LocalVariableElement &&
          !_written.contains(element) &&
          active.add(element)) {
        final initializer = _initializers[element];
        final result = initializer == null
            ? null
            : _aggregate(initializer, active, depth + 1, stored: true);
        active.remove(element);
        return result;
      }
    }
    return null;
  }

  static const _unsupportedKey = Object();

  Object? _constantKey(Expression expression, Set<Element> active, int depth) {
    if (depth > maxAliasDepth || _remainingSteps-- <= 0) return _unsupportedKey;
    return switch (expression) {
      IntegerLiteral() => expression.value,
      DoubleLiteral() => expression.value,
      BooleanLiteral() => expression.value,
      NullLiteral() => null,
      StringLiteral() => expression.stringValue ?? _unsupportedKey,
      ParenthesizedExpression() => _constantKey(
        expression.expression,
        active,
        depth + 1,
      ),
      SimpleIdentifier() => _constantLocalKey(
        expression.element,
        active,
        depth,
      ),
      _ => _unsupportedKey,
    };
  }

  Object? _constantLocalKey(Element? element, Set<Element> active, int depth) {
    final base = element?.baseElement;
    if (base is! LocalVariableElement ||
        !base.isConst ||
        _written.contains(base) ||
        !active.add(base)) {
      return _unsupportedKey;
    }
    final initializer = _initializers[base];
    final result = initializer == null
        ? _unsupportedKey
        : _constantKey(initializer, active, depth + 1);
    active.remove(base);
    return result;
  }

  CallbackValue _element(Element? element, Set<Element> active, int depth) {
    if (depth > maxAliasDepth || element == null || _remainingSteps-- <= 0) {
      return CallbackValue.unknown();
    }
    final base = element.baseElement;
    if (base is FormalParameterElement) {
      final enclosing = base.enclosingElement;
      if (enclosing is ExecutableElement &&
          active.contains(enclosing.baseElement)) {
        return CallbackValue.unknown();
      }
      if (_written.contains(base)) return CallbackValue.unknown();
      return _bounded(_bindings[base] ?? CallbackValue.unknown());
    }
    // A getter executes to obtain a value; it is not itself the callback value.
    if (base is ExecutableElement && base is! PropertyAccessorElement) {
      return _bounded(CallbackValue(targets: [base]));
    }
    if (base is LocalVariableElement && !_written.contains(base)) {
      final initializer = _initializers[base];
      if (initializer != null && active.add(base)) {
        final value = _resolve(initializer, active, depth + 1);
        active.remove(base);
        return value;
      }
    }
    return CallbackValue.unknown();
  }
}

final class _ValueIndex extends RecursiveAstVisitor<void> {
  _ValueIndex(this.initializers, this.written);

  final Map<LocalVariableElement, Expression?> initializers;
  final Set<Element> written;

  void _write(Expression target) {
    if (target is ParenthesizedExpression) {
      _write(target.expression);
    } else if (target is SimpleIdentifier && target.element != null) {
      written.add(target.element!.baseElement);
    }
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    final element = node.declaredFragment?.element;
    if (element is LocalVariableElement) {
      initializers[element.baseElement] = node.initializer;
    }
    super.visitVariableDeclaration(node);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    _write(node.leftHandSide);
    super.visitAssignmentExpression(node);
  }

  @override
  void visitForEachPartsWithIdentifier(ForEachPartsWithIdentifier node) {
    _write(node.identifier);
    super.visitForEachPartsWithIdentifier(node);
  }

  @override
  void visitAssignedVariablePattern(AssignedVariablePattern node) {
    final element = node.element;
    if (element != null) written.add(element.baseElement);
    super.visitAssignedVariablePattern(node);
  }

  @override
  void visitPrefixExpression(PrefixExpression node) {
    if (node.operator.lexeme == '++' || node.operator.lexeme == '--') {
      _write(node.operand);
    }
    super.visitPrefixExpression(node);
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    _write(node.operand);
    super.visitPostfixExpression(node);
  }
}
