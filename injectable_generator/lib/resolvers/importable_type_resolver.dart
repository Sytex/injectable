import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:collection/collection.dart';
import 'package:injectable_generator/models/importable_type.dart';
import 'package:injectable_generator/utils.dart';
import 'package:path/path.dart' as p;

abstract class ImportableTypeResolver {
  Set<String> resolveImports(Element element);

  ImportableType resolveType(DartType type);

  ImportableType resolveFunctionType(
    FunctionType function, [
    ExecutableElement? executableElement,
  ]);

  static String? relative(String? path, Uri? to) {
    if (path == null || to == null) {
      return null;
    }
    var fileUri = Uri.parse(path);
    var libName = to.pathSegments.first;
    if ((to.scheme == 'package' &&
            fileUri.scheme == 'package' &&
            fileUri.pathSegments.first == libName) ||
        (to.scheme == 'asset' && fileUri.scheme != 'package')) {
      if (fileUri.path == to.path) {
        return fileUri.pathSegments.last;
      } else {
        return p.posix
            .relative(fileUri.path, from: to.path)
            .replaceFirst('../', '');
      }
    } else {
      return path;
    }
  }

  static String? resolveAssetImport(String? path) {
    if (path == null) {
      return null;
    }
    var fileUri = Uri.parse(path);
    if (fileUri.scheme == "asset") {
      return "/${fileUri.path}";
    }
    return path;
  }
}

class ImportableTypeResolverImpl extends ImportableTypeResolver {
  final List<LibraryElement> libs;

  ImportableTypeResolverImpl(this.libs);

  @override
  Set<String> resolveImports(Element? element) {
    final imports = <String>{};

    final elementLibrary = element?.library;
    if (elementLibrary == null || elementLibrary.isDartCore) {
      return imports;
    }

    for (var lib in libs) {
      if (_isBarrelFile(lib)) continue;
      if (lib.isDartCore) continue;
      final libExportsElement = lib.exportNamespace.definedNames2.values
          .contains(element);
      if (!libExportsElement) continue;
      imports.add(lib.uri.toString());
    }

    return imports;
  }

  bool _isBarrelFile(LibraryElement lib) {
    final hasExports = lib.firstFragment.libraryExports.isNotEmpty;
    if (!hasExports) return false;

    // Check if library has any of its own top-level declarations
    // A barrel file re-exports but doesn't declare its own elements
    final hasOwnDeclarations =
        lib.classes.isNotEmpty ||
        lib.enums.isNotEmpty ||
        lib.extensions.isNotEmpty ||
        lib.extensionTypes.isNotEmpty ||
        lib.mixins.isNotEmpty ||
        lib.typeAliases.isNotEmpty ||
        lib.topLevelFunctions.isNotEmpty ||
        lib.topLevelVariables.isNotEmpty;

    return hasExports && !hasOwnDeclarations;
  }

  @override
  ImportableType resolveFunctionType(
    FunctionType function, [
    ExecutableElement? executableElement,
  ]) {
    final functionElement =
        executableElement ?? function.element ?? function.alias?.element;
    if (functionElement == null) {
      throw 'Can not resolve function type \nTry using an alias e.g typedef MyFunction = ${function.nameWithoutSuffix};';
    }
    final displayName = functionElement.displayName;
    var functionName = displayName;

    Element elementToImport = functionElement;
    var enclosingElement = functionElement.enclosingElement;

    if (enclosingElement != null && enclosingElement is ClassElement) {
      functionName = '${enclosingElement.displayName}.$displayName';
      elementToImport = enclosingElement;
    }
    final imports = resolveImports(elementToImport);
    return ImportableType(
      name: functionName,
      import: imports.firstOrNull,
      otherImports: imports.skip(1).toSet(),
      isNullable: function.nullabilitySuffix == NullabilitySuffix.question,
    );
  }

  List<ImportableType> _resolveTypeArguments(DartType typeToCheck) {
    final importableTypes = <ImportableType>[];
    if (typeToCheck is RecordType && typeToCheck.alias == null) {
      for (final recordField in [
        ...typeToCheck.positionalFields,
        ...typeToCheck.namedFields,
      ]) {
        final imports = resolveImports(recordField.type.element);
        importableTypes.add(
          ImportableType(
            name: recordField.type.element?.displayName ?? 'void',
            import: imports.firstOrNull,
            otherImports: imports.skip(1).toSet(),
            isNullable:
                recordField.type.nullabilitySuffix ==
                NullabilitySuffix.question,
            typeArguments: _resolveTypeArguments(recordField.type),
            nameInRecord: recordField is RecordTypeNamedField
                ? recordField.name
                : null,
          ),
        );
      }
    } else if (typeToCheck is ParameterizedType || typeToCheck.alias != null) {
      final typeArguments = [
        if (typeToCheck.alias != null)
          ...typeToCheck.alias!.typeArguments
        else if (typeToCheck is ParameterizedType)
          ...typeToCheck.typeArguments,
      ];
      for (DartType type in typeArguments) {
        final imports = resolveImports(type.element);
        if (type is RecordType) {
          final effectiveElement = type.alias?.element ?? type.element;
          importableTypes.add(
            ImportableType.record(
              name: effectiveElement?.displayName ?? '',
              import: imports.firstOrNull,
              otherImports: imports.skip(1).toSet(),
              isNullable: type.nullabilitySuffix == NullabilitySuffix.question,
              typeArguments: _resolveTypeArguments(type),
            ),
          );
        } else if (type.element is TypeParameterElement) {
          importableTypes.add(ImportableType(name: 'dynamic'));
        } else {
          importableTypes.add(
            ImportableType(
              name: type.element?.displayName ?? type.nameWithoutSuffix,
              import: imports.firstOrNull,
              otherImports: imports.skip(1).toSet(),
              isNullable: type.nullabilitySuffix == NullabilitySuffix.question,
              typeArguments: _resolveTypeArguments(type),
            ),
          );
        }
      }
    }
    return importableTypes;
  }

  @override
  ImportableType resolveType(DartType type) {
    final effectiveElement = type.alias?.element ?? type.element;
    final imports = resolveImports(effectiveElement);
    if (type is RecordType && type.alias == null) {
      return ImportableType.record(
        name: effectiveElement?.displayName ?? '',
        import: imports.firstOrNull,
        otherImports: imports.skip(1).toSet(),
        isNullable: type.nullabilitySuffix == NullabilitySuffix.question,
        typeArguments: _resolveTypeArguments(type),
      );
    }
    return ImportableType(
      name: effectiveElement?.displayName ?? type.nameWithoutSuffix,
      isNullable: type.nullabilitySuffix == NullabilitySuffix.question,
      import: imports.firstOrNull,
      otherImports: imports.skip(1).toSet(),
      typeArguments: _resolveTypeArguments(type),
    );
  }
}
