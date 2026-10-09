import 'package:analyzer/dart/ast/ast.dart';

/// Explicit inventory for analyzer 14.1.0. Analyzed means a model exists,
/// not that the entire construct has been proven free of failure.
enum SyntaxCoverage { structural, analyzed, conservative }

final class SyntaxCoverageInventory {
  static const analyzerVersion = '14.1.0';
  static const nodes = <String, SyntaxCoverage>{
    'AdjacentStrings': SyntaxCoverage.structural,
    'Annotation': SyntaxCoverage.structural,
    'AnonymousBlockBody': SyntaxCoverage.structural,
    'AnonymousExpressionBody': SyntaxCoverage.structural,
    'AnonymousMethodInvocation': SyntaxCoverage.conservative,
    'ArgumentList': SyntaxCoverage.structural,
    'AsExpression': SyntaxCoverage.analyzed,
    'AssertInitializer': SyntaxCoverage.analyzed,
    'AssertStatement': SyntaxCoverage.analyzed,
    'AssignedVariablePattern': SyntaxCoverage.structural,
    'AssignmentExpression': SyntaxCoverage.analyzed,
    'AwaitExpression': SyntaxCoverage.analyzed,
    'BinaryExpression': SyntaxCoverage.analyzed,
    'Block': SyntaxCoverage.structural,
    'BlockClassBody': SyntaxCoverage.structural,
    'BlockEnumBody': SyntaxCoverage.structural,
    'BlockFunctionBody': SyntaxCoverage.structural,
    'BooleanLiteral': SyntaxCoverage.structural,
    'BreakStatement': SyntaxCoverage.structural,
    'CascadeExpression': SyntaxCoverage.structural,
    'CaseClause': SyntaxCoverage.structural,
    'CastPattern': SyntaxCoverage.analyzed,
    'CatchClause': SyntaxCoverage.structural,
    'CatchClauseParameter': SyntaxCoverage.structural,
    'ClassDeclaration': SyntaxCoverage.structural,
    'ClassTypeAlias': SyntaxCoverage.structural,
    'Comment': SyntaxCoverage.structural,
    'CommentReference': SyntaxCoverage.structural,
    'CompilationUnit': SyntaxCoverage.structural,
    'ConditionalExpression': SyntaxCoverage.analyzed,
    'Configuration': SyntaxCoverage.structural,
    'ConstantPattern': SyntaxCoverage.analyzed,
    'ConstructorDeclaration': SyntaxCoverage.structural,
    'ConstructorFieldInitializer': SyntaxCoverage.structural,
    'ConstructorName': SyntaxCoverage.structural,
    'ConstructorReference': SyntaxCoverage.structural,
    'ConstructorSelector': SyntaxCoverage.structural,
    'ContinueStatement': SyntaxCoverage.structural,
    'DeclaredIdentifier': SyntaxCoverage.structural,
    'DeclaredVariablePattern': SyntaxCoverage.structural,
    'DoStatement': SyntaxCoverage.analyzed,
    'DotShorthandInvocation': SyntaxCoverage.conservative,
    'DotShorthandPropertyAccess': SyntaxCoverage.conservative,
    'DottedName': SyntaxCoverage.structural,
    'DoubleLiteral': SyntaxCoverage.structural,
    'EmptyClassBody': SyntaxCoverage.structural,
    'EmptyEnumBody': SyntaxCoverage.structural,
    'EmptyFunctionBody': SyntaxCoverage.structural,
    'EmptyStatement': SyntaxCoverage.structural,
    'EnumConstantArguments': SyntaxCoverage.structural,
    'EnumConstantDeclaration': SyntaxCoverage.structural,
    'EnumDeclaration': SyntaxCoverage.structural,
    'ExportDirective': SyntaxCoverage.structural,
    'ExpressionFunctionBody': SyntaxCoverage.analyzed,
    'ExpressionStatement': SyntaxCoverage.structural,
    'ExtendsClause': SyntaxCoverage.structural,
    'ExtensionDeclaration': SyntaxCoverage.structural,
    'ExtensionOnClause': SyntaxCoverage.structural,
    'ExtensionOverride': SyntaxCoverage.structural,
    'ExtensionTypeDeclaration': SyntaxCoverage.structural,
    'FieldDeclaration': SyntaxCoverage.structural,
    'FieldFormalParameter': SyntaxCoverage.structural,
    'ForEachPartsWithDeclaration': SyntaxCoverage.structural,
    'ForEachPartsWithIdentifier': SyntaxCoverage.structural,
    'ForEachPartsWithPattern': SyntaxCoverage.structural,
    'ForElement': SyntaxCoverage.conservative,
    'ForPartsWithDeclarations': SyntaxCoverage.structural,
    'ForPartsWithExpression': SyntaxCoverage.structural,
    'ForPartsWithPattern': SyntaxCoverage.structural,
    'ForStatement': SyntaxCoverage.analyzed,
    'FormalParameterDefaultClause': SyntaxCoverage.structural,
    'FormalParameterList': SyntaxCoverage.structural,
    'FunctionDeclaration': SyntaxCoverage.structural,
    'FunctionDeclarationStatement': SyntaxCoverage.structural,
    'FunctionExpression': SyntaxCoverage.structural,
    'FunctionExpressionInvocation': SyntaxCoverage.analyzed,
    'FunctionReference': SyntaxCoverage.structural,
    'FunctionTypeAlias': SyntaxCoverage.structural,
    'GenericFunctionType': SyntaxCoverage.structural,
    'GenericTypeAlias': SyntaxCoverage.structural,
    'GuardedPattern': SyntaxCoverage.structural,
    'HideCombinator': SyntaxCoverage.structural,
    'IfElement': SyntaxCoverage.structural,
    'IfStatement': SyntaxCoverage.analyzed,
    'ImplementsClause': SyntaxCoverage.structural,
    'ImplicitCallReference': SyntaxCoverage.structural,
    'ImportDirective': SyntaxCoverage.structural,
    'ImportPrefixReference': SyntaxCoverage.structural,
    'IndexExpression': SyntaxCoverage.analyzed,
    'InstanceCreationExpression': SyntaxCoverage.analyzed,
    'IntegerLiteral': SyntaxCoverage.structural,
    'InterpolationExpression': SyntaxCoverage.analyzed,
    'InterpolationString': SyntaxCoverage.structural,
    'IsExpression': SyntaxCoverage.structural,
    'Label': SyntaxCoverage.structural,
    'LabelReference': SyntaxCoverage.structural,
    'LabeledStatement': SyntaxCoverage.structural,
    'LibraryDirective': SyntaxCoverage.structural,
    'ListLiteral': SyntaxCoverage.analyzed,
    'ListPattern': SyntaxCoverage.conservative,
    'LogicalAndPattern': SyntaxCoverage.structural,
    'LogicalOrPattern': SyntaxCoverage.structural,
    'MapLiteralEntry': SyntaxCoverage.structural,
    'MapPattern': SyntaxCoverage.conservative,
    'MapPatternEntry': SyntaxCoverage.structural,
    'MethodDeclaration': SyntaxCoverage.structural,
    'MethodInvocation': SyntaxCoverage.analyzed,
    'MixinDeclaration': SyntaxCoverage.structural,
    'MixinOnClause': SyntaxCoverage.structural,
    'NameWithTypeParameters': SyntaxCoverage.structural,
    'NamedArgument': SyntaxCoverage.structural,
    'NamedType': SyntaxCoverage.structural,
    'NativeClause': SyntaxCoverage.structural,
    'NativeFunctionBody': SyntaxCoverage.structural,
    'NullAssertPattern': SyntaxCoverage.analyzed,
    'NullAwareElement': SyntaxCoverage.structural,
    'NullCheckPattern': SyntaxCoverage.structural,
    'NullLiteral': SyntaxCoverage.structural,
    'ObjectPattern': SyntaxCoverage.analyzed,
    'ParenthesizedExpression': SyntaxCoverage.structural,
    'ParenthesizedPattern': SyntaxCoverage.structural,
    'PartDirective': SyntaxCoverage.structural,
    'PartOfDirective': SyntaxCoverage.structural,
    'PatternAssignment': SyntaxCoverage.conservative,
    'PatternField': SyntaxCoverage.analyzed,
    'PatternFieldName': SyntaxCoverage.structural,
    'PatternVariableDeclaration': SyntaxCoverage.conservative,
    'PostfixExpression': SyntaxCoverage.analyzed,
    'PrefixExpression': SyntaxCoverage.analyzed,
    'PrefixedIdentifier': SyntaxCoverage.analyzed,
    'PrimaryConstructorBody': SyntaxCoverage.conservative,
    'PrimaryConstructorDeclaration': SyntaxCoverage.conservative,
    'PrimaryConstructorName': SyntaxCoverage.structural,
    'PropertyAccess': SyntaxCoverage.analyzed,
    'RecordLiteral': SyntaxCoverage.structural,
    'RecordLiteralNamedField': SyntaxCoverage.structural,
    'RecordPattern': SyntaxCoverage.structural,
    'RecordTypeAnnotation': SyntaxCoverage.structural,
    'RecordTypeAnnotationNamedField': SyntaxCoverage.structural,
    'RegularFormalParameter': SyntaxCoverage.structural,
    'RelationalPattern': SyntaxCoverage.analyzed,
    'RestPatternElement': SyntaxCoverage.structural,
    'RethrowExpression': SyntaxCoverage.analyzed,
    'ReturnStatement': SyntaxCoverage.analyzed,
    'ScriptTag': SyntaxCoverage.structural,
    'SetOrMapLiteral': SyntaxCoverage.conservative,
    'ShowCombinator': SyntaxCoverage.structural,
    'SimpleIdentifier': SyntaxCoverage.analyzed,
    'SimpleStringLiteral': SyntaxCoverage.structural,
    'SpreadElement': SyntaxCoverage.conservative,
    'StringInterpolation': SyntaxCoverage.structural,
    'SuperConstructorInvocation': SyntaxCoverage.conservative,
    'SuperExpression': SyntaxCoverage.structural,
    'SuperFormalParameter': SyntaxCoverage.structural,
    'SwitchCase': SyntaxCoverage.structural,
    'SwitchDefault': SyntaxCoverage.structural,
    'SwitchExpression': SyntaxCoverage.analyzed,
    'SwitchExpressionCase': SyntaxCoverage.structural,
    'SwitchPatternCase': SyntaxCoverage.structural,
    'SwitchStatement': SyntaxCoverage.analyzed,
    'SymbolLiteral': SyntaxCoverage.structural,
    'ThisExpression': SyntaxCoverage.structural,
    'ThrowExpression': SyntaxCoverage.analyzed,
    'TopLevelVariableDeclaration': SyntaxCoverage.structural,
    'TryStatement': SyntaxCoverage.analyzed,
    'TypeArgumentList': SyntaxCoverage.structural,
    'TypeLiteral': SyntaxCoverage.structural,
    'TypeParameter': SyntaxCoverage.structural,
    'TypeParameterList': SyntaxCoverage.structural,
    'VariableDeclaration': SyntaxCoverage.analyzed,
    'VariableDeclarationList': SyntaxCoverage.structural,
    'VariableDeclarationStatement': SyntaxCoverage.structural,
    'WhenClause': SyntaxCoverage.structural,
    'WhileStatement': SyntaxCoverage.analyzed,
    'WildcardPattern': SyntaxCoverage.structural,
    'WithClause': SyntaxCoverage.structural,
    'YieldStatement': SyntaxCoverage.analyzed,
    'DotShorthandConstructorInvocation': SyntaxCoverage.conservative,
    'FunctionTypedFormalParameterSuffix': SyntaxCoverage.structural,
    'PatternVariableDeclarationStatement': SyntaxCoverage.structural,
    'RecordTypeAnnotationNamedFields': SyntaxCoverage.structural,
    'RecordTypeAnnotationPositionalField': SyntaxCoverage.structural,
    'RedirectingConstructorInvocation': SyntaxCoverage.conservative,
  };

