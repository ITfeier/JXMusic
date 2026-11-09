import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/constants.dart';
import 'glass.dart';

/// 弹出目录选择对话框，返回选中的目录路径；取消返回 null。
///
/// 纯 `dart:io` 自绘（不引第三方 file picker）：
/// - 可编辑当前路径 + 上级目录；
/// - 只列子目录（不列文件），跳过隐藏目录；
/// - 快捷入口 chips（Windows 盘符 / Android 常用目录）；
/// - 不可读目录显示错误原因，不崩溃。
Future<String?> showDirectoryPickerDialog(
  BuildContext context, {
  String? initialPath,
  List<String> quickPaths = const <String>[],
}) {
  return showDialog<String>(
    context: context,
    builder: (_) =>
        DirectoryPickerDialog(initialPath: initialPath, quickPaths: quickPaths),
  );
}

/// 目录选择对话框（可独立测试）。
class DirectoryPickerDialog extends StatefulWidget {
  const DirectoryPickerDialog({
    super.key,
    this.initialPath,
    this.quickPaths = const <String>[],
  });

  final String? initialPath;
  final List<String> quickPaths;

  @override
  State<DirectoryPickerDialog> createState() => _DirectoryPickerDialogState();
}

class _DirectoryPickerDialogState extends State<DirectoryPickerDialog> {
  late final TextEditingController _controller;
  String _current = '';
  List<String> _directories = const <String>[];
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    final initial = _initialPath();
    _current = initial;
    _controller = TextEditingController(text: initial);
    _open(initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _initialPath() {
    final injected = widget.initialPath?.trim() ?? '';
    if (injected.isNotEmpty) return injected;
    if (widget.quickPaths.isNotEmpty) return widget.quickPaths.first;
    final home = _homePath();
    if (home.isNotEmpty) return home;
    try {
      return Platform.isWindows ? 'C:\\' : '/';
    } catch (_) {
      return '/';
    }
  }

  static String _homePath() {
    try {
      return Platform.environment['USERPROFILE'] ??
          Platform.environment['HOME'] ??
          '';
    } catch (_) {
      return '';
    }
  }

  String? get _parentPath {
    try {
      final parent = p.dirname(_current);
      if (parent.isEmpty || parent == _current) return null;
      return parent;
    } catch (_) {
      return null;
    }
  }

  Future<void> _open(String rawPath) async {
    final path = rawPath.trim();
    if (path.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
      _current = path;
      _controller.text = path;
    });
    try {
      final entries = await Directory(path).list(followLinks: false).toList();
      final directories =
          entries
              .whereType<Directory>()
              .map((d) => d.path)
              .where((d) => !p.basename(d).startsWith('.'))
              .toList()
            ..sort(
              (a, b) => p
                  .basename(a)
                  .toLowerCase()
                  .compareTo(p.basename(b).toLowerCase()),
            );
      if (!mounted) return;
      setState(() {
        _directories = directories;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _directories = const <String>[];
        _loading = false;
        _error = '无法读取该目录：${_errorText(e)}';
      });
    }
  }

  static String _errorText(Object error) {
    if (error is FileSystemException) {
      final osMessage = error.osError?.message;
      if (osMessage != null && osMessage.isNotEmpty) return osMessage;
      if (error.message.isNotEmpty) return error.message;
    }
    return '$error';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? JXColors.textOnDark : JXColors.textPrimary;
    final textSub = isDark
        ? JXColors.textOnDarkSecondary
        : JXColors.textSecondary;
    final parent = _parentPath;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: SizedBox(
        width: 520,
        height: 460,
        child: GlassCard(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '选择音乐目录',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  GlassIconButton(
                    icon: Icons.close_rounded,
                    size: 30,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  GlassIconButton(
                    icon: Icons.arrow_upward_rounded,
                    size: 34,
                    onPressed: parent == null ? null : () => _open(parent),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      style: TextStyle(fontSize: 12, color: textColor),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: '输入目录路径后回车',
                        hintStyle: TextStyle(fontSize: 12, color: textSub),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onSubmitted: _open,
                    ),
                  ),
                  const SizedBox(width: 8),
                  GlassIconButton(
                    icon: Icons.refresh_rounded,
                    size: 34,
                    onPressed: () => _open(_current),
                  ),
                ],
              ),
              if (widget.quickPaths.isNotEmpty) ...[
                const SizedBox(height: 8),
                SizedBox(
                  height: 32,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: widget.quickPaths.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 6),
                    itemBuilder: (context, index) {
                      final quickPath = widget.quickPaths[index];
                      return GestureDetector(
                        onTap: () => _open(quickPath),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: JXColors.primary.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: JXColors.primary.withValues(alpha: 0.3),
                            ),
                          ),
                          child: Text(
                            p.basename(quickPath).isEmpty
                                ? quickPath
                                : p.basename(quickPath),
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
              const SizedBox(height: 8),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.redAccent,
                    ),
                  ),
                ),
              Expanded(
                child: _loading
                    ? const Center(
                        child: CircularProgressIndicator(
                          color: JXColors.primary,
                          strokeWidth: 2,
                        ),
                      )
                    : _directories.isEmpty
                    ? Center(
                        child: Text(
                          '该目录下没有子目录',
                          style: TextStyle(fontSize: 12, color: textSub),
                        ),
                      )
                    : ListView.builder(
                        itemCount: _directories.length,
                        itemBuilder: (context, index) {
                          final path = _directories[index];
                          return ListTile(
                            dense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 4,
                            ),
                            leading: const Icon(
                              Icons.folder_rounded,
                              size: 20,
                              color: JXColors.primary,
                            ),
                            title: Text(
                              p.basename(path),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 13, color: textColor),
                            ),
                            onTap: () => _open(path),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _current,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10.5, color: textSub),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GlassButton(
                    text: '选择此目录',
                    primary: true,
                    height: 38,
                    onPressed: () => Navigator.of(context).pop(_current),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
