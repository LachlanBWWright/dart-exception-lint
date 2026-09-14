import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/constant/value.dart';

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

bool _hasDirectExceptionBoundaryAnnotation(Element element) {
  return element.metadata.annotations.any((annotation) {
    final annotatedElement = annotation.element;
    return switch (annotatedElement) {
      ConstructorElement(:final enclosingElement)
          when enclosingElement.name == 'ExceptionBoundary' =>
        true,
      _ => annotatedElement?.name == 'ExceptionBoundary',
    };
  });
}

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
  const ExceptionContract({required this.kind, required this.exceptionTypes});

  final ExceptionContractKind kind;
  final List<String> exceptionTypes;
}

enum ExceptionContractKind { mayThrow, failingFuture, doesNotThrow }

ExceptionContract? exceptionContractFor(Element element) {
  for (final annotation in element.metadata.annotations) {
    final name = switch (annotation.element) {
      ConstructorElement(:final enclosingElement) => enclosingElement.name,
      final annotatedElement? => annotatedElement.name,
      _ => null,
    };
    final kind = switch (name) {
      'MayThrow' => ExceptionContractKind.mayThrow,
      'ReturnsFailingFuture' => ExceptionContractKind.failingFuture,
      'DoesNotThrow' => ExceptionContractKind.doesNotThrow,
      _ => null,
    };
    if (kind == null) continue;
    if (kind == ExceptionContractKind.doesNotThrow) {
      return const ExceptionContract(
        kind: ExceptionContractKind.doesNotThrow,
        exceptionTypes: [],
      );
    }

    final value = annotation.computeConstantValue();
    final types = value?.getField('exceptionTypes')?.toListValue();
    return ExceptionContract(
      kind: kind,
      exceptionTypes: [
        for (final type in types ?? const <DartObject>[]) _typeName(type),
      ],
    );
  }
  return null;
}

String _typeName(DartObject value) => value.type?.element?.name ?? 'Object';
