import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/dart/element/type.dart';

import '../analysis/throw_protection.dart';
import '../analysis/exception_type_labels.dart';
import '../analysis/diagnostic_emission_guard.dart';
import '../analysis/throw_source_catalog.dart';
import '../analysis/throw_summary.dart';
import '../engine/runtime_checks.dart';
import '../engine/effect_containment.dart';
import '../config/exception_analysis_options.dart';
import '../diagnostics.dart';
import '../engine/exception_analysis_service.dart';
import '../utils/source_utils.dart';

class CatchRuntimeThrowSourcesRule extends AnalysisRule {
  CatchRuntimeThrowSourcesRule()
    : super(
        name:
            DartExceptionLintDiagnostics.catchRuntimeThrowSources.lowerCaseName,
        description: 'Reports known runtime throw sources outside try/catch.',
      );

  @override
  LintCode get diagnosticCode =>
      DartExceptionLintDiagnostics.catchRuntimeThrowSources;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    final options = ExceptionAnalysisService.forContext(context).options;
    if (shouldSkipLintRuleForFile(
      ruleName: name,
      options: options,
      filePath: context.definingUnit.file.path,
      packageRoot: context.package?.root.path,
    )) {
      return;
    }

    final visitor = _Visitor(this, options);
    registry.addMethodInvocation(this, visitor);
    registry.addFunctionExpressionInvocation(this, visitor);
    registry.addInstanceCreationExpression(this, visitor);
    registry.addIndexExpression(this, visitor);
    registry.addAsExpression(this, visitor);
    registry.addCastPattern(this, visitor);
    registry.addNullAssertPattern(this, visitor);
    registry.addRelationalPattern(this, visitor);
    registry.addBinaryExpression(this, visitor);
    registry.addSimpleIdentifier(this, visitor);
    registry.addAssertStatement(this, visitor);
    registry.addListLiteral(this, visitor);
    registry.addSetOrMapLiteral(this, visitor);
    registry.addVariableDeclaration(this, visitor);
    registry.addAssignmentExpression(this, visitor);
    registry.addArgumentList(this, visitor);
    registry.addReturnStatement(this, visitor);
    registry.addExpressionFunctionBody(this, visitor);
  }
}

final class _Visitor extends SimpleAstVisitor<void> {
  _Visitor(this.rule, this.options);

  final AnalysisRule rule;
  final ExceptionAnalysisOptions options;
  final DiagnosticEmissionGuard _emissions = DiagnosticEmissionGuard();

  @override
  void visitRelationalPattern(RelationalPattern node) {
    _recordImplicitCast(
      node.operand,
      node.element?.formalParameters.firstOrNull?.type,
    );
  }

  @override
  void visitCastPattern(CastPattern node) {
    if (!options.treatAsCastsAsThrowing) return;
    final source = RuntimeChecks.castPattern(node);
    if (source != null) {
      _report(
        node,
        node.type,
        source.displayName,
        source.exceptionTypes,
        source: source,
      );
    }
  }

  @override
  void visitNullAssertPattern(NullAssertPattern node) {
    final source = RuntimeChecks.nullAssertPattern(node);
    if (source != null) {
      _report(
        node,
        node,
        source.displayName,
        source.exceptionTypes,
        source: source,
      );
    }
  }

  @override
  void visitAsExpression(AsExpression node) {
    final library = node
        .thisOrAncestorOfType<CompilationUnit>()
        ?.declaredFragment
        ?.element;
    final sourceType = node.expression.staticType;
    final targetType = node.type.type;
    if (library != null &&
        sourceType != null &&
        targetType != null &&
        library.typeSystem.isSubtypeOf(sourceType, targetType)) {
      return;
    }
    final source = ThrowSourceCatalog.matchAsExpression(node, options);
    if (source == null ||
        !source.confidence.isThrowing ||
        source.confidence.isAsync) {
      return;
    }
    _report(
      node,
      node.type,
      source.displayName,
      source.exceptionTypes,
      source: source,
    );
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    final source = ThrowSourceCatalog.matchResolvedInvocation(
      node,
      node.element,
      options,
    );
    if (source == null ||
        !source.confidence.isThrowing ||
        source.confidence.isAsync) {
      return;
    }
    _report(
      node,
      node.function,
      source.displayName,
      source.exceptionTypes,
      source: source,
    );
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final source = ThrowSourceCatalog.matchResolvedInvocation(
      node,
      node.constructorName.element,
      options,
    );
    if (source == null ||
        !source.confidence.isThrowing ||
        source.confidence.isAsync) {
      return;
    }
    _report(
      node,
      node.constructorName,
      source.displayName,
      source.exceptionTypes,
    );
  }

