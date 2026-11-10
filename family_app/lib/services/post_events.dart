import 'dart:async';

// =======================================================
// โพสต์เปลี่ยน → ทุกหน้าที่แสดงโพสต์นั้นอยู่อัปเดตตาม (ไม่ต้องโหลดใหม่ทั้งหน้า)
// ฟีด / โปรไฟล์ / รายละเอียดโพสต์ / ผลค้นหา / วิดีโอ / โพสต์ที่บันทึก
// รวมถึงส่วนแสดงต้นฉบับในโพสต์ที่แชร์ต่อ (shared_post ที่ id ตรงกัน)
// =======================================================

class PostChange {
  final int postId;

  // ค่าที่เปลี่ยน (รวมเข้ากับข้อมูลโพสต์เดิม) เช่น content, edited_at, edit_version
  final Map<String, dynamic> fields;

  const PostChange(this.postId, this.fields);
}

class PostEvents {
  static final StreamController<PostChange> _changes =
      StreamController<PostChange>.broadcast();

  static Stream<PostChange> get changes => _changes.stream;

  static void emit(int postId, Map<String, dynamic> fields) {
    _changes.add(PostChange(postId, fields));
  }

  // แก้ไขข้อความสำเร็จ → ส่งเฉพาะส่วนข้อความ (ยอดถูกใจ/ความคิดเห็นในหน้าเดิมไม่ถูกทับ)
  static void edited(Map<String, dynamic> post) {
    final dynamic id = post['id'];

    if (id is! num) return;

    emit(id.toInt(), {
      'content': post['content'],
      'edited_at': post['edited_at'],
      'edit_version': post['edit_version'],
    });
  }

  // รวมการเปลี่ยนแปลงเข้ากับรายการโพสต์ (ทั้งตัวโพสต์และต้นฉบับที่แชร์มา)
  // คืน true เมื่อมีโพสต์ในรายการตรงกัน (หน้าต้องวาดใหม่)
  static bool apply(List<Map<String, dynamic>> posts, PostChange change) {
    bool touched = false;

    for (final Map<String, dynamic> post in posts) {
      if (_idOf(post) == change.postId) {
        post.addAll(change.fields);
        touched = true;
      }

      final dynamic shared = post['shared_post'];

      if (shared is Map && _idOf(shared) == change.postId) {
        post['shared_post'] = {
          ...Map<String, dynamic>.from(shared),
          ...change.fields,
        };
        touched = true;
      }
    }

    return touched;
  }

  static int? _idOf(Map post) {
    final dynamic id = post['id'];

    return id is num ? id.toInt() : int.tryParse('${id ?? ''}');
  }
}
