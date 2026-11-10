import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../cover.dart';

/// 播放页「黑胶唱片」视觉组件。
///
/// 自外向内分层（见 PRD R3.1）：
/// 1. 外缘高光 + 柔和落影（包在根节点上，不随盘旋转）；
/// 2. 圆形盘体：近黑径向渐变（#0A0A0D → #26262E → #0D0D12）+ 1px 外缘高光；
/// 3. 沟槽 + 反光：[CustomPaint] 画 14 圈同心细环（白色 4%~10% alpha）、
///   135° 斜向反光带、外缘内侧高光弧、盘面暗角；
/// 4. 中心标签：圆形裁剪的专辑封面，直径 ≈ 0.52×size，外圈 1px 浅色描边；
///    封面为空/加载失败时用「深色渐变 + 音符图标」兜底（盘体仍完整）；
/// 5. 中心轴孔：直径 ≈ 0.05×size 的深色圆孔。
///
/// 旋转规则（PRD R3.2）：播放中 30s/圈匀速旋转；暂停时 [AnimationController.stop]
/// 停在当前角度，恢复播放从当前角度继续；组件自身状态不随 `coverUrl` 变化重建，
/// 因此切歌不会重置角度。
class JXVinylDisc extends StatefulWidget {
  const JXVinylDisc({
    super.key,
    required this.coverUrl,
    required this.size,
    this.spinning = false,
  });

  /// 专辑封面 URL / 本地文件路径；可为空。
  final String coverUrl;

  /// 唱片外径（正方形边长），布局由调用方决定（播放页走 jxPlayerCoverSize）。
  final double size;

  /// 是否播放中（true 旋转 / false 停在当前角度）。
  final bool spinning;

  /// 一圈时长（PRD R3.2：30s/圈）。
  static const Duration spinPeriod = Duration(seconds: 30);

  /// 中心封面标签直径占比。
  static const double labelScale = 0.52;

  /// 中心轴孔直径占比。
  static const double holeScale = 0.05;

  @override
  State<JXVinylDisc> createState() => _JXVinylDiscState();
}

class _JXVinylDiscState extends State<JXVinylDisc>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(vsync: this, duration: JXVinylDisc.spinPeriod);
    _syncSpin();
  }

  @override
  void didUpdateWidget(covariant JXVinylDisc oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 只有播放状态变化才改动画；换歌（coverUrl 变化）不碰角度。
    if (oldWidget.spinning != widget.spinning) _syncSpin();
  }

  /// 播放中 repeat（AnimationController.repeat 从当前 value 起算，即保留角度），
  /// 暂停时 stop 并停住当前角度。
  void _syncSpin() {
    if (widget.spinning) {
      _spin.repeat();
    } else {
      _spin.stop();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    if (size <= 0) return const SizedBox.shrink();
    final labelSize = size * JXVinylDisc.labelScale;
    final holeSize = size * JXVinylDisc.holeScale;

    return Container(
      // 根 Key：widget 测试/QA 用它定位整张唱片并断言尺寸
      key: const Key('playerVinylDisc'),
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        // 保留原 _GlowCover 的「外圈光环 + 深投影」观感
        boxShadow: [
          BoxShadow(
            color: Colors.white.withValues(alpha: 0.05),
            blurRadius: 0,
            spreadRadius: size * 0.045,
          ),
          BoxShadow(
            color: Colors.white.withValues(alpha: 0.035),
            blurRadius: 0,
            spreadRadius: size * 0.10,
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: size * 0.14,
            offset: Offset(0, size * 0.07),
          ),
        ],
      ),
      child: RotationTransition(
        turns: _spin,
        child: SizedBox(
          width: size,
          height: size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // 1) 圆形盘体：近黑径向渐变 + 1px 外缘高光
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const RadialGradient(
                      center: Alignment(-0.15, -0.2),
                      radius: 0.85,
                      colors: [
                        Color(0xFF26262E),
                        Color(0xFF14141A),
                        Color(0xFF0A0A0D),
                        Color(0xFF0D0D12),
                      ],
                      stops: [0.0, 0.55, 0.85, 1.0],
                    ),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.16),
                      width: 1,
                    ),
                  ),
                ),
              ),
              // 2) 沟槽 + 135° 反光 + 外缘内侧高光（不透明背景之外的纹理层）
              const Positioned.fill(
                child: CustomPaint(
                  key: Key('vinylGrooves'),
                  painter: _VinylGroovePainter(),
                ),
              ),
              // 3) 中心圆形专辑封面标签
              _VinylLabel(coverUrl: widget.coverUrl, size: labelSize),
              // 4) 中心轴孔
              Container(
                key: const Key('vinylHole'),
                width: holeSize,
                height: holeSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const RadialGradient(
                    colors: [Color(0xFF050508), Color(0xFF1C1C22)],
                  ),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.10),
                    width: 0.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.65),
                      blurRadius: holeSize * 0.5,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 中心圆形专辑封面标签（≈0.52×size）+ 1px 浅色描边 + 标签高光。