  static String kind(AstNode node) =>
      node.runtimeType.toString().replaceAll('Impl', '');

  static bool requiresUnknown(AstNode node) {
    final coverage = nodes[kind(node)];
    if (coverage == null) return true;
    if (coverage != SyntaxCoverage.conservative) return false;
    // Literal primitive patterns compare with SDK implementations. A failed
    // match is normal control flow and does not itself throw.
    if (node is ConstantPattern && node.expression is Literal) return false;
    // A compile-time constant collection has no runtime insertion/cast effect.
    if (node is ListLiteral && node.constKeyword != null) return false;
    if (node is SetOrMapLiteral) {
      if (node.constKeyword != null) return false;
      bool primitive(Expression expression) => const {
        'int',
        'double',
        'String',
        'bool',
        'Null',
      }.contains(expression.staticType?.getDisplayString());
      if (node.elements.every(
        (element) => element is MapLiteralEntry
            ? primitive(element.key)
            : element is Expression && primitive(element),
      )) {
        return false;
      }
    }
    if (node is SetOrMapLiteral &&
        node.elements.whereType<SpreadElement>().any(
          (element) =>
              element.expression.staticType?.getDisplayString() == 'dynamic',
        )) {
      return false;
    }
    if (node is SpreadElement &&
        node.expression.staticType?.getDisplayString() == 'dynamic') {
      return false;
    }
    if (node.thisOrAncestorOfType<Annotation>() != null) return false;
    return true;
  }
}
