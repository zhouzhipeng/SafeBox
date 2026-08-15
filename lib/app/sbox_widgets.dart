import 'package:flutter/material.dart';

import 'sbox_theme.dart';

class SboxLogo extends StatelessWidget {
  const SboxLogo({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'SafeBox 文件安全盒子',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: compact ? 34 : 40,
            height: compact ? 34 : 40,
            decoration: BoxDecoration(
              color: SboxColors.accent.withValues(alpha: 0.12),
              border: Border.all(
                color: SboxColors.accent.withValues(alpha: 0.5),
              ),
              borderRadius: BorderRadius.circular(10),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: SboxColors.accent.withValues(alpha: 0.08),
                  blurRadius: 18,
                ),
              ],
            ),
            child: Icon(
              Icons.shield_outlined,
              color: SboxColors.accent,
              size: compact ? 21 : 25,
            ),
          ),
          const SizedBox(width: 11),
          Text(
            'SafeBox',
            style: TextStyle(
              color: SboxColors.text,
              fontSize: compact ? 20 : 23,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
            ),
          ),
        ],
      ),
    );
  }
}

class SboxCard extends StatelessWidget {
  const SboxCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.color,
    this.borderColor,
    this.radius = 13,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final Color? borderColor;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? SboxColors.panel,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: borderColor ?? SboxColors.borderSoft),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Material(type: MaterialType.transparency, child: child),
    );
  }
}

class PageHeading extends StatelessWidget {
  const PageHeading({
    super.key,
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final heading = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title, style: Theme.of(context).textTheme.displaySmall),
            const SizedBox(height: 9),
            Text(
              subtitle,
              style: Theme.of(context).textTheme.bodyLarge
                  ?.copyWith(color: SboxColors.textMuted),
            ),
          ],
        );
        if (constraints.maxWidth < 620 && trailing != null) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              heading,
              const SizedBox(height: 16),
              Align(alignment: Alignment.centerLeft, child: trailing),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            Expanded(child: heading),
            if (trailing != null) ...<Widget>[
              const SizedBox(width: 20),
              trailing!,
            ],
          ],
        );
      },
    );
  }
}

class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.label,
    this.icon = Icons.check_circle_outline,
    this.tone = SboxColors.success,
    this.compact = false,
  });

  final String label;
  final IconData icon;
  final Color tone;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 30),
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 9 : 11,
        vertical: compact ? 5 : 7,
      ),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.1),
        border: Border.all(color: tone.withValues(alpha: 0.28)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: compact ? 14 : 16, color: tone),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: tone,
                fontSize: compact ? 11 : 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              if (subtitle != null) ...<Widget>[
                const SizedBox(height: 4),
                Text(subtitle!, style: Theme.of(context).textTheme.bodyMedium),
              ],
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }
}

class SecurityNotice extends StatelessWidget {
  const SecurityNotice({
    super.key,
    required this.title,
    required this.message,
    this.warning = false,
    this.icon,
  });

  final String title;
  final String message;
  final bool warning;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final color = warning ? SboxColors.warning : SboxColors.accent;
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.075),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.27)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            icon ??
                (warning ? Icons.warning_amber_rounded : Icons.shield_outlined),
            color: color,
            size: 21,
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(
                    color: color,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: SboxColors.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class MonospaceValue extends StatelessWidget {
  const MonospaceValue(this.value, {super.key, this.maxLines = 1, this.color});

  final String value;
  final int maxLines;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SelectableText(
      value,
      maxLines: maxLines,
      style: TextStyle(
        color: color ?? SboxColors.text,
        fontSize: 12,
        height: 1.5,
        fontFamily: 'RobotoMono',
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actions = const <Widget>[],
  });

  final IconData icon;
  final String title;
  final String message;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return SboxCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 34, horizontal: 16),
        child: Column(
          children: <Widget>[
            Container(
              width: 62,
              height: 62,
              decoration: BoxDecoration(
                color: SboxColors.accent.withValues(alpha: 0.08),
                shape: BoxShape.circle,
                border: Border.all(
                  color: SboxColors.accent.withValues(alpha: 0.2),
                ),
              ),
              child: Icon(icon, size: 29, color: SboxColors.accent),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            if (actions.isNotEmpty) ...<Widget>[
              const SizedBox(height: 22),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: actions,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class SboxProgressCard extends StatelessWidget {
  const SboxProgressCard({
    super.key,
    required this.title,
    required this.detail,
    this.value,
    this.onCancel,
  });

  final String title;
  final String detail;
  final double? value;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    return SboxCard(
      borderColor: SboxColors.accent.withValues(alpha: 0.3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (onCancel != null)
                TextButton(onPressed: onCancel, child: const Text('取消')),
            ],
          ),
          const SizedBox(height: 14),
          LinearProgressIndicator(
            value: value,
            minHeight: 6,
            borderRadius: BorderRadius.circular(999),
            backgroundColor: SboxColors.borderSoft,
            color: SboxColors.accent,
          ),
          const SizedBox(height: 10),
          Text(detail, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}
