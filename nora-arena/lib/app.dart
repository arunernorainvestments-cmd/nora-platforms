import 'package:flutter/material.dart';

import 'core/config/theme.dart';
import 'router.dart';

class NoraArenaApp extends StatelessWidget {
  const NoraArenaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'N.O.R.A. Arena',
      debugShowCheckedModeBanner: false,
      theme: buildNoraTheme(),
      routerConfig: appRouter,
    );
  }
}
