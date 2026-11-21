import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

import '../config/exception_analysis_options.dart';
import 'throw_summary.dart';
import '../engine/exception_effect.dart';
import '../engine/numeric_checks.dart';
import '../engine/numeric_parse_checks.dart';
import '../engine/statement_completion.dart';
import '../engine/string_bounds.dart';
import '../engine/list_literals.dart';

final class ThrowSourceCatalog {
  const ThrowSourceCatalog._();

  static ThrowSource? matchResolvedInvocation(
    AstNode node,
    Element? element,
    ExceptionAnalysisOptions options,
  ) {
    // Spelling is not declaration identity. Unresolved calls are handled by
    // inference as unknown, including calls that resemble familiar SDK APIs.
    element = element?.baseElement;
    if (element is! ExecutableElement || !element.library.isInSdk) return null;
    if (element is GetterElement &&
        element.library.uri.toString() == 'dart:core' &&
        element.enclosingElement.name == 'String' &&
        const {'isEmpty', 'isNotEmpty', 'length'}.contains(element.name)) {
      return ThrowSource(
        kind: ThrowSourceKind.collectionStateCall,
        confidence: ThrowConfidence.noObviousThrow,
        displayName: 'String.${element.name}',
        evidence: const {EffectEvidence.sdkModel},
      );
    }
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
    final source = switch (node) {
      MethodInvocation() => _matchMethodInvocation(
        node,
        libraryUri: element.library.uri.toString(),
        callableName: element.name,
        enclosingClassName: element.enclosingElement is InterfaceElement
            ? element.enclosingElement?.name
            : null,
        options: options,
      ),
      FunctionExpressionInvocation() => _matchFunctionInvocation(
        node,
        libraryUri: element.library.uri.toString(),
        callableName: element.name,
        options: options,
      ),
      InstanceCreationExpression() => _matchInstanceCreation(
        node,
        libraryUri: element.library.uri.toString(),
        className: element.enclosingElement?.name,
        constructorName: element.name,
      ),
      AssignmentExpression(leftHandSide: final IndexExpression index) ||
      PrefixExpression(operand: final IndexExpression index) ||
      PostfixExpression(
        operand: final IndexExpression index,
      ) => matchIndexAccess(index, options, indexedOperator: element),
      _ => null,
    };
    return source?.withEvidence({EffectEvidence.sdkModel}, replace: true);
  }

