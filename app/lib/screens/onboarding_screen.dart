import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/settings_store.dart';

class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(),
              Icon(Icons.dashboard_customize_outlined,
                  size: 64, color: scheme.primary),
              const SizedBox(height: 24),
              Text('HomeDeck',
                  style: Theme.of(context).textTheme.headlineLarge),
              const SizedBox(height: 12),
              Text(
                'Turn this device into a home control panel.',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 24),
              const _Point(Icons.radar,
                  'Finds everything on your network — smart or not'),
              const _Point(Icons.videocam_outlined,
                  'Shows any security camera, any brand'),
              const _Point(Icons.home_outlined,
                  'Connects to Home Assistant if you have it'),
              const _Point(Icons.battery_saver_outlined,
                  'Built to run well on old phones and tablets'),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () =>
                      context.read<SettingsStore>().onboarded = true,
                  child: const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('Get started'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Point extends StatelessWidget {
  const _Point(this.icon, this.text);

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 16),
            Expanded(child: Text(text)),
          ],
        ),
      );
}
