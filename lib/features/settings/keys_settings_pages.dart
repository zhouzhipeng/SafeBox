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
        const SecurityNotice(
          title: '公钥与缩略图隐私提示',
          message: '获得此公钥的人可以读取文件名、说明、时间和缩略图预览，但不能仅凭公钥解密文件正文。',
          warning: true,
        ),
        const SizedBox(height: 16),
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
