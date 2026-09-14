import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

import '../config/exception_analysis_options.dart';
import 'throw_summary.dart';

final class ThrowSourceCatalog {
  const ThrowSourceCatalog._();

  static ThrowSource? matchResolvedInvocation(
    AstNode node,
    Element? element,
    ExceptionAnalysisOptions options,
  ) {
    return switch (node) {
      MethodInvocation() => _matchMethodInvocation(
        node,
        libraryUri: element?.library?.uri.toString(),
        callableName: element?.name,
        enclosingClassName: element?.enclosingElement?.name,
        options: options,
      ),
      FunctionExpressionInvocation() => _matchFunctionInvocation(
        node,
        libraryUri: element?.library?.uri.toString(),
        callableName: element?.name,
        options: options,
      ),
      InstanceCreationExpression() => _matchInstanceCreation(
        node,
        libraryUri: element?.library?.uri.toString(),
        className: element?.enclosingElement?.name,
        constructorName: element?.name,
      ),
      _ => null,
    };
  }

  static ThrowSource? matchUnresolvedInvocation(
    AstNode node,
    ExceptionAnalysisOptions options,
  ) {
    return switch (node) {
      MethodInvocation() => _matchMethodInvocation(
        node,
        libraryUri: null,
        callableName: node.methodName.name,
        options: options,
      ),
      FunctionExpressionInvocation(:final function)
          when function is SimpleIdentifier =>
        _matchFunctionInvocation(
          node,
          libraryUri: null,
          callableName: function.name,
          options: options,
        ),
      InstanceCreationExpression(:final constructorName) =>
        _matchInstanceCreation(
          node,
          libraryUri: null,
          className: constructorName.type.name.lexeme,
          constructorName: constructorName.name?.name ?? '',
        ),
      _ => null,
    };
  }

  static ThrowSource? matchIndexAccess(
    IndexExpression node,
    ExceptionAnalysisOptions options,
  ) {
    if (!options.treatIndexAccessAsThrowing) {
      return null;
    }

    return const ThrowSource(
      kind: ThrowSourceKind.indexAccess,
      confidence: ThrowConfidence.possibleThrow,
      displayName: 'index access',
      exceptionTypes: ['RangeError'],
    );
  }

  static ThrowSource? matchAsExpression(
    AsExpression node,
    ExceptionAnalysisOptions options,
  ) {
    if (!options.treatAsCastsAsThrowing) {
      return null;
    }

    return ThrowSource(
      kind: ThrowSourceKind.asCast,
      confidence: ThrowConfidence.possibleThrow,
      displayName: 'cast to ${node.type}',
      exceptionTypes: const ['TypeError'],
    );
  }

  static ThrowSource? matchLateInitializationRead(
    SimpleIdentifier node,
    ExceptionAnalysisOptions options,
  ) {
    final element = node.element;
    final isLate = switch (element) {
      VariableElement(:final isLate) => isLate,
      PropertyAccessorElement(:final variable) => variable.isLate,
      _ => false,
    };
    if (!options.treatLateInitializationAsThrowing || !isLate) {
      return null;
    }
    if (node.parent is VariableDeclaration) {
      return null;
    }
    return ThrowSource(
      kind: ThrowSourceKind.lateInitializationRead,
      confidence: ThrowConfidence.possibleThrow,
      displayName: 'late variable ${node.name}',
      exceptionTypes: const ['LateInitializationError'],
    );
  }

  static ThrowSource? matchBinaryExpression(
    BinaryExpression node,
    ExceptionAnalysisOptions options,
  ) {
    if (!options.treatArithmeticAsThrowing ||
        (node.operator.lexeme != '~/' && node.operator.lexeme != '%')) {
      return null;
    }
    if (node.operator.lexeme == '%' &&
        (node.leftOperand.staticType?.getDisplayString() != 'int' ||
            node.rightOperand.staticType?.getDisplayString() != 'int')) {
      return null;
    }
    return const ThrowSource(
      kind: ThrowSourceKind.arithmeticOperation,
      confidence: ThrowConfidence.possibleThrow,
      displayName: 'integer arithmetic',
      exceptionTypes: ['IntegerDivisionByZeroException'],
    );
  }

  static ThrowSource? _matchFunctionInvocation(
    FunctionExpressionInvocation node, {
    required String? libraryUri,
    required String? callableName,
    required ExceptionAnalysisOptions options,
  }) {
    if (callableName == 'jsonDecode' &&
        _isExpectedLibrary(libraryUri, 'dart:convert')) {
      return const ThrowSource(
        kind: ThrowSourceKind.decodeCall,
        confidence: ThrowConfidence.possibleThrow,
        displayName: 'jsonDecode',
        exceptionTypes: ['FormatException'],
      );
    }

    return null;
  }

