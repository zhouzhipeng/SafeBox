import 'package:flutter/material.dart';

import 'sbox_theme.dart';

class SboxLogo extends StatelessWidget {
  const SboxLogo({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final iconSize = compact ? 40.0 : 48.0;
    return Semantics(
      label: 'SafeBox 文件安全盒子',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: iconSize,
            height: iconSize,
            decoration: BoxDecoration(
              color: SboxColors.accent.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(compact ? 11 : 14),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: SboxColors.accent.withValues(alpha: 0.1),
                  blurRadius: 20,
                ),
              ],
            ),
            child: Icon(
              Icons.shield_outlined,
              color: SboxColors.accent,
              size: compact ? 27 : 32,
            ),
          ),
          SizedBox(width: compact ? 10 : 14),
          Text(
            'SafeBox',
            style: TextStyle(
              color: SboxColors.text,
              fontSize: compact ? 22 : 26,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
          ),
        ],
      ),
    );
  }
}

class SboxTopBar extends StatelessWidget {
  const SboxTopBar({
    super.key,
    required this.mobile,
    this.onFilesTap,
    this.onSettingsTap,
    this.firstUse = false,
  });

  final bool mobile;
  final VoidCallback? onFilesTap;
  final VoidCallback? onSettingsTap;
  final bool firstUse;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: mobile ? 122 : 72,
      padding: EdgeInsets.symmetric(horizontal: mobile ? 34 : 32),
      decoration: BoxDecoration(
        color: SboxColors.backgroundDeep.withValues(alpha: 0.92),
        border: const Border(bottom: BorderSide(color: SboxColors.borderSoft)),
      ),
      child: Row(
        children: <Widget>[
          SboxLogo(compact: mobile),
          const Spacer(),
          if (firstUse)
            const Text(
              '首次使用',
              style: TextStyle(
                color: SboxColors.accent,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            )
          else ...<Widget>[
            if (onFilesTap != null) ...<Widget>[
              IconButton(
                onPressed: onFilesTap,
                tooltip: '文件',
                icon: const Icon(Icons.folder_outlined),
                color: SboxColors.textMuted,
                iconSize: 28,
                padding: const EdgeInsets.all(10),
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              ),
              const SizedBox(width: 12),
            ],
            if (onSettingsTap != null) ...<Widget>[
              IconButton(
                onPressed: onSettingsTap,
                tooltip: '设置',
                icon: const Icon(Icons.settings_outlined),
                color: SboxColors.textMuted,
                iconSize: 28,
                padding: const EdgeInsets.all(10),
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class SboxTabBar extends StatelessWidget {
  const SboxTabBar({
    super.key,
    required this.mobile,
    required this.settingsSelected,
    this.onCloudTap,
    this.onSettingsTap,
    this.cloudDisabled = false,
  });

  final bool mobile;
  final bool settingsSelected;
  final VoidCallback? onCloudTap;
  final VoidCallback? onSettingsTap;
  final bool cloudDisabled;

  @override
  Widget build(BuildContext context) {
    Widget tab({
      required String label,
      required IconData icon,
      required bool selected,
      required VoidCallback? onTap,
      bool disabled = false,
    }) {
      final child = _SboxTab(
        mobile: mobile,
        label: label,
        icon: icon,
        selected: selected,
        disabled: disabled,
        onTap: onTap,
      );
      return SizedBox(width: mobile ? 130 : 230, child: child);
    }

    return Container(
      height: mobile ? 98 : 64,
      decoration: const BoxDecoration(
        color: Color(0xCC0A1A2B),
        border: Border(bottom: BorderSide(color: SboxColors.borderSoft)),
      ),
      child: Center(
        child: SizedBox(
          width: mobile ? 260 : 460,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              tab(
                label: '云端文件',
                icon: Icons.cloud_download_outlined,
                selected: !settingsSelected,
                disabled: cloudDisabled,
                onTap: onCloudTap,
              ),
              tab(
                label: '设置',
                icon: Icons.settings_outlined,
                selected: settingsSelected,
                onTap: onSettingsTap,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _SboxTab extends StatelessWidget {
  const _SboxTab({
    required this.mobile,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.disabled = false,
  });

  final bool mobile;
  final String label;
  final IconData icon;
  final bool selected;
  final bool disabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = disabled
        ? SboxColors.textDim
        : selected
        ? SboxColors.accent
        : SboxColors.textMuted;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        onTap: disabled ? null : onTap,
        child: Stack(
          fit: StackFit.expand,
          alignment: Alignment.bottomCenter,
          children: <Widget>[
            Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(icon, color: color, size: mobile ? 38 : 31),
                  SizedBox(width: mobile ? 16 : 12),
                  Text(
                    label,
                    style: TextStyle(
                      color: color,
                      fontSize: mobile ? 22 : 17,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            if (selected)
              Positioned(
                bottom: 0,
                left: mobile ? 8 : 0,
                right: mobile ? 8 : 0,
                child: Container(
                  height: mobile ? 5 : 4,
                  decoration: BoxDecoration(
                    color: SboxColors.accent,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
          ],
        ),
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
        color: color ?? SboxColors.panelSoft,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: borderColor ?? SboxColors.borderSoft),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.16),
            blurRadius: 22,
            offset: const Offset(0, 10),
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
        final compact = constraints.maxWidth < 620;
        final titleText = Text(
          title,
          style: Theme.of(context).textTheme.displaySmall
              ?.copyWith(fontSize: compact ? 32 : 38),
        );
        final subtitleText = Text(
          subtitle,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
            color: SboxColors.textMuted,
            fontSize: compact ? 15 : 16,
          ),
        );
        final heading = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            titleText,
            const SizedBox(height: 8),
            subtitleText,
          ],
        );
        if (compact && trailing != null) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  Expanded(child: titleText),
                  const SizedBox(width: 12),
                  trailing!,
                ],
              ),
              const SizedBox(height: 8),
              subtitleText,
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
      constraints: BoxConstraints(minHeight: compact ? 30 : 36),
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 11 : 15,
        vertical: compact ? 5 : 7,
      ),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.08),
        border: Border.all(color: tone.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: compact ? 16 : 19, color: tone),
          const SizedBox(width: 7),
          Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: tone,
              fontSize: compact ? 12 : 14,
              fontWeight: FontWeight.w600,
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
    this.compact = false,
  });

  final String title;
  final String message;
  final bool warning;
  final IconData? icon;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final color = warning ? SboxColors.warning : SboxColors.accent;
    return Container(
      padding: EdgeInsets.all(compact ? 12 : 15),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            icon ??
                (warning ? Icons.warning_amber_rounded : Icons.shield_outlined),
            color: color,
            size: compact ? 19 : 21,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(
                    color: color,
                    fontSize: compact ? 12 : 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
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

class SboxLockHint extends StatelessWidget {
  const SboxLockHint({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Icon(Icons.lock_outline, color: SboxColors.textMuted, size: 20),
        const SizedBox(width: 8),
        Text(
          text,
          style: Theme.of(context).textTheme.bodyLarge
              ?.copyWith(color: SboxColors.textMuted),
        ),
      ],
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
            Icon(icon, size: 42, color: SboxColors.accent),
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
    this.progressLabel,
    this.onCancel,
  });

  final String title;
  final String detail;
  final double? value;
  final String? progressLabel;
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Text(detail, style: Theme.of(context).textTheme.bodyMedium),
              ),
              if (progressLabel != null) ...<Widget>[
                const SizedBox(width: 12),
                Text(
                  progressLabel!,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: SboxColors.accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class SboxShieldMark extends StatelessWidget {
  const SboxShieldMark({super.key, this.size = 86, this.filled = false});

  final double size;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: filled ? SboxColors.accent.withValues(alpha: 0.12) : null,
        borderRadius: BorderRadius.circular(size * 0.24),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: SboxColors.accent.withValues(alpha: 0.18),
            blurRadius: size * 0.32,
          ),
        ],
      ),
      child: Icon(
        Icons.verified_user_outlined,
        color: SboxColors.accent,
        size: size * 0.78,
      ),
    );
  }
}

class FileTypeBadge extends StatelessWidget {
  const FileTypeBadge({super.key, required this.type, required this.color});

  final String type;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 54,
      height: 68,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Icon(Icons.insert_drive_file_rounded, color: color, size: 61),
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              type,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w800,
                height: 1.0,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
