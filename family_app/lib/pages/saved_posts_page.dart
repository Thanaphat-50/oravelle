import 'package:flutter/material.dart';

import 'feed_page.dart';

// =======================================================
// โพสต์ที่บันทึก (ส่วนตัว — คนอื่นและเจ้าของโพสต์ไม่เห็น)
// - ใช้การ์ดโพสต์เดียวกับฟีด / ล่าสุดก่อน / เลื่อนลงโหลดเพิ่ม / ดึงลงรีเฟรช
// - ยกเลิกบันทึกจากเมนู ⋯ แล้วหายจากรายการ / แตะการ์ดเพื่อเปิดโพสต์
// - โพสต์ที่หมดสิทธิ์ (ลบ ซ่อน บล็อก ออกจากกลุ่ม) เซิร์ฟเวอร์ไม่ส่งมา
// =======================================================

class SavedPostsPage extends StatelessWidget {
  const SavedPostsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('โพสต์ที่บันทึก')),
      body: const FeedPage(scope: FeedScope.community, savedOnly: true),
    );
  }
}