  static ThrowSource? _matchInstanceCreation(
    InstanceCreationExpression node, {
    required String? libraryUri,
    required String? className,
    required String? constructorName,
  }) {
    if (className == 'Future' &&
        constructorName == 'error' &&
        _isExpectedLibrary(libraryUri, 'dart:async')) {
      return ThrowSource(
        kind: ThrowSourceKind.futureError,
        confidence: ThrowConfidence.asyncError,
        displayName: 'Future.error',
        isAsync: true,
        exceptionTypes: _argumentExceptionTypes(node.argumentList),
      );
    }

    if (className == 'JsonDecoder' &&
        _isExpectedLibrary(libraryUri, 'dart:convert')) {
      return const ThrowSource(
        kind: ThrowSourceKind.decodeCall,
        confidence: ThrowConfidence.possibleThrow,
        displayName: 'JsonDecoder',
        exceptionTypes: ['FormatException'],
      );
    }

    if (_isExpectedLibrary(libraryUri, 'dart:core') &&
        (className == 'RegExp' || className == 'BigInt')) {
      return ThrowSource(
        kind: ThrowSourceKind.parseCall,
        confidence: ThrowConfidence.possibleThrow,
        displayName: '$className constructor',
        exceptionTypes: const ['FormatException'],
      );
    }

    return null;
  }

