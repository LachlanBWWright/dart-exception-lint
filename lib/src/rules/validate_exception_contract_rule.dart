import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/error.dart';

import '../analysis/exception_annotations.dart';
import '../diagnostics.dart';

/// Validates optional public contracts without making them required. This is
/// deliberately separate from inference: a missing annotation is valid, but
/// an annotation that contradicts the declaration should be visible.
class ValidateExceptionContractRule extends AnalysisRule {
  ValidateExceptionContractRule()
    : super(
        name:
            DartExceptionLintDiagnostics.invalidExceptionContract.lowerCaseName,
        description: 'Reports contradictory or malformed exception contracts.',
      );

  @override
  LintCode get diagnosticCode =>
      DartExceptionLintDiagnostics.invalidExceptionContract;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    registry.addCompilationUnit(this, _Visitor(this));
  }
}

final class _Visitor extends RecursiveAstVisitor<void> {
  _Visitor(this.rule);

  final AnalysisRule rule;

  @override
  void visitCompilationUnit(CompilationUnit node) {
    node.visitChildren(this);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    _check(node, node.declaredFragment?.element);
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    _check(node, node.declaredFragment?.element);
    super.visitMethodDeclaration(node);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    _check(node, node.declaredFragment?.element);
    super.visitConstructorDeclaration(node);
  }

  void _check(AstNode node, ExecutableElement? element) {
    if (element == null) return;
    final contract = exceptionContractFor(element);
    if (contract == null) return;

    final returnsAsyncValue = _returnsAsyncValue(element);
    if (contract.kind == ExceptionContractKind.mayThrow && returnsAsyncValue) {
      _report(node, 'MayThrow cannot describe a Future or Stream result');
      return;
    }

    if (contract.kind == ExceptionContractKind.failingFuture &&
        !returnsAsyncValue) {
      _report(node, 'ReturnsFailingFuture requires a Future or Stream return');
      return;
    }

    if (contract.kind == ExceptionContractKind.doesNotThrow &&
        _containsDirectThrow(node)) {
      _report(node, 'DoesNotThrow contradicts an explicit throw or rethrow');
      return;
    }

    final contractNames = element.metadata.annotations
        .map((annotation) => annotation.element?.name)
        .where(
          (name) =>
              name == 'MayThrow' ||
              name == 'ReturnsFailingFuture' ||
              name == 'DoesNotThrow',
        )
        .length;
    if (contractNames > 1) {
      _report(node, 'only one exception contract may be declared');
    }
  }

  bool _returnsAsyncValue(ExecutableElement element) {
    final type = element.returnType;
    return type is InterfaceType &&
        (type.element.name == 'Future' || type.element.name == 'Stream');
  }

  bool _containsDirectThrow(AstNode node) {
    final visitor = _DirectThrowVisitor();
    switch (node) {
      case FunctionDeclaration(:final functionExpression):
        functionExpression.body.accept(visitor);
      case MethodDeclaration(:final body):
        body.accept(visitor);
      case ConstructorDeclaration(:final body):
        body.accept(visitor);
      default:
        return false;
    }
    return visitor.found;
  }

  void _report(AstNode node, String message) {
    rule.reportAtNode(node, arguments: [message]);
  }
}

/// Finds throws belonging to the declared callable while deliberately not
/// descending into nested closures or local function declarations. A nested
/// callback executes under a different ownership boundary and must not make a
/// containing `@DoesNotThrow` declaration invalid by itself.
final class _DirectThrowVisitor extends RecursiveAstVisitor<void> {
  bool found = false;

  @override
  void visitThrowExpression(ThrowExpression node) {
    found = true;
  }

  @override
  void visitRethrowExpression(RethrowExpression node) {
    found = true;
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {
    // Nested closures are separate execution units.
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    // Local function declarations are separate execution units.
  }
}
