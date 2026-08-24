import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';

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
      return const ThrowSource(
        kind: ThrowSourceKind.futureError,
        confidence: ThrowConfidence.asyncError,
        displayName: 'Future.error',
        isAsync: true,
      );
    }

    if (className == 'JsonDecoder' &&
        _isExpectedLibrary(libraryUri, 'dart:convert')) {
      return const ThrowSource(
        kind: ThrowSourceKind.decodeCall,
        confidence: ThrowConfidence.possibleThrow,
        displayName: 'JsonDecoder',
      );
    }

    return null;
  }

  static ThrowSource? _matchMethodInvocation(
    MethodInvocation node, {
    required String? libraryUri,
    required String? callableName,
    required ExceptionAnalysisOptions options,
  }) {
    final name = callableName ?? node.methodName.name;
    final targetSource = node.target?.toSource();
    if (options.treatParseMethodsAsThrowing &&
        name == 'parse' &&
        _isExpectedLibrary(libraryUri, 'dart:core')) {
      switch (targetSource) {
        case 'int':
          return const ThrowSource(
            kind: ThrowSourceKind.parseCall,
            confidence: ThrowConfidence.possibleThrow,
            displayName: 'int.parse',
          );
        case 'double':
          return const ThrowSource(
            kind: ThrowSourceKind.parseCall,
            confidence: ThrowConfidence.possibleThrow,
            displayName: 'double.parse',
          );
        case 'DateTime':
          return const ThrowSource(
            kind: ThrowSourceKind.parseCall,
            confidence: ThrowConfidence.possibleThrow,
            displayName: 'DateTime.parse',
          );
        case 'Uri':
          return const ThrowSource(
            kind: ThrowSourceKind.parseCall,
            confidence: ThrowConfidence.possibleThrow,
            displayName: 'Uri.parse',
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

    if (_isExpectedLibrary(libraryUri, 'dart:core') &&
        (name == 'single' || name == 'first' || name == 'last')) {
      return ThrowSource(
        kind: ThrowSourceKind.collectionStateCall,
        confidence: ThrowConfidence.possibleThrow,
        displayName: name,
      );
    }

    if (name == 'singleWhere' && _isExpectedLibrary(libraryUri, 'dart:core')) {
      return ThrowSource(
        kind: ThrowSourceKind.collectionStateCall,
        confidence: ThrowConfidence.possibleThrow,
        displayName: 'singleWhere',
      );
    }

    if (name == 'firstWhere' &&
        _isExpectedLibrary(libraryUri, 'dart:core') &&
        node.argumentList.arguments.whereType<NamedArgument>().every(
          (argument) => argument.name.lexeme != 'orElse',
        )) {
      return ThrowSource(
        kind: ThrowSourceKind.collectionStateCall,
        confidence: ThrowConfidence.possibleThrow,
        displayName: 'firstWhere',
      );
    }

    if (name == 'error' &&
        targetSource == 'Future' &&
        _isExpectedLibrary(libraryUri, 'dart:async')) {
      return const ThrowSource(
        kind: ThrowSourceKind.futureError,
        confidence: ThrowConfidence.asyncError,
        displayName: 'Future.error',
        isAsync: true,
      );
    }

    if (name == 'completeError' &&
        _isExpectedLibrary(libraryUri, 'dart:async')) {
      return const ThrowSource(
        kind: ThrowSourceKind.completerCompleteError,
        confidence: ThrowConfidence.asyncError,
        displayName: 'Completer.completeError',
        isAsync: true,
      );
    }

    if (name == 'addError' && _isExpectedLibrary(libraryUri, 'dart:async')) {
      return const ThrowSource(
        kind: ThrowSourceKind.streamAddError,
        confidence: ThrowConfidence.asyncError,
        displayName: 'StreamController.addError',
        isAsync: true,
      );
    }

    if (name == 'throwWithStackTrace' &&
        targetSource == 'Error' &&
        _isExpectedLibrary(libraryUri, 'dart:core')) {
      return const ThrowSource(
        kind: ThrowSourceKind.futureError,
        confidence: ThrowConfidence.asyncError,
        displayName: 'Error.throwWithStackTrace',
        isAsync: true,
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
}
