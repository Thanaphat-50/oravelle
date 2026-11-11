import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

// =======================================================
// ตัวอย่างรูปจากกล้องก่อนส่ง
// คืนค่า: null = ยกเลิก / 'retake' = ถ่ายใหม่ / {'caption': ...} = ส่ง
// ข้อความที่พิมพ์ค้างไว้ในห้องแชทไม่ถูกแตะต้อง
// =======================================================

class ChatPhotoPreviewPage extends StatefulWidget {
  final XFile image;

  const ChatPhotoPreviewPage({super.key, required this.image});

  @override
  State<ChatPhotoPreviewPage> createState() => _ChatPhotoPreviewPageState();
}

class _ChatPhotoPreviewPageState extends State<ChatPhotoPreviewPage> {
  final TextEditingController caption = TextEditingController();

  @override
  void dispose() {
    caption.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('ตัวอย่างรูป'),
        leading: IconButton(
          tooltip: 'ยกเลิก',
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close_rounded),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: InteractiveViewer(
              child: Center(
                child: Semantics(
                  label: 'รูปที่ถ่าย',
                  image: true,
                  child: Image.file(File(widget.image.path)),
                ),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: () => Navigator.of(context).pop('retake'),
                    style: TextButton.styleFrom(foregroundColor: Colors.white),
                    icon: const Icon(Icons.replay_rounded),
                    label: const Text('ถ่ายใหม่'),
                  ),
                  Expanded(
                    child: TextField(
                      controller: caption,
                      maxLength: 2000,
                      minLines: 1,
                      maxLines: 3,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: 'ใส่คำบรรยาย...',
                        hintStyle: const TextStyle(color: Colors.white70),
                        counterText: '',
                        filled: true,
                        fillColor: Colors.white12,
                        isDense: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton.filled(
                    tooltip: 'ส่งรูป',
                    onPressed: () =>
                        Navigator.of(context).pop({'caption': caption.text}),
                    icon: const Icon(Icons.send_rounded),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
