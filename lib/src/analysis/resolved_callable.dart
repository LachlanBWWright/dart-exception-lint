import 'package:analyzer/dart/element/element.dart';

enum CallableKind {
  topLevelFunction,
  instanceMethod,
  staticMethod,
  constructor,
  getter,
  setter,
}

final class ResolvedCallable {
  ResolvedCallable({
    required this.packageName,
    required this.libraryUri,
    required this.callableName,
    required this.kind,
    required this.isStatic,
    this.enclosingClassName,
    this.constructorName,
    required this.supertypeKeys,
  });

  final String packageName;
  final String libraryUri;
  final String callableName;
  final CallableKind kind;
  final bool isStatic;
  final String? enclosingClassName;
  final String? constructorName;
  final Set<String> supertypeKeys;

  String get elementKey {
    final classSegment = enclosingClassName == null
        ? ''
        : '$enclosingClassName.';
    final constructorSegment = constructorName == null
        ? ''
        : '#$constructorName';
    return '$libraryUri::$classSegment$callableName$constructorSegment';
  }

  static ResolvedCallable? tryCreate(Element? element) {
    switch (element) {
      case TopLevelFunctionElement():
        final sourceUri = _libraryUriFor(element);
        final packageName = _packageNameFromUri(sourceUri);
        final callableName = element.name;
        if (packageName == null || callableName == null) {
          return null;
        }
        return ResolvedCallable(
          packageName: packageName,
          libraryUri: sourceUri.toString(),
          callableName: callableName,
          kind: CallableKind.topLevelFunction,
          isStatic: true,
          supertypeKeys: const {},
        );
      case ConstructorElement():
        final sourceUri = _libraryUriFor(element);
        final packageName = _packageNameFromUri(sourceUri);
        final enclosingElement = element.enclosingElement;
        final className = enclosingElement.name;
        if (packageName == null || className == null) {
          return null;
        }
        return ResolvedCallable(
          packageName: packageName,
          libraryUri: sourceUri.toString(),
          callableName: className,
          kind: CallableKind.constructor,
          isStatic: true,
          enclosingClassName: className,
          constructorName: element.name,
          supertypeKeys: _supertypeKeys(enclosingElement),
        );
      case MethodElement():
        final sourceUri = _libraryUriFor(element);
        final packageName = _packageNameFromUri(sourceUri);
        final callableName = element.name;
        if (packageName == null || callableName == null) {
          return null;
        }
        final enclosingElement = element.enclosingElement;
        return ResolvedCallable(
          packageName: packageName,
          libraryUri: sourceUri.toString(),
          callableName: callableName,
          kind: element.isStatic
              ? CallableKind.staticMethod
              : CallableKind.instanceMethod,
          isStatic: element.isStatic,
          enclosingClassName: enclosingElement is InterfaceElement
              ? enclosingElement.name
              : null,
          supertypeKeys: enclosingElement is InterfaceElement
              ? _supertypeKeys(enclosingElement)
              : const {},
        );
      case PropertyAccessorElement():
        final sourceUri = _libraryUriFor(element);
        final packageName = _packageNameFromUri(sourceUri);
        final callableName = element.name;
        if (packageName == null || callableName == null) {
          return null;
        }
        final enclosingElement = element.enclosingElement;
        return ResolvedCallable(
          packageName: packageName,
          libraryUri: sourceUri.toString(),
          callableName: callableName,
          kind: element is SetterElement
              ? CallableKind.setter
              : CallableKind.getter,
          isStatic: element.isStatic,
          enclosingClassName: enclosingElement is InterfaceElement
              ? enclosingElement.name
              : null,
          supertypeKeys: enclosingElement is InterfaceElement
              ? _supertypeKeys(enclosingElement)
              : const {},
        );
      default:
        return null;
    }
  }

  static Uri _libraryUriFor(Element element) {
    return element.library!.firstFragment.source.uri;
  }

  static String? _packageNameFromUri(Uri uri) {
    if (uri.scheme != 'package' || uri.pathSegments.isEmpty) {
      return null;
    }
    return uri.pathSegments.first;
  }

  static Set<String> _supertypeKeys(InterfaceElement element) {
    return {
      for (final type in element.allSupertypes)
        if (type.element.name case final name?)
          '${type.element.library.firstFragment.source.uri}::$name',
    };
  }
}