  static ThrowSource? matchIndexAccess(
    IndexExpression node,
    ExceptionAnalysisOptions options, {
    ExecutableElement? indexedOperator,
  }) {
    if (!options.treatIndexAccessAsThrowing) {
      return null;
    }
    final parent = node.parent;
    final writes =
        node.inSetterContext() &&
        (parent is! AssignmentExpression || assignmentWriteCanExecute(parent));
    final (readElement, writeElement) = switch (parent) {
      AssignmentExpression() when identical(parent.leftHandSide, node) => (
        parent.readElement,
        parent.writeElement,
      ),
      PrefixExpression() when node.inSetterContext() => (
        parent.readElement,
        parent.writeElement,
      ),
      PostfixExpression() when node.inSetterContext() => (
        parent.readElement,
        parent.writeElement,
      ),
      _ => (node.element, null),
    };
    // User-defined index operators must use their own inferred behavior.
    final sdkRead =
        node.inGetterContext() &&
        readElement is ExecutableElement &&
        readElement.library.isInSdk &&
        (indexedOperator == null || indexedOperator == readElement.baseElement);
    final sdkWrite =
        writes &&
        writeElement is ExecutableElement &&
        writeElement.library.isInSdk &&
        (indexedOperator == null ||
            indexedOperator == writeElement.baseElement);
    if (!sdkRead && !sdkWrite) return null;

    final target = node.realTarget;
    final type = target.staticType;
    final index = node.index;
    final sdkList =
        type is InterfaceType &&
        (type.isDartCoreList ||
            type.allSupertypes.any((type) => type.isDartCoreList));
    final sdkString = type is InterfaceType && type.isDartCoreString;
    if (!sdkList && !sdkString) return null;
    if (sdkString && sdkRead && isProvenStringZeroIndex(node, target, index)) {
      return const ThrowSource(
        kind: ThrowSourceKind.indexAccess,
        confidence: ThrowConfidence.noObviousThrow,
        displayName: 'proven in-bounds String index',
      );
    }
    final literalLength = switch (target) {
      ListLiteral(:final elements)
          when elements.every((element) => element is Expression) =>
        elements.length,
      SimpleStringLiteral() => target.value.length,
      _ => null,
    };
    if (sdkRead &&
        !sdkWrite &&
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
    // The runtime list can have a narrower element type than its static view.
    final covariantWrite =
        sdkWrite &&
        writeElement.formalParameters.lastOrNull?.baseElement.type
            is TypeParameterType;
    return ThrowSource(
      kind: ThrowSourceKind.indexAccess,
      evidence: const {EffectEvidence.sdkModel},
      confidence: ThrowConfidence.possibleThrow,
      displayName: 'index access',
      exceptionTypes: [
        'RangeError',
        if (index.staticType is DynamicType || covariantWrite) 'TypeError',
        if (sdkWrite) 'UnsupportedError',
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
    if (!options.treatLateInitializationAsThrowing ||
        !isLate ||
        !node.inGetterContext()) {
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

  static ThrowSource? matchAssertion(
    Expression condition,
    Expression? message,
  ) {
    if (constantBooleanValue(condition) == true ||
        !expressionCanCompleteNormally(condition) ||
        message != null && !expressionCanCompleteNormally(message)) {
      return null;
    }
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

    if ((className == 'Future' || className == 'Stream') &&
        constructorName == 'error' &&
        _isExpectedLibrary(libraryUri, 'dart:async')) {
      final stream = className == 'Stream';
      return ThrowSource(
        kind: stream
            ? ThrowSourceKind.streamAddError
            : ThrowSourceKind.futureError,
        confidence: ThrowConfidence.asyncError,
        displayName: '$className.error',
        isAsync: true,
        channel: stream ? ExceptionChannel.stream : ExceptionChannel.future,
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

    if (libraryUri == 'dart:async' &&
        className == 'Stream' &&
        constructorName == 'fromFuture') {
      return _knownFutureStreamSource(
        node.argumentList.arguments.firstOrNull?.argumentExpression,
      );
    }
    if (libraryUri == 'dart:async' &&
        className == 'Stream' &&
        const {'empty', 'value'}.contains(constructorName)) {
      return ThrowSource(
        kind: ThrowSourceKind.asyncOperation,
        confidence: ThrowConfidence.noObviousThrow,
        displayName: 'Stream.$constructorName',
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
    if (name == 'add' &&
        libraryUri == 'dart:core' &&
        enclosingClassName == 'List') {
      final literal = literalListAddReceiver(node);
      final value = node.argumentList.arguments.firstOrNull?.argumentExpression;
      if (literal != null && value != null) {
        final exceptions = [
          if (literal.isConst && options.treatCollectionStateAsThrowing)
            'UnsupportedError',
          if (!literalListAccepts(literal, value) &&
              options.treatAsCastsAsThrowing)
            'TypeError',
        ];
        return ThrowSource(
          kind: ThrowSourceKind.collectionStateCall,
          confidence: exceptions.isEmpty
              ? ThrowConfidence.noObviousThrow
              : ThrowConfidence.possibleThrow,
          displayName: 'List.add',
          exceptionTypes: exceptions,
        );
      }
    }
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
    final targetSource = enclosingClassName;
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

    if (libraryUri == 'dart:core' &&
        enclosingClassName == 'String' &&
        name == 'codeUnitAt') {
      final receiver = node.realTarget;
      final index = node.argumentList.arguments.firstOrNull?.argumentExpression;
      if (receiver != null &&
          index != null &&
          isProvenStringZeroIndex(node, receiver, index)) {
        return const ThrowSource(
          kind: ThrowSourceKind.collectionStateCall,
          confidence: ThrowConfidence.noObviousThrow,
          displayName: 'proven in-bounds String code unit',
        );
      }
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
      if ((name == 'wait' || name == 'any') && _knownFutureJoinInputs(node)) {
        // Each input carries its own error through the join. The SDK call
        // adds no error of its own for these literal, native inputs.
        return ThrowSource(
          kind: ThrowSourceKind.asyncOperation,
          confidence: ThrowConfidence.noObviousThrow,
          displayName: 'Future.$name',
        );
      }
      return ThrowSource(
        kind: ThrowSourceKind.asyncOperation,
        confidence: ThrowConfidence.asyncError,
        displayName: 'Future.$name',
        isAsync: true,
      );
    }

    if (libraryUri == 'dart:async' &&
        enclosingClassName == 'Future' &&
        name == 'asStream') {
      return _knownFutureStreamSource(node.realTarget) ??
          const ThrowSource(
            kind: ThrowSourceKind.asyncOperation,
            confidence: ThrowConfidence.asyncError,
            displayName: 'Future.asStream',
            isAsync: true,
            channel: ExceptionChannel.stream,
          );
    }

    if (_isExpectedLibrary(libraryUri, 'dart:async') &&
        enclosingClassName == 'Future' &&
        const {'then', 'catchError'}.contains(name)) {
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

    if (_isExpectedLibrary(libraryUri, 'dart:js_interop') &&
        enclosingClassName == 'JSPromise' &&
        name == 'resolve') {
      return const ThrowSource(
        kind: ThrowSourceKind.collectionStateCall,
        confidence: ThrowConfidence.possibleThrow,
        displayName: 'JSPromise.resolve',
        exceptionTypes: ['ArgumentError'],
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
          'rangeEquals',
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

  static ThrowSource? _knownFutureStreamSource(Expression? expression) {
    final source = _knownFutureSource(expression);
    if (source == null) return null;
    return ThrowSource(
      kind: source.kind,
      confidence: source.confidence,
      displayName: source.displayName,
      isAsync: source.isAsync,
      channel: ExceptionChannel.stream,
      exceptionTypes: source.exceptionTypes,
      resolvedExceptionTypes: source.resolvedExceptionTypes,
      exceptionSupertypes: source.exceptionSupertypes,
    );
  }

  static ThrowSource? _knownFutureSource(Expression? expression) {
    while (expression is ParenthesizedExpression) {
      expression = expression.expression;
    }
    if (expression is! InstanceCreationExpression) return null;
    final constructor = expression.constructorName.element?.baseElement;
    if (constructor is! ConstructorElement ||
        constructor.library.uri.toString() != 'dart:async' ||
        constructor.enclosingElement.name != 'Future' ||
        (constructor.name != 'error' && constructor.name != 'value')) {
      return null;
    }
    final source = _matchInstanceCreation(
      expression,
      libraryUri: 'dart:async',
      className: 'Future',
      constructorName: constructor.name,
    );
    if (source == null ||
        source.isAsync && source.kind != ThrowSourceKind.futureError) {
      return null;
    }
    return source;
  }

  static bool _knownFutureJoinInputs(MethodInvocation node) {
    var input = node.argumentList.arguments.firstOrNull?.argumentExpression;
    while (input is ParenthesizedExpression) {
      input = input.expression;
    }
    return input is ListLiteral &&
        input.elements.every(
          (element) =>
              element is Expression && _knownFutureSource(element) != null,
        );
  }

  /// SDK models require an established library identity.
  static bool _isExpectedLibrary(String? actual, String expected) {
    return actual == expected;
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
