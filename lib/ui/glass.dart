import 'dart:ui';
import 'package:flutter/material.dart';
import '../core/constants.dart';
import 'cover.dart';

/// iOS26 液态玻璃组件库
/// 核心视觉：高透表面 + 背景模糊 + 1px 描边高光 + 柔和阴影 + 大圆角

/// 玻璃容器（带背景模糊的卡片）
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final BorderRadius borderRadius;
  final Color? tint;
  final double blur;
  final bool bordered;
  final VoidCallback? onTap;
  final Gradient? gradient;

  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin = EdgeInsets.zero,
    this.borderRadius = const BorderRadius.all(Radius.circular(24)),
    this.tint,
    this.blur = 18,
    this.bordered = true,
    this.onTap,
    this.gradient,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final defaultTint =
        isDark ? JXColors.glassDark : JXColors.glassLight;

    Widget content = ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            gradient: gradient ??
                LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    tint ?? defaultTint,
                    (tint ?? defaultTint).withValues(alpha: 0.55),
                  ],
                ),
            borderRadius: borderRadius,
            border: bordered
                ? Border.all(
                    color: isDark
                        ? JXColors.glassStrokeDark
                        : JXColors.glassStrokeLight,
                    width: 1,
                  )
                : null,
          ),
          child: child,
        ),
      ),
    );

    if (onTap != null) {
      content = InkWell(
        onTap: onTap,
        borderRadius: borderRadius,
        child: content,
      );
    }

    return Container(
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.08),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: content,
    );
  }
}

/// 玻璃按钮
class GlassButton extends StatelessWidget {
  final String text;
  final IconData? icon;
  final VoidCallback? onPressed;
  final Color? color;
  final bool primary;
  final double height;

  const GlassButton({
    super.key,
    required this.text,
    this.icon,
    this.onPressed,
    this.color,
    this.primary = false,
    this.height = 44,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = color ?? (primary ? JXColors.primary : null);
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          gradient: bg != null
              ? LinearGradient(colors: [
                  bg.withValues(alpha: 0.9),
                  bg.withValues(alpha: 0.7),
                ])
              : LinearGradient(colors: [
                  isDark ? JXColors.glassDark : JXColors.glassLight,
                  (isDark ? JXColors.glassDark : JXColors.glassLight)
                      .withValues(alpha: 0.5),
                ]),
          borderRadius: BorderRadius.circular(height / 2),
          border: Border.all(
            color: isDark ? JXColors.glassStrokeDark : JXColors.glassStrokeLight,
            width: 1,
          ),
          boxShadow: bg != null
              ? [
                  BoxShadow(
                    color: bg.withValues(alpha: 0.35),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  )
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18,
                  color: bg != null
                      ? Colors.white
                      : isDark
                          ? JXColors.textOnDark
                          : JXColors.textPrimary),
              const SizedBox(width: 8),
            ],
            Text(
              text,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: bg != null
                    ? Colors.white
                    : isDark
                        ? JXColors.textOnDark
                        : JXColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 圆形玻璃图标按钮
class GlassIconButton extends StatelessWidget {
  final IconData icon;
  final double size;
  final VoidCallback? onPressed;
  final Color? color;

  const GlassIconButton({
    super.key,
    required this.icon,
    this.size = 44,
    this.onPressed,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              color?.withValues(alpha: 0.85) ??
                  (isDark ? JXColors.glassDark : JXColors.glassLight),
              (color?.withValues(alpha: 0.55) ??
                      (isDark ? JXColors.glassDark : JXColors.glassLight))
                  .withValues(alpha: 0.45),
            ],
          ),
          shape: BoxShape.circle,
          border: Border.all(
            color: isDark ? JXColors.glassStrokeDark : JXColors.glassStrokeLight,
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.06),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Icon(icon,
            size: size * 0.46,
            color: color != null
                ? Colors.white
                : isDark
                    ? JXColors.textOnDark
                    : JXColors.textPrimary),
      ),
    );
  }
}

/// 液态玻璃封面图（带内阴影高光）
class GlassCover extends StatelessWidget {
  final String url;
  final double size;
  final BorderRadius? borderRadius;

  const GlassCover({
    super.key,
    required this.url,
    required this.size,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    final radius = borderRadius ?? BorderRadius.circular(size * 0.22);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.22),
            blurRadius: size * 0.12,
            offset: Offset(0, size * 0.05),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          fit: StackFit.expand,
          children: [
            JXCoverImage(
              src: url,
              cacheWidth: (size * 2).round(),
              fallback: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [JXColors.primary, JXColors.accentCyan],
                  ),
                ),
                child: Icon(Icons.music_note_rounded,
                    color: Colors.white, size: size * 0.28),
              ),
            ),
            // 高光层
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.white.withValues(alpha: 0.22),
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.12),
                  ],
                  stops: const [0, 0.45, 1],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
