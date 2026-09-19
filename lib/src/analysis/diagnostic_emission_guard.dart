import 'package:analyzer/dart/ast/ast.dart';

/// Prevents a single rule from emitting duplicate diagnostics for the same
/// source span when several registered AST callbacks observe one operation.
///
/// The guard is intentionally scoped to one visitor. Different diagnostics
/// may still report the same operation when they represent different policy
/// decisions (for example, a configured API and an inferred source).
final class DiagnosticEmissionGuard {
  final Set<String> _claims = <String>{};

  bool claim(AstNode node) {
    return _claims.add('${node.offset}:${node.end}');
  }
}
