import 'package:flutter/material.dart';

/// 通用文本输入弹窗（歌单命名/重命名等），返回 null 表示取消
Future<String?> promptText(
  BuildContext context, {
  required String title,
  String initial = '',
  String hint = '',
  int maxLength = 30,
}) async {
  final result = await showDialog<String>(
    context: context,
    builder: (_) => _PromptTextDialog(
      title: title,
      initial: initial,
      hint: hint,
      maxLength: maxLength,
    ),
  );
  if (result == null || result.isEmpty) return null;
  return result;
}

/// controller 由对话框自身持有：showDialog 的 future 在 pop 时就完成，
/// 而退场动画还会跑 150~300ms，期间 TextField 仍连着 controller，
/// 提前 dispose 会触发 "used after being disposed" 断言。
class _PromptTextDialog extends StatefulWidget {
  const _PromptTextDialog({
    required this.title,
    required this.initial,
    required this.hint,
    required this.maxLength,
  });

  final String title;
  final String initial;
  final String hint;
  final int maxLength;

  @override
  State<_PromptTextDialog> createState() => _PromptTextDialogState();
}

class _PromptTextDialogState extends State<_PromptTextDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title, style: const TextStyle(fontSize: 16)),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: widget.maxLength,
        decoration: InputDecoration(hintText: widget.hint),
        onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

/// 通用二次确认弹窗
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String content,
  String confirmText = '确定',
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title, style: const TextStyle(fontSize: 16)),
      content: Text(content),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(confirmText),
        ),
      ],
    ),
  );
  return result ?? false;
}
