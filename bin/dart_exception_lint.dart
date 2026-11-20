import 'dart:io';

import 'package:dart_exception_lint/src/cli/command.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runCommand(arguments, stdout, stderr);
}
