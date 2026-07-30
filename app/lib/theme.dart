import 'package:flutter/material.dart';

/// HomeDeck theme. Dark-first: these panels live on a wall, usually at night
/// brightness. [lowFx] strips transitions/shadows for old hardware.
ThemeData buildTheme({required bool lowFx}) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF4DB6AC),
    brightness: Brightness.dark,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: const Color(0xFF101414),
    cardTheme: CardThemeData(
      elevation: lowFx ? 0 : 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    listTileTheme: const ListTileThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 64,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
    pageTransitionsTheme: lowFx
        ? const PageTransitionsTheme(builders: {
            TargetPlatform.android: _NoTransitionsBuilder(),
            TargetPlatform.linux: _NoTransitionsBuilder(),
          })
        : null,
    splashFactory: lowFx ? NoSplash.splashFactory : null,
  );
}

class _NoTransitionsBuilder extends PageTransitionsBuilder {
  const _NoTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) =>
      child;
}