class _VinylLabel extends StatelessWidget {
  const _VinylLabel({required this.coverUrl, required this.size});

  final String coverUrl;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('vinylLabel'),
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.22),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: size * 0.10,
          ),
        ],
      ),
      child: ClipOval(
        child: Stack(
          fit: StackFit.expand,
          children: [
            JXCoverImage(
              src: coverUrl,
              cacheWidth: (size * 2).round(),
              fallback: _labelFallback(size),
            ),
            // 标签表面高光：左上亮、右下暗，让封面与盘面融合
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color(0x22FFFFFF),
                    Color(0x00FFFFFF),
                    Color(0x33000000),
                  ],
                  stops: [0.0, 0.5, 1.0],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 封面为空 / 加载失败：深色渐变 + 音符图标（盘体仍完整）。
  Widget _labelFallback(double labelSize) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2B2B35), Color(0xFF101014)],
        ),
      ),
      child: Icon(
        Icons.music_note_rounded,
        color: Colors.white.withValues(alpha: 0.72),
        size: labelSize * 0.42,
      ),
    );
  }
}

/// 黑胶沟槽 / 反光绘制层。
///
/// 只画纹理与光，不含盘体底色（底色由外层径向渐变负责），因此
/// `shouldRepaint == false`：旋转由 [RotationTransition] 的 Transform 完成，
/// 不需要逐帧重绘。
class _VinylGroovePainter extends CustomPainter {
  const _VinylGroovePainter();

  /// 同心沟槽圈数（PRD 要求 12~16 圈）。
  static const int grooveCount = 14;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    if (radius <= 0) return;
    final bounds = Rect.fromCircle(center: center, radius: radius);

    canvas.save();
    canvas.clipPath(Path()..addOval(bounds));

    // 盘面暗角：外缘更暗，中心附近略亮，增强「黑胶」立体感
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.3, -0.35),
          radius: 1.05,
          colors: [Color(0x14FFFFFF), Color(0x00000000), Color(0x40000000)],
          stops: [0.0, 0.5, 1.0],
        ).createShader(bounds),
    );

    // 135° 斜向反光带（左上 → 右下，即 135° 方向）
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: 0.10),
            Colors.white.withValues(alpha: 0.02),
            Colors.transparent,
            Colors.transparent,
          ],
          stops: const [0.0, 0.30, 0.58, 1.0],
        ).createShader(bounds),
    );

    // 同心沟槽：14 圈，白色 4%~10% alpha，越靠外越密
    final inner = radius * 0.60;
    final outer = radius * 0.955;
    for (var i = 0; i < grooveCount; i++) {
      final t = i / (grooveCount - 1);
      final r = inner + (outer - inner) * t;
      final alpha = 0.04 + 0.06 * (0.5 + 0.5 * math.sin(t * math.pi * 2));
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(0.6, radius * 0.004)
          ..color = Colors.white.withValues(alpha: alpha),
      );
    }

    // 外缘内侧高光弧（顶部亮、底部弱，模拟环境光）
    final rim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.0, radius * 0.006)
      ..shader = const SweepGradient(
        colors: [
          Color(0x33FFFFFF),
          Color(0x00FFFFFF),
          Color(0x1AFFFFFF),
          Color(0x00FFFFFF),
          Color(0x33FFFFFF),
        ],
        stops: [0.0, 0.25, 0.5, 0.75, 1.0],
      ).createShader(bounds);
    canvas.drawCircle(center, radius - radius * 0.012, rim);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _VinylGroovePainter oldDelegate) => false;
}
