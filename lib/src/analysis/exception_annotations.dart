import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/type.dart';

bool hasExceptionBoundaryAnnotation(Element element) {
  if (_hasDirectExceptionBoundaryAnnotation(element)) {
    return true;
  }

  // A class-level annotation applies to all of its instance and static
  // members. This keeps propagation APIs concise without making callers
  // annotate every method individually.
  final enclosing = element.enclosingElement;
  return enclosing is InterfaceElement &&
      _hasDirectExceptionBoundaryAnnotation(enclosing);
}

/// Names alone never establish a contract: use the evaluated annotation type
/// so import prefixes, re-exports, and constant aliases resolve consistently.
String? exceptionAnnotationName(ElementAnnotation annotation) {
  final type = annotation.computeConstantValue()?.type;
  if (type is! InterfaceType ||
      type.element.library.uri.toString() !=
          'package:dart_exception_lint/dart_exception_lint.dart') {
    return null;
  }
  return type.element.name;
}

bool _hasDirectExceptionBoundaryAnnotation(Element element) =>
    element.metadata.annotations.any(
      (annotation) =>
          exceptionAnnotationName(annotation) == 'ExceptionBoundary',
    );

bool isInsideExceptionBoundary(AstNode node) {
  AstNode? current = node;
  while (current != null) {
    final element = switch (current) {
      FunctionDeclaration(:final declaredFragment) => declaredFragment?.element,
      MethodDeclaration(:final declaredFragment) => declaredFragment?.element,
      ConstructorDeclaration(:final declaredFragment) =>
        declaredFragment?.element,
      _ => null,
    };
    if (element != null && hasExceptionBoundaryAnnotation(element)) {
      return true;
    }
    current = current.parent;
  }
  return false;
}

/// The contract declared by a public exception annotation.
final class ExceptionContract {
  const ExceptionContract({
    required this.kind,
    required this.exceptionTypes,
    this.exceptionSupertypes = const {},
    this.resolvedExceptionTypes = const [],
  });

  final ExceptionContractKind kind;
  final List<String> exceptionTypes;
  final List<DartType> resolvedExceptionTypes;
  final Map<String, List<String>> exceptionSupertypes;
}

enum ExceptionContractKind { mayThrow, failingFuture, doesNotThrow }

ExceptionContract? exceptionContractFor(Element element) =>
    exceptionContractsFor(element).firstOrNull;

Iterable<ExceptionContract> exceptionContractsFor(Element element) sync* {
  for (final annotation in element.metadata.annotations) {
    final name = exceptionAnnotationName(annotation);
    final kind = switch (name) {
      'MayThrow' => ExceptionContractKind.mayThrow,
      'ReturnsFailingFuture' => ExceptionContractKind.failingFuture,
      'DoesNotThrow' => ExceptionContractKind.doesNotThrow,
      _ => null,
    };
    if (kind == null) continue;
    if (kind == ExceptionContractKind.doesNotThrow) {
      yield const ExceptionContract(
        kind: ExceptionContractKind.doesNotThrow,
        exceptionTypes: [],
      );
      continue;
    }

    final value = annotation.computeConstantValue();
    final types = value?.getField('exceptionTypes')?.toListValue();
    yield ExceptionContract(
      kind: kind,
      resolvedExceptionTypes: [
        for (final value in types ?? const <DartObject>[]) ?value.toTypeValue(),
      ],
      exceptionTypes: [
        for (final type in types ?? const <DartObject>[]) _typeName(type),
      ],
      exceptionSupertypes: {
        for (final value in types ?? const <DartObject>[])
          if (value.toTypeValue() case final InterfaceType type)
            _typeName(value): [
              for (final supertype in type.allSupertypes)
                ?supertype.element.name,
            ],
      },
    );
  }
}

String _typeName(DartObject value) =>
    value.toTypeValue()?.element?.name ?? 'Object';
