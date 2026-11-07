import 'package:flutter/material.dart';

/// 通用文本输入弹窗（歌单命名/重命名等），返回 null 表示取消
Future<String?> promptText(
  BuildContext context, {
  required String title,
  String initial = '',
  String hint = '',
  int maxLength = 30,
}) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title, style: const TextStyle(fontSize: 16)),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: maxLength,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (v) => Navigator.of(dialogContext).pop(v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(dialogContext).pop(controller.text.trim()),
          child: const Text('确定'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (result == null || result.isEmpty) return null;
  return result;
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
