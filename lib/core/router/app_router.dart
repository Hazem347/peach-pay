import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

// Provide the GoRouter instance via Riverpod so we can inject auth state later
final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const Scaffold(
          body: Center(
            child: Text('Peach Pay Initializing...'),
          ),
        ),
      ),
      // Add routes here as features are built
    ],
  );
});