  static ThrowSource? _matchMethodInvocation(
    MethodInvocation node, {
    required String? libraryUri,
    required String? callableName,
    String? enclosingClassName,
    required ExceptionAnalysisOptions options,
  }) {
    final name = callableName ?? node.methodName.name;
    final targetSource = enclosingClassName ?? node.target?.toSource();
    if (options.treatParseMethodsAsThrowing &&
        name == 'parse' &&
        _isExpectedLibrary(libraryUri, 'dart:core')) {
      switch (targetSource) {
        case 'int':
          return const ThrowSource(
            kind: ThrowSourceKind.parseCall,
            confidence: ThrowConfidence.possibleThrow,
            displayName: 'int.parse',
            exceptionTypes: ['FormatException'],
          );
        case 'double':
          return const ThrowSource(
            kind: ThrowSourceKind.parseCall,
            confidence: ThrowConfidence.possibleThrow,
            displayName: 'double.parse',
            exceptionTypes: ['FormatException'],
          );
        case 'DateTime':
          return const ThrowSource(
            kind: ThrowSourceKind.parseCall,
            confidence: ThrowConfidence.possibleThrow,
            displayName: 'DateTime.parse',
            exceptionTypes: ['FormatException'],
          );
        case 'Uri':
          return const ThrowSource(
            kind: ThrowSourceKind.parseCall,
            confidence: ThrowConfidence.possibleThrow,
            displayName: 'Uri.parse',
            exceptionTypes: ['FormatException'],
          );
        case 'num':
          return const ThrowSource(
            kind: ThrowSourceKind.parseCall,
            confidence: ThrowConfidence.possibleThrow,
            displayName: 'num.parse',
            exceptionTypes: ['FormatException'],
          );
        case 'BigInt':
          return const ThrowSource(
            kind: ThrowSourceKind.parseCall,
            confidence: ThrowConfidence.possibleThrow,
            displayName: 'BigInt.parse',
            exceptionTypes: ['FormatException'],
          );
      }
    }

    if (name == 'jsonDecode' &&
        targetSource == null &&
        _isExpectedLibrary(libraryUri, 'dart:convert')) {
      return const ThrowSource(
        kind: ThrowSourceKind.decodeCall,
        confidence: ThrowConfidence.possibleThrow,
        displayName: 'jsonDecode',
      );
    }

    if (name == 'convert' &&
        targetSource == 'JsonDecoder' &&
        _isExpectedLibrary(libraryUri, 'dart:convert')) {
      return const ThrowSource(
        kind: ThrowSourceKind.decodeCall,
        confidence: ThrowConfidence.possibleThrow,
        displayName: 'JsonDecoder.convert',
      );
    }

    if (options.treatCollectionStateAsThrowing &&
        _isExpectedLibrary(libraryUri, 'dart:core') &&
        (name == 'single' ||
            name == 'first' ||
            name == 'last' ||
            name == 'elementAt' ||
            name == 'removeAt' ||
            name == 'insert' ||
            name == 'setRange' ||
            name == 'substring' ||
            name == 'codeUnitAt' ||
            name == 'byName')) {
      return ThrowSource(
        kind: ThrowSourceKind.collectionStateCall,
        confidence: ThrowConfidence.possibleThrow,
        displayName: name,
        exceptionTypes: const ['RangeError', 'StateError'],
      );
    }

    if (options.treatCollectionStateAsThrowing &&
        name == 'singleWhere' &&
        _isExpectedLibrary(libraryUri, 'dart:core')) {
      return ThrowSource(
        kind: ThrowSourceKind.collectionStateCall,
        confidence: ThrowConfidence.possibleThrow,
        displayName: 'singleWhere',
        exceptionTypes: const ['StateError'],
      );
    }

    if (options.treatCollectionStateAsThrowing &&
        (name == 'firstWhere' || name == 'lastWhere') &&
        _isExpectedLibrary(libraryUri, 'dart:core') &&
        node.argumentList.arguments.whereType<NamedArgument>().every(
          (argument) => argument.name.lexeme != 'orElse',
        )) {
      return ThrowSource(
        kind: ThrowSourceKind.collectionStateCall,
        confidence: ThrowConfidence.possibleThrow,
        displayName: name,
        exceptionTypes: const ['StateError'],
      );
    }

    if (name == 'error' &&
        targetSource == 'Future' &&
        _isExpectedLibrary(libraryUri, 'dart:async')) {
      return ThrowSource(
        kind: ThrowSourceKind.futureError,
        confidence: ThrowConfidence.asyncError,
        displayName: 'Future.error',
        isAsync: true,
        exceptionTypes: _argumentExceptionTypes(node.argumentList),
      );
    }

    if (_isExpectedLibrary(libraryUri, 'dart:async') &&
        targetSource == 'Future' &&
        (name == 'wait' ||
            name == 'any' ||
            name == 'sync' ||
            name == 'microtask' ||
            name == 'delayed')) {
      return ThrowSource(
        kind: ThrowSourceKind.asyncOperation,
        confidence: ThrowConfidence.asyncError,
        displayName: 'Future.$name',
        isAsync: true,
      );
    }

    if (_isExpectedLibrary(libraryUri, 'dart:async') &&
        enclosingClassName == 'Future' &&
        name == 'timeout') {
      return const ThrowSource(
        kind: ThrowSourceKind.asyncOperation,
        confidence: ThrowConfidence.asyncError,
        displayName: 'Future.timeout',
        isAsync: true,
      );
    }

    if (name == 'completeError' &&
        _isExpectedLibrary(libraryUri, 'dart:async')) {
      return ThrowSource(
        kind: ThrowSourceKind.completerCompleteError,
        confidence: ThrowConfidence.asyncError,
        displayName: 'Completer.completeError',
        isAsync: true,
        exceptionTypes: _argumentExceptionTypes(node.argumentList),
      );
    }

    if (name == 'addError' && _isExpectedLibrary(libraryUri, 'dart:async')) {
      return ThrowSource(
        kind: ThrowSourceKind.streamAddError,
        confidence: ThrowConfidence.asyncError,
        displayName: 'StreamController.addError',
        isAsync: true,
        exceptionTypes: _argumentExceptionTypes(node.argumentList),
      );
    }

    if (name == 'throwWithStackTrace' &&
        targetSource == 'Error' &&
        _isExpectedLibrary(libraryUri, 'dart:core')) {
      return const ThrowSource(
        kind: ThrowSourceKind.explicitThrow,
        confidence: ThrowConfidence.definiteThrow,
        displayName: 'Error.throwWithStackTrace',
      );
    }

    return null;
  }

  /// A null URI means the invocation was unresolved while analyzing a body.
  /// In that case the syntax-based fallback remains intentionally conservative;
  /// a resolved invocation must belong to the expected SDK library.
  static bool _isExpectedLibrary(String? actual, String expected) {
    return actual == null || actual == expected;
  }

  static List<String> _argumentExceptionTypes(ArgumentList arguments) {
    if (arguments.arguments.isEmpty) return const [];
    final expression = arguments.arguments.first;
    if (expression is NamedArgument) return const [];
    final type = expression.argumentExpression.staticType;
    if (type is! InterfaceType) return const [];
    return {
      type.element.name,
      for (final supertype in type.allSupertypes) supertype.element.name,
    }.whereType<String>().toList();
  }
}
