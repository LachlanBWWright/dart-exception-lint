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
import '../engine/exception_analysis_service.dart';

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
    registry.addCompilationUnit(
      this,
      _Visitor(this, ExceptionAnalysisService.forContext(context)),
    );
  }
}

final class _Visitor extends RecursiveAstVisitor<void> {
  _Visitor(this.rule, this.service);

  final AnalysisRule rule;
  final ExceptionAnalysisService service;

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
    final contracts = exceptionContractsFor(element).toList();
    final inherited = _inheritedContracts(element).toList();
    if (contracts.isEmpty && inherited.isEmpty) return;

    for (final contract in contracts) {
      if (contract.kind == ExceptionContractKind.mayThrow &&
          element.firstFragment.isAsynchronous) {
        _report(
          node,
          'MayThrow describes synchronous failures; an async body returns failures asynchronously',
        );
        return;
      }
      if (contract.kind == ExceptionContractKind.failingFuture &&
          !_returnsAsyncValue(element)) {
        _report(
          node,
          'ReturnsFailingFuture requires a Future or Stream return',
        );
        return;
      }
    }

    final promisesNoEffects = [
      ...contracts,
      ...inherited,
    ].any((contract) => contract.kind == ExceptionContractKind.doesNotThrow);
    if (promisesNoEffects && !element.isAbstract && !element.isExternal) {
      final summary = service.analyzer.summarizeImplementation(element);
      if (summary.hasAnyThrowSource || !summary.complete) {
        _report(
          node,
          inherited.any(
                (contract) =>
                    contract.kind == ExceptionContractKind.doesNotThrow,
              )
              ? 'override violates inherited DoesNotThrow contract'
              : 'DoesNotThrow has escaping or unverified implementation effects',
        );
        return;
      }
    }
    if (inherited.any(
          (contract) => contract.kind == ExceptionContractKind.doesNotThrow,
        ) &&
        contracts.any(
          (contract) => contract.kind != ExceptionContractKind.doesNotThrow,
        )) {
      _report(
        node,
        'override adds failures to inherited DoesNotThrow contract',
      );
      return;
    }

    final contractNames = element.metadata.annotations
        .map(exceptionAnnotationName)
        .where(
          (name) =>
              name == 'MayThrow' ||
              name == 'ReturnsFailingFuture' ||
              name == 'DoesNotThrow',
        )
        .toList();
    if (contractNames.toSet().length != contractNames.length ||
        (contractNames.contains('DoesNotThrow') && contractNames.length > 1)) {
      _report(node, 'duplicate or contradictory exception contracts');
    }
  }

  Iterable<ExceptionContract> _inheritedContracts(
    ExecutableElement element,
  ) sync* {
    final owner = element.enclosingElement;
    if (element.isStatic || owner is! InterfaceElement) return;
    final name = element.name;
    if (name == null) return;
    for (final supertype in owner.allSupertypes) {
      final member = switch (element) {
        MethodElement() => supertype.element.getMethod(name),
        GetterElement() => supertype.element.getGetter(name),
        SetterElement() => supertype.element.getSetter(name),
        _ => null,
      };
      if (member != null) yield* exceptionContractsFor(member);
    }
  }

  bool _returnsAsyncValue(ExecutableElement element) {
    final type = element.returnType;
    return type is InterfaceType &&
        (type.isDartAsyncFuture ||
            type.isDartAsyncFutureOr ||
            (type.element.name == 'Stream' &&
                type.element.library.uri.toString() == 'dart:async'));
  }

  void _report(AstNode node, String message) {
    rule.reportAtNode(node, arguments: [message]);
  }
}
