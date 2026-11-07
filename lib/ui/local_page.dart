import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/constants.dart';
import '../models/song.dart';
import '../providers.dart';
import '../services/playback.dart';
import 'glass.dart';

/// 本地音乐页
class LocalPage extends ConsumerStatefulWidget {
  const LocalPage({super.key});

  @override
  ConsumerState<LocalPage> createState() => _LocalPageState();
}

class _LocalPageState extends ConsumerState<LocalPage> {
  bool _loading = false;
  String _dir = '';
  List<Song> _songs = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _scanDefault();
  }

  Future<void> _scanDefault() async {
    final service = ref.read(localMusicServiceProvider);
    final paths = await service.defaultScanPaths();
    if (paths.isEmpty) {
      if (mounted) setState(() => _error = '未找到可扫描的音乐目录');
      return;
    }
    await _scan(paths.first);
  }

  Future<void> _scan(String dir) async {
    setState(() {
      _loading = true;
      _dir = dir;
      _error = null;
    });
    try {
      final service = ref.read(localMusicServiceProvider);
      final songs = await service.scanDirectory(dir);
      if (mounted) setState(() => _songs = songs);
    } catch (e) {
      if (mounted) setState(() => _error = '扫描失败：$e');
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _pickDir() async {
    final service = ref.read(localMusicServiceProvider);
    final paths = await service.defaultScanPaths();
    if (paths.isEmpty) {
      if (mounted) setState(() => _error = '未找到可扫描的音乐目录');
      return;
    }
    await _scan(paths.first);
  }

  Future<void> _play(Song song) async {
    await resolveAndPlay(ref, song);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? JXColors.textOnDark : JXColors.textPrimary;
    final textSub =
        isDark ? JXColors.textOnDarkSecondary : JXColors.textSecondary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '本地音乐',
                      style: TextStyle(
                          fontSize: 24, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _dir.isEmpty ? '选择目录开始扫描' : _dir,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: textSub),
                    ),
                  ],
                ),
              ),
              GlassButton(text: '扫描目录', onPressed: _pickDir),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(
                  child: CircularProgressIndicator(color: JXColors.primary))
              : _error != null
                  ? Center(
                      child: Text(_error!,
                          style: const TextStyle(color: Colors.redAccent)))
                  : _songs.isEmpty
                      ? Center(
                          child: Text('未发现音乐文件',
                              style: TextStyle(color: textSub)),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                          itemCount: _songs.length,
                          separatorBuilder: (_, _) => const Divider(
                              height: 1, indent: 64),
                          itemBuilder: (context, i) {
                            final s = _songs[i];
                            return ListTile(
                              contentPadding:
                                  const EdgeInsets.symmetric(horizontal: 8),
                              leading: GlassCover(
                                  url: s.coverUrl,
                                  size: 44,
                                  borderRadius: BorderRadius.circular(10)),
                              title: Text(
                                s.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 14,
                                    color: textColor,
                                    fontWeight: FontWeight.w500),
                              ),
                              subtitle: Text(
                                '${s.artist} · ${s.album}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style:
                                    TextStyle(fontSize: 11, color: textSub),
                              ),
                              trailing: GlassIconButton(
                                icon: Icons.play_arrow_rounded,
                                size: 36,
                                color: JXColors.primary,
                                onPressed: () => _play(s),
                              ),
                              onTap: () => _play(s),
                            );
                          },
                        ),
        ),
      ],
    );
  }
}
