//
// GENERATED CODE - DO NOT MODIFY BY HAND!
// BUILDER: reflection_factory/1.0.12
// BUILD COMMAND: dart run build_runner build
//

part of 'bones_api_test.dart';

class MyInfoModule$reflection extends ClassReflection<MyInfoModule> {
  MyInfoModule$reflection([MyInfoModule? object]) : super(MyInfoModule, object);

  bool _registered = false;
  @override
  void register() {
    if (!_registered) {
      _registered = true;
      super.register();
    }
  }

  @override
  Version get languageVersion => Version.parse('2.13.0');

  @override
  MyInfoModule$reflection withObject([MyInfoModule? obj]) =>
      MyInfoModule$reflection(obj);

  @override
  bool get hasDefaultConstructor => false;
  @override
  MyInfoModule? createInstanceWithDefaultConstructor() => null;

  @override
  bool get hasEmptyConstructor => false;
  @override
  MyInfoModule? createInstanceWithEmptyConstructor() => null;

  @override
  List<String> get constructorsNames => const <String>[''];

  @override
  ConstructorReflection<MyInfoModule>? constructor<R>(String constructorName) {
    var lc = constructorName.trim().toLowerCase();

    switch (lc) {
      case '':
        return ConstructorReflection<MyInfoModule>(
            this,
            '',
            () => (APIRoot apiRoot) => MyInfoModule(apiRoot),
            const <ParameterReflection>[
              ParameterReflection(
                  TypeReflection(APIRoot), 'apiRoot', false, true, null, null)
            ],
            null,
            null,
            null);
      default:
        return null;
    }
  }

  @override
  List<Object> get classAnnotations => List<Object>.unmodifiable(<Object>[]);

  @override
  List<String> get fieldsNames => const <String>[];

  @override
  FieldReflection<MyInfoModule, T>? field<T>(String fieldName,
      [MyInfoModule? obj]) {
    obj ??= object!;

    return null;
  }

  @override
  List<String> get staticFieldsNames => const <String>[];

  @override
  FieldReflection<MyInfoModule, T>? staticField<T>(String fieldName) {
    return null;
  }

  @override
  List<String> get methodsNames => const <String>['configure', 'echo'];

  @override
  MethodReflection<MyInfoModule, R>? method<R>(String methodName,
      [MyInfoModule? obj]) {
    obj ??= object;

    var lc = methodName.trim().toLowerCase();

    switch (lc) {
      case 'configure':
        return MethodReflection<MyInfoModule, R>(this, 'configure', null, false,
            (o) => o!.configure, obj, false, null, null, null, [override]);
      case 'echo':
        return MethodReflection<MyInfoModule, R>(
            this,
            'echo',
            TypeReflection(FutureOr, [
              TypeReflection(APIResponse, [dynamic])
            ]),
            false,
            (o) => o!.echo,
            obj,
            false,
            const <ParameterReflection>[
              ParameterReflection(
                  TypeReflection.tString, 'msg', false, true, null, null),
              ParameterReflection(TypeReflection(APIRequest), 'request', false,
                  true, null, null)
            ],
            null,
            null,
            null);
      default:
        return null;
    }
  }

  @override
  List<String> get staticMethodsNames => const <String>[];

  @override
  MethodReflection<MyInfoModule, R>? staticMethod<R>(String methodName) {
    return null;
  }
}

extension MyInfoModule$reflectionExtension on MyInfoModule {
  /// Returns a [ClassReflection] for type [MyInfoModule]. (Generated by [ReflectionFactory])
  ClassReflection<MyInfoModule> get reflection => MyInfoModule$reflection(this);

  /// Returns a JSON [Map] for type [MyInfoModule]. (Generated by [ReflectionFactory])
  Map<String, dynamic> toJson() => reflection.toJson();

  /// Returns an encoded JSON [String] for type [MyInfoModule]. (Generated by [ReflectionFactory])
  String toJsonEncoded() => reflection.toJsonEncoded();
}
