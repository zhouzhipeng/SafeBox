import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../app/sbox_widgets.dart';

final class KeysSummaryPage extends StatelessWidget {
  const KeysSummaryPage({
    super.key,
    required this.controller,
    required this.onOpenOnboarding,
  });

  final AppController controller;
  final VoidCallback onOpenOnboarding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const PageHeading(
          title: '身份',
          subtitle: 'RSA-3072 公钥和 Key ID 可以持久化；私钥材料只在需要时从助记词临时派生。',
        ),
        const SizedBox(height: 24),
        SboxCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'recipient_key_id',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              SelectableText(controller.shortFingerprint),
              const SizedBox(height: 18),
              OutlinedButton(
                onPressed: onOpenOnboarding,
                child: const Text('恢复或创建身份'),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
