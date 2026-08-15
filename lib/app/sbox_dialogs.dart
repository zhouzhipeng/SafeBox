import 'package:flutter/material.dart';

import 'sbox_theme.dart';
import 'sbox_widgets.dart';

Future<String?> showMnemonicPrompt(
  BuildContext context, {
  required String title,
  String actionLabel = '继续',
}) async {
  final controller = TextEditingController();
  var obscured = true;
  try {
    return await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          backgroundColor: SboxColors.panel,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: SboxColors.border),
          ),
          title: Text(title),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const SecurityNotice(
                  title: '仅用于本次任务 · 不会保存',
                  message: '助记词只进入一次性 Crypto Isolate。任务完成、失败、取消或应用进入后台后立即终止。',
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  minLines: obscured ? 1 : 3,
                  maxLines: obscured ? 1 : 4,
                  obscureText: obscured,
                  autocorrect: false,
                  enableSuggestions: false,
                  autofillHints: null,
                  keyboardType: TextInputType.visiblePassword,
                  decoration: InputDecoration(
                    labelText: '12 词助记词',
                    hintText: 'word1 word2 … word12',
                    suffixIcon: IconButton(
                      tooltip: obscured ? '显示助记词' : '隐藏助记词',
                      onPressed: () => setState(() => obscured = !obscured),
                      icon: Icon(
                        obscured
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                    ),
                  ),
                  onSubmitted: (value) {
                    final trimmed = value.trim();
                    if (trimmed.isNotEmpty) Navigator.of(context).pop(trimmed);
                  },
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () {
                final value = controller.text.trim();
                if (value.isNotEmpty) Navigator.of(context).pop(value);
              },
              child: Text(actionLabel),
            ),
          ],
        ),
      ),
    );
  } finally {
    controller.clear();
    controller.dispose();
  }
}

Future<bool> showDestructiveConfirmation(
  BuildContext context, {
  required String title,
  required String message,
  String actionLabel = '确认删除',
}) async {
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: SboxColors.panel,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: SboxColors.border),
          ),
          title: Text(title),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: SecurityNotice(
              title: '请确认影响范围',
              message: message,
              warning: true,
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: SboxColors.danger,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(actionLabel),
            ),
          ],
        ),
      ) ??
      false;
}
