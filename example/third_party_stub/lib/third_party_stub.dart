import 'dart:convert';

class DangerousClient {
  DangerousClient();
  DangerousClient.named();

  static String load() => jsonDecode('not json') as String;

  String fetch() => _decode('not json');
}

String _decode(String input) => jsonDecode(input) as String;

String dangerousTopLevel() => throw Exception('boom');

Future<String> dangerousAsync() => Future.error(Exception('boom'));