  @override
  void visitIndexExpression(IndexExpression node) {
    final source = ThrowSourceCatalog.matchIndexAccess(node, options);
    if (source == null ||
        !source.confidence.isThrowing ||
        source.confidence.isAsync) {
      return;
    }
    _report(
      node,
      node,
      source.displayName,
      source.exceptionTypes,
      source: source,
    );
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final source = ThrowSourceCatalog.matchResolvedInvocation(
      node,
      node.methodName.element,
      options,
    );
    if (source == null ||
        !source.confidence.isThrowing ||
        source.confidence.isAsync) {
      return;
    }
    _report(
      node,
      node.methodName,
      source.displayName,
      source.exceptionTypes,
      source: source,
    );
  }

  @override
  void visitBinaryExpression(BinaryExpression node) {
    final source = ThrowSourceCatalog.matchBinaryExpression(node, options);
    if (source == null || !source.confidence.isThrowing) return;
    _report(
      node,
      node,
      source.displayName,
      source.exceptionTypes,
      source: source,
    );
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final source = ThrowSourceCatalog.matchLateInitializationRead(
      node,
      options,
    );
    if (source == null || !source.confidence.isThrowing) return;
    _report(
      node,
      node,
      source.displayName,
      source.exceptionTypes,
      source: source,
    );
  }

  @override
  void visitAssertStatement(AssertStatement node) {
    final source = ThrowSourceCatalog.matchAssertStatement(node);
    _report(
      node,
      node.condition,
      source.displayName,
      source.exceptionTypes,
      source: source,
    );
  }

  void _recordImplicitCast(Expression expression, DartType? target) {
    if (!options.treatAsCastsAsThrowing) return;
    final source = RuntimeChecks.implicitCast(expression, target);
    if (source != null &&
        !isProtectedByCatch(
          expression,
          exceptionTypes: source.exceptionTypes,
        )) {
      _report(
        expression,
        expression,
        source.displayName,
        source.exceptionTypes,
      );
    }
  }

  @override
  void visitListLiteral(ListLiteral node) {
    final type = node.staticType;
    if (type is InterfaceType && type.typeArguments.isNotEmpty) {
      for (final element in node.elements.whereType<Expression>()) {
        _recordImplicitCast(element, type.typeArguments.first);
      }
    }
    super.visitListLiteral(node);
  }

  @override
  void visitSetOrMapLiteral(SetOrMapLiteral node) {
    final type = node.staticType;
    if (type is InterfaceType && type.typeArguments.isNotEmpty) {
      for (final element in node.elements) {
        if (element is MapLiteralEntry && type.typeArguments.length == 2) {
          _recordImplicitCast(element.key, type.typeArguments.first);
          _recordImplicitCast(element.value, type.typeArguments.last);
        } else if (element is Expression) {
          _recordImplicitCast(element, type.typeArguments.first);
        }
      }
    }
    super.visitSetOrMapLiteral(node);
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    final initializer = node.initializer;
    if (initializer != null) {
      _recordImplicitCast(initializer, node.declaredFragment?.element.type);
    }
    super.visitVariableDeclaration(node);
  }

  @override
  void visitArgumentList(ArgumentList node) {
    for (final argument in node.arguments) {
      final value = argument.argumentExpression;
      _recordImplicitCast(value, argument.correspondingParameter?.type);
      final source = RuntimeChecks.covarianceCheck(
        value,
        argument.correspondingParameter,
      );
      if (source != null && options.treatAsCastsAsThrowing) {
        _report(
          value,
          value,
          source.displayName,
          source.exceptionTypes,
          source: source,
        );
      }
    }
    super.visitArgumentList(node);
  }

  @override
  void visitReturnStatement(ReturnStatement node) {
    if (node.expression case final expression?) {
      _recordImplicitCast(expression, RuntimeChecks.returnType(node));
    }
    super.visitReturnStatement(node);
  }

  @override
  void visitExpressionFunctionBody(ExpressionFunctionBody node) {
    _recordImplicitCast(node.expression, RuntimeChecks.returnType(node));
    super.visitExpressionFunctionBody(node);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    _recordImplicitCast(node.rightHandSide, node.writeType);
    final source = ThrowSourceCatalog.matchAssignmentExpression(node, options);
    if (source != null && source.confidence.isThrowing) {
      _report(
        node,
        node,
        source.displayName,
        source.exceptionTypes,
        source: source,
      );
    }
  }

  void _report(
    AstNode node,
    AstNode diagnosticTarget,
    String displayName,
    List<String> exceptionTypes, {
    ThrowSource? source,
  }) {
    final effect =
        source ??
        ThrowSource(
          kind: ThrowSourceKind.inferredCall,
          confidence: ThrowConfidence.possibleThrow,
          displayName: displayName,
          exceptionTypes: exceptionTypes,
        );
    if (isEffectContained(node, effect)) return;

    if (_emissions.claim(diagnosticTarget)) {
      rule.reportAtNode(
        diagnosticTarget,
        arguments: [displayName, exceptionTypeLabel(exceptionTypes)],
      );
    }
  }
}
