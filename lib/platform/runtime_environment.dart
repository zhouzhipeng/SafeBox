/// Whether the current program was compiled for the web.
///
/// This uses the same compile-time environment flag as Flutter's `kIsWeb`
/// without loading Flutter's `dart:ui`-dependent foundation library.
const bool isWebRuntime = bool.fromEnvironment('dart.library.js_interop');
