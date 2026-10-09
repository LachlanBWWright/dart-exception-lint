import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

import '../config/exception_analysis_options.dart';
import 'throw_summary.dart';
import '../engine/exception_effect.dart';
import '../engine/numeric_checks.dart';
import '../engine/numeric_parse_checks.dart';

final class ThrowSourceCatalog {
  const ThrowSourceCatalog._();

  static ThrowSource? matchResolvedInvocation(
    AstNode node,
    Element? element,
    ExceptionAnalysisOptions options,
  ) {
    if (NumericParseChecks.modelsInvocation(node, element)) {
      return options.treatParseMethodsAsThrowing
          ? NumericParseChecks.invocation(node, element)
          : null;
    }
    if (NumericChecks.modelsInvocation(node, element)) {
      // A modeled pure numeric call must not fall through to broad legacy
      // constructor classifications (notably BigInt.from as parsing).
      return options.treatArithmeticAsThrowing
          ? NumericChecks.invocation(node, element)
          : null;
    }
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

    final target = node.realTarget;
    final type = target.staticType;
    final index = node.index;
    final sdkList =
        type is InterfaceType &&
        (type.isDartCoreList ||
            type.allSupertypes.any((type) => type.isDartCoreList));
    final sdkString = type is InterfaceType && type.isDartCoreString;
    if (!sdkList && !sdkString) return null;
    final literalLength = switch (target) {
      ListLiteral(:final elements)
          when elements.every((element) => element is Expression) =>
        elements.length,
      SimpleStringLiteral() => target.value.length,
      _ => null,
    };
    if (node.inGetterContext() &&
        !node.inSetterContext() &&
        index is IntegerLiteral &&
        literalLength != null &&
        index.value != null &&
        index.value! >= 0 &&
        index.value! < literalLength) {
      return const ThrowSource(
        kind: ThrowSourceKind.indexAccess,
        confidence: ThrowConfidence.noObviousThrow,
        displayName: 'proven in-bounds literal index',
      );
    }
    return ThrowSource(
      kind: ThrowSourceKind.indexAccess,
      confidence: ThrowConfidence.possibleThrow,
      displayName: 'index access',
      exceptionTypes: [
        'RangeError',
        if (index.staticType is DynamicType) 'TypeError',
        if (node.inSetterContext()) 'UnsupportedError',
      ],
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
    final variable = element is PropertyAccessorElement
        ? element.variable
        : element;
    if (variable is PropertyInducingElement && variable.hasInitializer) {
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
    return options.treatArithmeticAsThrowing
        ? NumericChecks.binary(node)
        : null;
  }

  static ThrowSource? matchAssignmentExpression(
    AssignmentExpression node,
    ExceptionAnalysisOptions options,
  ) =>
      options.treatArithmeticAsThrowing ? NumericChecks.assignment(node) : null;

  static ThrowSource matchAssertStatement(AssertStatement node) {
    return const ThrowSource(
      kind: ThrowSourceKind.assertion,
      confidence: ThrowConfidence.possibleThrow,
      displayName: 'assertion',
      exceptionTypes: ['AssertionError'],
    );
  }

  static ThrowSource? _matchFunctionInvocation(
    FunctionExpressionInvocation node, {
    required String? libraryUri,
    required String? callableName,
    required ExceptionAnalysisOptions options,
  }) {
    if (libraryUri == 'dart:async' && callableName == 'scheduleMicrotask') {
      return const ThrowSource(
        kind: ThrowSourceKind.asyncOperation,
        confidence: ThrowConfidence.unknown,
        displayName: 'scheduled microtask callback',
        isAsync: true,
        channel: ExceptionChannel.scheduled,
      );
    }
    if (callableName == 'jsonDecode' &&
        _isExpectedLibrary(libraryUri, 'dart:convert')) {
      return const ThrowSource(
        kind: ThrowSourceKind.decodeCall,
        confidence: ThrowConfidence.possibleThrow,
        displayName: 'jsonDecode',
        exceptionTypes: ['FormatException'],
      );
    }

    if (callableName == 'base64Decode' &&
        _isExpectedLibrary(libraryUri, 'dart:convert')) {
      return const ThrowSource(
        kind: ThrowSourceKind.decodeCall,
        confidence: ThrowConfidence.possibleThrow,
        displayName: 'base64Decode',
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
    // Audited core constructors only initialize fields; allocation failure is
    // outside the Dart-exception contract. Argument checks remain separate.
    if (libraryUri == 'dart:core' &&
        (constructorName == null ||
            constructorName.isEmpty ||
            constructorName == 'new') &&
        const {
          'Object',
          'Exception',
          'FormatException',
          'StateError',
          'UnsupportedError',
          'UnimplementedError',
        }.contains(className)) {
      return ThrowSource(
        kind: ThrowSourceKind.inferredCall,
        confidence: ThrowConfidence.noObviousThrow,
        displayName: '$className constructor',
      );
    }

    if (libraryUri == 'dart:async' &&
        className == 'Future' &&
        constructorName == 'value') {
      final argument =
          node.argumentList.arguments.firstOrNull?.argumentExpression;
      final type = argument?.staticType;
      final assimilatesFuture =
          type is DynamicType ||
          type is TypeParameterType ||
          (type is InterfaceType &&
              (type.isDartAsyncFuture || type.isDartAsyncFutureOr));
      return ThrowSource(
        kind: ThrowSourceKind.asyncOperation,
        confidence: assimilatesFuture
            ? ThrowConfidence.asyncError
            : ThrowConfidence.noObviousThrow,
        displayName: 'Future.value',
        isAsync: assimilatesFuture,
      );
    }

    if (className == 'Future' &&
        constructorName == 'error' &&
        _isExpectedLibrary(libraryUri, 'dart:async')) {
      return ThrowSource(
        kind: ThrowSourceKind.futureError,
        confidence: ThrowConfidence.asyncError,
        displayName: 'Future.error',
        isAsync: true,
        exceptionTypes: _argumentExceptionTypes(node.argumentList),
        exceptionSupertypes: _argumentExceptionSupertypes(node.argumentList),
        resolvedExceptionTypes: [
          ?node
              .argumentList
              .arguments
              .firstOrNull
              ?.argumentExpression
              .staticType,
        ],
      );
    }

    if (className == 'Timer' && _isExpectedLibrary(libraryUri, 'dart:async')) {
      return const ThrowSource(
        kind: ThrowSourceKind.asyncOperation,
        confidence: ThrowConfidence.asyncError,
        displayName: 'Timer callback',
        isAsync: true,
        channel: ExceptionChannel.scheduled,
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
        (className == 'RegExp' ||
            className == 'BigInt' && constructorName == 'parse')) {
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
    if (libraryUri == 'dart:core' &&
        enclosingClassName == 'Object' &&
        node.target is SuperExpression &&
        name == 'noSuchMethod') {
      return const ThrowSource(
        kind: ThrowSourceKind.inferredCall,
        confidence: ThrowConfidence.definiteThrow,
        displayName: 'Object.noSuchMethod',
        exceptionTypes: ['NoSuchMethodError'],
        exceptionSupertypes: {
          'NoSuchMethodError': ['Error', 'Object'],
        },
      );
    }
    if (libraryUri == 'dart:async' && name == 'scheduleMicrotask') {
      return const ThrowSource(
        kind: ThrowSourceKind.asyncOperation,
        confidence: ThrowConfidence.unknown,
        displayName: 'scheduled microtask callback',
        isAsync: true,
        channel: ExceptionChannel.scheduled,
      );
    }
    final targetSource =
        enclosingClassName ??
        node.target?.staticType?.getDisplayString() ??
        node.target?.toSource();
    if (libraryUri == 'dart:async' &&
        name == 'value' &&
        targetSource == 'Future') {
      final type = node
          .argumentList
          .arguments
          .firstOrNull
          ?.argumentExpression
          .staticType;
      final assimilatesFuture =
          type is DynamicType ||
          type is TypeParameterType ||
          (type is InterfaceType &&
              (type.isDartAsyncFuture || type.isDartAsyncFutureOr));
      return ThrowSource(
        kind: ThrowSourceKind.asyncOperation,
        confidence: assimilatesFuture
            ? ThrowConfidence.asyncError
            : ThrowConfidence.noObviousThrow,
        displayName: 'Future.value',
        isAsync: assimilatesFuture,
      );
    }

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

    if (_isExpectedLibrary(libraryUri, 'dart:core') &&
        enclosingClassName == 'Uri' &&
        (name == 'decodeComponent' || name == 'decodeFull')) {
      return const ThrowSource(
        kind: ThrowSourceKind.decodeCall,
        confidence: ThrowConfidence.possibleThrow,
        displayName: 'Uri decoding',
        exceptionTypes: ['FormatException'],
      );
    }

    if (_isExpectedLibrary(libraryUri, 'dart:core') &&
        enclosingClassName == 'UriData' &&
        name == 'parse') {
      return const ThrowSource(
        kind: ThrowSourceKind.parseCall,
        confidence: ThrowConfidence.possibleThrow,
        displayName: 'UriData.parse',
        exceptionTypes: ['FormatException'],
      );
    }

    if (_isExpectedLibrary(libraryUri, 'dart:core') &&
        enclosingClassName == 'String' &&
        (name == 'fromCharCode' || name == 'fromCharCodes')) {
      return const ThrowSource(
        kind: ThrowSourceKind.collectionStateCall,
        confidence: ThrowConfidence.possibleThrow,
        displayName: 'String character construction',
        exceptionTypes: ['RangeError'],
      );
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

    if (name == 'convert' &&
        targetSource == 'JsonEncoder' &&
        _isExpectedLibrary(libraryUri, 'dart:convert')) {
      return const ThrowSource(
        kind: ThrowSourceKind.decodeCall,
        confidence: ThrowConfidence.possibleThrow,
        displayName: 'JsonEncoder.convert',
        exceptionTypes: ['JsonUnsupportedObjectError'],
      );
    }

    if (_isExpectedLibrary(libraryUri, 'dart:convert') &&
        (name == 'decode' &&
            (targetSource == 'Utf8Codec' ||
                targetSource == 'Base64Codec' ||
                targetSource == 'AsciiCodec' ||
                targetSource == 'Latin1Codec'))) {
      return ThrowSource(
        kind: ThrowSourceKind.decodeCall,
        confidence: ThrowConfidence.possibleThrow,
        displayName: '$targetSource.decode',
        exceptionTypes: const ['FormatException'],
      );
    }

    if (_isExpectedLibrary(libraryUri, 'dart:convert') &&
        name == 'convert' &&
        (targetSource == 'Utf8Decoder' ||
            targetSource == 'Base64Decoder' ||
            targetSource == 'AsciiDecoder' ||
            targetSource == 'Latin1Decoder')) {
      return ThrowSource(
        kind: ThrowSourceKind.decodeCall,
        confidence: ThrowConfidence.possibleThrow,
        displayName: '$targetSource.convert',
        exceptionTypes: const ['FormatException'],
      );
    }

    // Stream terminal operations asynchronously surface both errors emitted
    // by the stream and state errors such as an empty stream. Keep the
    // exception list open because a stream may carry application-defined
    // errors as well as SDK errors.
    if (_isExpectedLibrary(libraryUri, 'dart:async') &&
        enclosingClassName == 'Stream' &&
        (name == 'first' ||
            name == 'last' ||
            name == 'single' ||
            name == 'elementAt' ||
            name == 'firstWhere' ||
            name == 'lastWhere' ||
            name == 'singleWhere' ||
            name == 'reduce' ||
            name == 'fold' ||
            name == 'toList')) {
      return ThrowSource(
        kind: ThrowSourceKind.asyncOperation,
        confidence: ThrowConfidence.asyncError,
        displayName: 'Stream.$name',
        isAsync: true,
      );
    }

    if (_isExpectedLibrary(libraryUri, 'dart:async') &&
        enclosingClassName == 'Stream' &&
        (name == 'timeout' || name == 'drain' || name == 'toSet')) {
      return const ThrowSource(
        kind: ThrowSourceKind.asyncOperation,
        confidence: ThrowConfidence.asyncError,
        displayName: 'Stream terminal operation',
        isAsync: true,
      );
    }

    // These operations asynchronously surface errors from the source stream,
    // callback, transformer, or destination sink.
    if (_isExpectedLibrary(libraryUri, 'dart:async') &&
        enclosingClassName == 'Stream' &&
        const {
          'listen',
          'asBroadcastStream',
          'transform',
          'pipe',
          'join',
          'contains',
          'any',
          'every',
          'forEach',
          'map',
          'where',
          'expand',
          'asyncMap',
          'asyncExpand',
          'distinct',
          'take',
          'takeWhile',
          'skip',
          'skipWhile',
          'whereType',
          'cast',
        }.contains(name)) {
      return ThrowSource(
        kind: ThrowSourceKind.asyncOperation,
        confidence: ThrowConfidence.asyncError,
        displayName: 'Stream.$name',
        isAsync: true,
      );
    }

    if (_isExpectedLibrary(libraryUri, 'dart:core') &&
        enclosingClassName == 'ArgumentError' &&
        name == 'checkNotNull') {
      return const ThrowSource(
        kind: ThrowSourceKind.collectionStateCall,
        confidence: ThrowConfidence.possibleThrow,
        displayName: 'ArgumentError.checkNotNull',
        exceptionTypes: ['ArgumentError'],
      );
    }

    if (_isExpectedLibrary(libraryUri, 'dart:core') &&
        enclosingClassName == 'RangeError' &&
        (name == 'checkValidIndex' ||
            name == 'checkValidRange' ||
            name == 'checkValueInInterval')) {
      return ThrowSource(
        kind: ThrowSourceKind.collectionStateCall,
        confidence: ThrowConfidence.possibleThrow,
        displayName: 'RangeError.$name',
        exceptionTypes: const ['RangeError'],
      );
    }

    if (options.treatCollectionStateAsThrowing &&
        _isExpectedLibrary(libraryUri, 'dart:core') &&
        (name == 'single' ||
            name == 'reduce' ||
            name == 'first' ||
            name == 'last' ||
            name == 'elementAt' ||
            name == 'removeAt' ||
            name == 'insert' ||
            name == 'setRange' ||
            name == 'setAll' ||
            name == 'fillRange' ||
            name == 'replaceRange' ||
            name == 'removeRange' ||
            name == 'substring' ||
            name == 'codeUnitAt' ||
            name == 'byName')) {
      return ThrowSource(
        kind: ThrowSourceKind.collectionStateCall,
        confidence: ThrowConfidence.possibleThrow,
        displayName: name,
        exceptionTypes:
            const {'single', 'reduce', 'first', 'last'}.contains(name)
            ? const ['StateError']
            : name == 'byName'
            ? const ['ArgumentError']
            : const ['RangeError'],
      );
    }

    if (options.treatCollectionStateAsThrowing &&
        _isExpectedLibrary(libraryUri, 'dart:core') &&
        const {
          'getRange',
          'insertAll',
          'skip',
          'take',
          'skipWhile',
          'takeWhile',
        }.contains(name)) {
      return ThrowSource(
        kind: ThrowSourceKind.collectionStateCall,
        confidence: ThrowConfidence.possibleThrow,
        displayName: name,
        exceptionTypes: const ['RangeError', 'ArgumentError'],
      );
    }

    if (options.treatCollectionStateAsThrowing &&
        _isExpectedLibrary(libraryUri, 'dart:core') &&
        name == 'update' &&
        (targetSource == 'Map' || targetSource?.startsWith('Map<') == true) &&
        node.argumentList.arguments.whereType<NamedArgument>().every(
          (argument) => argument.name.lexeme != 'ifAbsent',
        )) {
      return const ThrowSource(
        kind: ThrowSourceKind.collectionStateCall,
        confidence: ThrowConfidence.possibleThrow,
        displayName: 'Map.update',
        exceptionTypes: ['StateError'],
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
        exceptionSupertypes: _argumentExceptionSupertypes(node.argumentList),
        resolvedExceptionTypes: [
          ?node
              .argumentList
              .arguments
              .firstOrNull
              ?.argumentExpression
              .staticType,
        ],
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
        const {'then', 'catchError', 'asStream'}.contains(name)) {
      return ThrowSource(
        kind: ThrowSourceKind.asyncOperation,
        confidence: ThrowConfidence.asyncError,
        displayName: 'Future.$name',
        isAsync: true,
      );
    }

    if (_isExpectedLibrary(libraryUri, 'dart:async') &&
        enclosingClassName == 'StreamController' &&
        const {'addStream', 'close'}.contains(name)) {
      return ThrowSource(
        kind: ThrowSourceKind.asyncOperation,
        confidence: ThrowConfidence.asyncError,
        displayName: 'StreamController.$name',
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
        exceptionTypes: ['TimeoutException'],
      );
    }

    if (_isExpectedLibrary(libraryUri, 'dart:async') &&
        enclosingClassName == 'Future' &&
        name == 'whenComplete') {
      return const ThrowSource(
        kind: ThrowSourceKind.asyncOperation,
        confidence: ThrowConfidence.asyncError,
        displayName: 'Future.whenComplete',
        isAsync: true,
      );
    }

    if (_isExpectedLibrary(libraryUri, 'dart:isolate') &&
        enclosingClassName == 'Isolate' &&
        (name == 'spawn' || name == 'spawnUri')) {
      return const ThrowSource(
        kind: ThrowSourceKind.asyncOperation,
        confidence: ThrowConfidence.asyncError,
        displayName: 'Isolate spawn',
        isAsync: true,
        exceptionTypes: ['IsolateSpawnException'],
      );
    }

    if (_isExpectedLibrary(libraryUri, 'dart:typed_data') &&
        (name == 'getInt8' ||
            name == 'getUint8' ||
            name == 'getInt16' ||
            name == 'getUint16' ||
            name == 'getInt32' ||
            name == 'getUint32' ||
            name == 'getInt64' ||
            name == 'getUint64' ||
            name == 'getFloat32' ||
            name == 'getFloat64' ||
            name == 'setInt8' ||
            name == 'setUint8' ||
            name == 'setInt16' ||
            name == 'setUint16' ||
            name == 'setInt32' ||
            name == 'setUint32' ||
            name == 'setInt64' ||
            name == 'setUint64' ||
            name == 'setFloat32' ||
            name == 'setFloat64')) {
      return ThrowSource(
        kind: ThrowSourceKind.collectionStateCall,
        confidence: ThrowConfidence.possibleThrow,
        displayName: 'ByteData.$name',
        exceptionTypes: const ['RangeError'],
      );
    }

    if (_isExpectedLibrary(libraryUri, 'dart:typed_data') &&
        const {
          'asInt8List',
          'asUint8List',
          'asInt16List',
          'asUint16List',
          'asInt32List',
          'asUint32List',
          'asInt64List',
          'asUint64List',
          'asFloat32List',
          'asFloat64List',
          'sublistView',
          'sublist',
          'getRange',
          'setRange',
        }.contains(name)) {
      return const ThrowSource(
        kind: ThrowSourceKind.collectionStateCall,
        confidence: ThrowConfidence.possibleThrow,
        displayName: 'typed-data bounds operation',
        exceptionTypes: ['RangeError'],
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
        exceptionSupertypes: _argumentExceptionSupertypes(node.argumentList),
        resolvedExceptionTypes: [
          ?node
              .argumentList
              .arguments
              .firstOrNull
              ?.argumentExpression
              .staticType,
        ],
      );
    }

    if (name == 'complete' &&
        enclosingClassName == 'Completer' &&
        _isExpectedLibrary(libraryUri, 'dart:async')) {
      return const ThrowSource(
        kind: ThrowSourceKind.collectionStateCall,
        confidence: ThrowConfidence.possibleThrow,
        displayName: 'Completer.complete',
        exceptionTypes: ['StateError'],
      );
    }

    if (name == 'addError' && _isExpectedLibrary(libraryUri, 'dart:async')) {
      return ThrowSource(
        kind: ThrowSourceKind.streamAddError,
        confidence: ThrowConfidence.asyncError,
        displayName: 'StreamController.addError',
        isAsync: true,
        exceptionTypes: _argumentExceptionTypes(node.argumentList),
        exceptionSupertypes: _argumentExceptionSupertypes(node.argumentList),
        resolvedExceptionTypes: [
          ?node
              .argumentList
              .arguments
              .firstOrNull
              ?.argumentExpression
              .staticType,
        ],
      );
    }

    if (name == 'add' &&
        enclosingClassName == 'StreamController' &&
        _isExpectedLibrary(libraryUri, 'dart:async')) {
      return const ThrowSource(
        kind: ThrowSourceKind.collectionStateCall,
        confidence: ThrowConfidence.possibleThrow,
        displayName: 'StreamController.add',
        exceptionTypes: ['StateError'],
      );
    }

    if (_isExpectedLibrary(libraryUri, 'dart:async') &&
        enclosingClassName == 'Timer' &&
        name == 'run') {
      return const ThrowSource(
        kind: ThrowSourceKind.asyncOperation,
        confidence: ThrowConfidence.asyncError,
        displayName: 'Timer.run',
        isAsync: true,
        channel: ExceptionChannel.scheduled,
      );
    }

    if (_isExpectedLibrary(libraryUri, 'dart:async') &&
        enclosingClassName == 'Timer' &&
        name == 'periodic') {
      return const ThrowSource(
        kind: ThrowSourceKind.asyncOperation,
        confidence: ThrowConfidence.asyncError,
        displayName: 'Timer.periodic',
        isAsync: true,
        channel: ExceptionChannel.scheduled,
      );
    }

    if (options.treatIoOperationsAsThrowing &&
        _isExpectedLibrary(libraryUri, 'dart:io')) {
      final ioMethods = <String, List<String>>{
        'File': [
          'readAsBytes',
          'readAsString',
          'writeAsBytes',
          'writeAsString',
          'copy',
          'create',
          'delete',
          'rename',
          'open',
          'openRead',
          'openWrite',
          'length',
          'lastModified',
          'setLastModified',
          'setLastAccessed',
          'readAsLines',
          'renameSync',
          'copySync',
          'deleteSync',
          'createSync',
        ],
        'Directory': [
          'create',
          'delete',
          'list',
          'rename',
          'watch',
          'exists',
          'createTemp',
          'createSync',
          'deleteSync',
          'listSync',
          'renameSync',
          'existsSync',
        ],
        'Socket': ['connect', 'connectSync', 'listen', 'bind', 'close'],
        'ServerSocket': ['bind', 'bindSync', 'close'],
        'RawSocket': ['connect', 'connectSync', 'startConnect'],
        'SecureSocket': ['connect', 'connectSync'],
        'HttpClient': [
          'open',
          'openUrl',
          'get',
          'getUrl',
          'post',
          'postUrl',
          'put',
          'putUrl',
          'delete',
          'deleteUrl',
          'close',
        ],
        'HttpServer': ['bind', 'bindSecure', 'close'],
        'InternetAddress': ['lookup'],
        'NetworkInterface': ['list'],
        'RandomAccessFile': [
          'read',
          'readByte',
          'readInto',
          'writeFrom',
          'writeByte',
          'setPosition',
          'truncate',
          'flush',
          'lock',
          'unlock',
          'length',
          'position',
          'close',
          'sync',
        ],
      };
      if (ioMethods[enclosingClassName]?.contains(name) == true) {
        final isAsync = name != 'connectSync';
        return ThrowSource(
          kind: ThrowSourceKind.asyncOperation,
          confidence: isAsync
              ? ThrowConfidence.asyncError
              : ThrowConfidence.possibleThrow,
          displayName: '$enclosingClassName.$name',
          isAsync: isAsync,
          exceptionTypes: const [
            'FileSystemException',
            'SocketException',
            'HttpException',
          ],
        );
      }
    }

    if (options.treatIoOperationsAsThrowing &&
        _isExpectedLibrary(libraryUri, 'dart:io') &&
        (enclosingClassName == 'FileSystemEntity' ||
            enclosingClassName == 'FileStat') &&
        (name == 'stat' || name == 'resolveSymbolicLinks' || name == 'watch')) {
      return const ThrowSource(
        kind: ThrowSourceKind.asyncOperation,
        confidence: ThrowConfidence.asyncError,
        displayName: 'filesystem operation',
        isAsync: true,
        exceptionTypes: ['FileSystemException'],
      );
    }

    if (options.treatIoOperationsAsThrowing &&
        _isExpectedLibrary(libraryUri, 'dart:io') &&
        enclosingClassName == 'Process' &&
        (name == 'run' || name == 'runSync' || name == 'start')) {
      final isAsync = name != 'runSync';
      return ThrowSource(
        kind: ThrowSourceKind.asyncOperation,
        confidence: isAsync
            ? ThrowConfidence.asyncError
            : ThrowConfidence.possibleThrow,
        displayName: 'Process.$name',
        isAsync: isAsync,
        exceptionTypes: const ['ProcessException', 'FileSystemException'],
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
    return [?type.element.name];
  }

  static Map<String, List<String>> _argumentExceptionSupertypes(
    ArgumentList arguments,
  ) {
    if (arguments.arguments.isEmpty) return const {};
    final expression = arguments.arguments.first;
    if (expression is NamedArgument) return const {};
    final type = expression.argumentExpression.staticType;
    if (type is! InterfaceType || type.element.name == null) return const {};
    return {
      type.element.name!: [
        for (final supertype in type.allSupertypes) ?supertype.element.name,
      ],
    };
  }
}
