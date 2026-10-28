import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Exercises the installed plugin through the Analysis Server's LSP transport,
/// including unsaved dependency overlays. The source files on disk stay safe.
Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp('exception-ide-');
  _LspClient? client;
  try {
    final plugin = Directory.current.absolute.path;
    await File(
      '${directory.path}/pubspec.yaml',
    ).writeAsString('name: ide_consumer\nenvironment:\n  sdk: ^3.11.0\n');
    await File('${directory.path}/analysis_options.yaml').writeAsString(
      'plugins:\n  dart_exception_lint:\n    path: ${jsonEncode(plugin)}\n',
    );
    final mainFile = File('${directory.path}/lib/main.dart');
    final wrapper = File('${directory.path}/lib/wrapper.dart');
    final dependency = File('${directory.path}/lib/dependency.dart');
    await mainFile.parent.create(recursive: true);
    // Always-present plugin diagnostics prove that the plugin has finished
    // analyzing both files before edits begin. Native analyzer idle events can
    // precede cold plugin compilation and are not a plugin readiness signal.
    const probe = 'void pluginProbe() { throw 0; }\n';
    const mainSource =
        "import 'wrapper.dart';\nint caller() => bridge();\n$probe";
    const safeSource = 'int value() => 1;\n$probe';
    const throwingSource = "int value() => throw 'failure';\n$probe";
    await mainFile.writeAsString(mainSource);
    await wrapper.writeAsString(
      "import 'dependency.dart';\nint bridge() => value();\n",
    );
    await dependency.writeAsString(safeSource);
    final pub = await Process.run(Platform.resolvedExecutable, [
      'pub',
      'get',
    ], workingDirectory: directory.path);
    if (pub.exitCode != 0) {
      throw StateError('Consumer resolution: ${pub.stderr}');
    }
    client = _LspClient(
      await Process.start(Platform.resolvedExecutable, [
        'language-server',
        '--protocol=lsp',
        '--client-id=exception-ide-smoke',
      ], workingDirectory: directory.path),
    );
    await client.request('initialize', {
      'processId': pid,
      'rootUri': directory.uri.toString(),
      'capabilities': <String, Object>{},
    });
    client.notify('initialized', {});
    client.open(mainFile.uri, mainSource);
    client.open(dependency.uri, safeSource);
    await client.diagnostics(mainFile.uri, throwing: false);
    await client.diagnostics(dependency.uri, throwing: false);
    var since = client.events.length;
    client.change(dependency.uri, throwingSource, 2);
    await client.diagnostics(mainFile.uri, throwing: true, since: since);
    since = client.events.length;
    client.change(dependency.uri, safeSource, 3);
    await client.diagnostics(mainFile.uri, throwing: false, since: since);
    if (await dependency.readAsString() != safeSource) {
      throw StateError('Overlay test unexpectedly changed disk contents');
    }
    stdout.writeln(
      'LSP consumer: safe → unsaved throwing dependency → safe diagnostics match.',
    );
  } finally {
    await client?.close();
    await directory.delete(recursive: true);
  }
}

final class _LspClient {
  _LspClient(this.process) {
    process.stdout.listen(_read);
    process.stderr.transform(utf8.decoder).listen(_stderr.write);
  }

  final Process process;
  final _stderr = StringBuffer();
  final _pending = <int, Completer<Object?>>{};
  final events = <Map<String, dynamic>>[];
  final _notifications = StreamController<Map<String, dynamic>>.broadcast();
  final _buffer = <int>[];
  var _id = 0;

  void _send(Map<String, Object?> message) {
    final bytes = utf8.encode(jsonEncode({'jsonrpc': '2.0', ...message}));
    process.stdin.add(ascii.encode('Content-Length: ${bytes.length}\r\n\r\n'));
    process.stdin.add(bytes);
  }

  Future<Object?> request(String method, Object? params) {
    final id = ++_id;
    final response = _pending[id] = Completer<Object?>();
    _send({'id': id, 'method': method, 'params': params});
    return response.future.timeout(
      const Duration(seconds: 90),
      onTimeout: () {
        throw StateError('LSP $method timed out: $_stderr');
      },
    );
  }

  void notify(String method, Object? params) =>
      _send({'method': method, 'params': params});

  void open(Uri uri, String source) => notify('textDocument/didOpen', {
    'textDocument': {
      'uri': uri.toString(),
      'languageId': 'dart',
      'version': 1,
      'text': source,
    },
  });

  void change(Uri uri, String source, int version) =>
      notify('textDocument/didChange', {
        'textDocument': {'uri': uri.toString(), 'version': version},
        'contentChanges': [
          {'text': source},
        ],
      });

  Future<void> diagnostics(
    Uri uri, {
    required bool throwing,
    int since = 0,
  }) async {
    bool matches(Map<String, dynamic> message) {
      if (message['method'] != 'textDocument/publishDiagnostics') return false;
      final params = message['params'] as Map;
      if (params['uri'] != uri.toString()) return false;
      final diagnostics = (params['diagnostics'] as List).cast<Map>();
      if (!diagnostics.any(
        (diagnostic) => '${diagnostic['code']}' == 'no_manual_throw',
      )) {
        return false;
      }
      final found = diagnostics.any(
        (diagnostic) =>
            '${diagnostic['code']}'.contains('catch_inferred_throwing_calls'),
      );
      return found == throwing;
    }

    if (events.skip(since).any(matches)) return;
    await _notifications.stream
        .firstWhere(matches)
        .timeout(
          const Duration(seconds: 90),
          onTimeout: () {
            throw StateError(
              'LSP expected throwing=$throwing for $uri; '
              'events: ${jsonEncode(events.skip(since).toList())}; stderr: $_stderr',
            );
          },
        );
  }

  void _read(List<int> bytes) {
    _buffer.addAll(bytes);
    while (true) {
      var end = -1;
      for (var index = 0; index + 3 < _buffer.length; index++) {
        if (_buffer[index] == 13 &&
            _buffer[index + 1] == 10 &&
            _buffer[index + 2] == 13 &&
            _buffer[index + 3] == 10) {
          end = index;
          break;
        }
      }
      if (end < 0) return;
      final header = ascii.decode(_buffer.sublist(0, end));
      final length = int.parse(
        RegExp(
          r'Content-Length: (\d+)',
          caseSensitive: false,
        ).firstMatch(header)!.group(1)!,
      );
      if (_buffer.length < end + 4 + length) return;
      final message =
          jsonDecode(utf8.decode(_buffer.sublist(end + 4, end + 4 + length)))
              as Map<String, dynamic>;
      _buffer.removeRange(0, end + 4 + length);
      if (message.containsKey('method')) {
        if (message.containsKey('id')) {
          final result = message['method'] == 'workspace/configuration'
              ? List<Object?>.filled(
                  ((message['params'] as Map)['items'] as List).length,
                  null,
                )
              : null;
          _send({'id': message['id'], 'result': result});
        } else {
          events.add(message);
          _notifications.add(message);
        }
      } else {
        final pending = _pending.remove(message['id']);
        if (message.containsKey('error')) {
          pending?.completeError(StateError('${message['error']}'));
        } else {
          pending?.complete(message['result']);
        }
      }
    }
  }

  Future<void> close() async {
    try {
      await request('shutdown', null).timeout(const Duration(seconds: 5));
      notify('exit', null);
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      process.kill();
      await process.exitCode;
    } finally {
      await process.stdin.close();
      await _notifications.close();
    }
  }
}
