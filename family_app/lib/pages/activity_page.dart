import 'package:flutter/material.dart';

import '../services/activity_service.dart';
import '../services/api_helper.dart';
import '../theme/app_theme.dart';

class ActivityPage extends StatefulWidget {
  const ActivityPage({super.key});

  @override
  State<ActivityPage> createState() => _ActivityPageState();
}

class _ActivityPageState extends State<ActivityPage> {
  bool isLoading = true;
  bool isCreating = false;

  bool hasFamily = false;

  List<dynamic> activities = [];

  // ตัวกรองทำงานบนเซิร์ฟเวอร์ (ทุกกิจกรรม ไม่ใช่เฉพาะที่โหลดมา)
  String selectedFilter = 'all';

  // แบ่งหน้า: โหลดเพิ่มเมื่อเลื่อนใกล้ท้ายรายการ
  int page = 1;
  bool hasMore = false;
  bool isLoadingMore = false;

  // จำนวนของแต่ละตัวกรอง (นับจากทุกกิจกรรมบนเซิร์ฟเวอร์)
  Map<String, int> counts = {};
  @override
  void initState() {
    super.initState();

    loadActivities();
  }

  // =====================================================
  // LOAD
  // =====================================================

  Future<void> loadActivities() async {
    final String filter = selectedFilter;

    try {
      final result = await ActivityService.getActivities(filter: filter);

      // ระหว่างรอ ผู้ใช้เปลี่ยนตัวกรองไปแล้ว → ไม่ใช้ผลเก่า
      if (!mounted || filter != selectedFilter) return;

      if (result['status'] == true) {
        final family = result['family'];

        setState(() {
          activities = result['activities'] ?? [];
          page = 1;
          hasMore = result['has_more'] == true;
          applyCounts(result['counts']);
          if (family is Map) {
            hasFamily = family['has_family'] == true;
          } else {
            hasFamily = false;
          }
        });
      } else {
        showMessage(result['message'] ?? 'โหลดกิจกรรมไม่สำเร็จ');
      }
    } catch (e) {
      if (!mounted) return;

      showMessage(ApiHelper.messageOf(e));
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  void applyCounts(dynamic raw) {
    if (raw is! Map) return;

    counts = {
      for (final entry in raw.entries)
        if (entry.value is num)
          entry.key.toString(): (entry.value as num).toInt(),
    };
  }

  // หน้าถัดไป (เลื่อนใกล้ท้ายรายการ)
  Future<void> loadMore() async {
    if (!hasMore || isLoadingMore || isLoading) return;

    final String filter = selectedFilter;

    setState(() => isLoadingMore = true);

    try {
      final result = await ActivityService.getActivities(
        page: page + 1,
        filter: filter,
      );

      if (!mounted || filter != selectedFilter) return;

      if (result['status'] == true) {
        final dynamic raw = result['activities'];

        setState(() {
          final Set<dynamic> known = activities
              .whereType<Map>()
              .map((item) => item['id'])
              .toSet();

          if (raw is List) {
            activities = [
              ...activities,
              ...raw.where(
                (item) => item is Map && !known.contains(item['id']),
              ),
            ];
          }

          page++;
          hasMore = result['has_more'] == true;
          applyCounts(result['counts']);
        });
      }
    } catch (e) {
      if (mounted) showMessage(ApiHelper.messageOf(e));
    } finally {
      if (mounted) setState(() => isLoadingMore = false);
    }
  }

  void changeFilter(String filter) {
    if (filter == selectedFilter) return;

    setState(() {
      selectedFilter = filter;
      activities = [];
      hasMore = false;
      isLoading = true;
    });

    loadActivities();
  }

  // =====================================================
  // HELPERS
  // =====================================================
  bool boolValue(dynamic value) {
    return value == true || value == 1 || value == '1';
  }

  bool canManage(Map<String, dynamic> activity) {
    return boolValue(activity['can_manage']);
  }

  bool isMine(Map<String, dynamic> activity) {
    return boolValue(activity['is_mine']);
  }

  bool isCompleted(Map<String, dynamic> activity) {
    return boolValue(activity['is_completed']);
  }

  String visibility(Map<String, dynamic> activity) {
    return activity['visibility']?.toString() ?? 'private';
  }

  String ownerName(Map<String, dynamic> activity) {
    final user = activity['user'];

    if (user is Map) {
      final name = user['name']?.toString().trim();

      if (name != null && name.isNotEmpty) {
        return name;
      }
    }

    return 'สมาชิก';
  }

  String? ownerImageUrl(Map<String, dynamic> activity) {
    final user = activity['user'];

    if (user is! Map) {
      return null;
    }

    const imageKeys = [
      'profile_image_url',
      'profile_image',
      'avatar_url',
      'avatar',
      'photo_url',
      'photo',
      'image_url',
      'image',
    ];

    String? imageUrl;

    for (final key in imageKeys) {
      final value = user[key]?.toString().trim();

      if (value != null && value.isNotEmpty && value.toLowerCase() != 'null') {
        imageUrl = value;
        break;
      }
    }

    if (imageUrl == null) {
      return null;
    }

    // ถ้า backend ส่ง updated_at มาด้วย จะช่วยบังคับให้ Flutter
    // โหลดรูปใหม่หลังผู้ใช้เปลี่ยนรูป แม้ URL รูปเดิมจะไม่เปลี่ยน
    final version =
        user['profile_image_updated_at']?.toString().trim() ??
        user['updated_at']?.toString().trim();

    if (version == null || version.isEmpty || version.toLowerCase() == 'null') {
      return imageUrl;
    }

    final separator = imageUrl.contains('?') ? '&' : '?';

    return '$imageUrl${separator}v=${Uri.encodeQueryComponent(version)}';
  }

  String ownerInitial(String name) {
    final cleanName = name.trim();

    if (cleanName.isEmpty) {
      return 'ส';
    }

    return cleanName.substring(0, 1).toUpperCase();
  }

  Widget buildOwnerAvatar({required String name, String? imageUrl}) {
    Widget fallback() {
      return Container(
        alignment: Alignment.center,
        color: AppColors.primary.withValues(alpha: 0.10),
        child: Text(
          ownerInitial(name),
          style: TextStyle(
            color: AppColors.primary,
            fontSize: 9,
            fontWeight: FontWeight.w800,
          ),
        ),
      );
    }

    return ClipOval(
      child: SizedBox(
        width: 20,
        height: 20,
        child: imageUrl == null
            ? fallback()
            : Image.network(
                imageUrl,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) {
                  return fallback();
                },
              ),
      ),
    );
  }

  // =====================================================
  // FILTER
  // =====================================================

  List<Map<String, dynamic>> get filteredActivities {
    final items = <Map<String, dynamic>>[];

    for (final item in activities) {
      if (item is! Map) {
        continue;
      }

      // เซิร์ฟเวอร์กรองตาม selectedFilter มาแล้ว
      items.add(Map<String, dynamic>.from(item));
    }

    return items;
  }

  // =====================================================
  // CREATE SHEET
  // =====================================================

  // เพิ่ม / แก้ไขกิจกรรม (editing = กิจกรรมที่แก้)
  // draft = ข้อมูลที่กรอกไว้ (บันทึกไม่สำเร็จ → เปิดฟอร์มเดิมพร้อมข้อมูลให้แก้แล้วกดใหม่)
  Future<void> showCreateActivitySheet({
    Map<String, dynamic>? editing,
    Map<String, dynamic>? draft,
  }) async {
    String title = (draft?['title'] ?? editing?['title'])?.toString() ?? '';
    String description =
        (draft?['description'] ?? editing?['description'])?.toString() ?? '';

    String selectedVisibility = draft?['visibility']?.toString() ?? 'private';

    DateTime? selectedDateTime = draft != null
        ? draft['activity_date'] as DateTime?
        : parseDate(editing?['activity_date']);

    final bool isEdit = editing != null;

    final titleController = TextEditingController(text: title);
    final descriptionController = TextEditingController(text: description);
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,

      isScrollControlled: true,

      backgroundColor: Colors.transparent,

      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            Future<void> selectDateTime() async {
              final now = DateTime.now();

              final date = await showDatePicker(
                context: context,

                initialDate: selectedDateTime ?? now,

                firstDate: DateTime(now.year - 1),

                lastDate: DateTime(now.year + 5),
              );

              if (date == null || !context.mounted) {
                return;
              }

              final time = await showTimePicker(
                context: context,

                initialTime: selectedDateTime != null
                    ? TimeOfDay.fromDateTime(selectedDateTime!)
                    : TimeOfDay.now(),
              );

              if (time == null) {
                return;
              }

              setSheetState(() {
                selectedDateTime = DateTime(
                  date.year,
                  date.month,
                  date.day,
                  time.hour,
                  time.minute,
                );
              });
            }

            return Container(
              margin: const EdgeInsets.only(top: 55),

              decoration: BoxDecoration(
                color: AppColors.surface,

                borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
              ),

              child: SafeArea(
                top: false,

                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    22,
                    12,
                    22,
                    MediaQuery.of(context).viewInsets.bottom + 25,
                  ),

                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,

                    children: [
                      // =================================
                      // HANDLE
                      // =================================

                      Center(
                        child: Container(
                          width: 40,
                          height: 4,

                          decoration: BoxDecoration(
                            color: AppColors.border,

                            borderRadius: BorderRadius.circular(99),
                          ),
                        ),
                      ),

                      const SizedBox(height: 22),

                      // =================================
                      // HEADER
                      // =================================
                      Row(
                        children: [
                          Container(
                            width: 48,
                            height: 48,

                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [AppColors.primary, Color(0xFF777CFF)],
                              ),

                              borderRadius: BorderRadius.circular(16),
                            ),

                            child: const Icon(
                              Icons.event_available_rounded,
                              color: Colors.white,
                            ),
                          ),

                          const SizedBox(width: 13),

                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,

                              children: [
                                Text(
                                  isEdit ? 'แก้ไขกิจกรรม' : 'เพิ่มกิจกรรม',
                                  style: TextStyle(
                                    color: AppColors.navy,
                                    fontSize: 21,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),

                                SizedBox(height: 3),

                                Text(
                                  isEdit
                                      ? 'แก้ชื่อ รายละเอียด หรือวันเวลา'
                                      : 'สร้างแผนของคุณหรือแชร์ให้กลุ่ม',
                                  style: TextStyle(
                                    color: AppColors.muted,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),

                          IconButton(
                            onPressed: () {
                              Navigator.of(sheetContext).pop();
                            },

                            icon: const Icon(Icons.close_rounded),
                          ),
                        ],
                      ),

                      const SizedBox(height: 25),

                      // =================================
                      // TITLE
                      // =================================
                      Text(
                        'ชื่อกิจกรรม',
                        style: TextStyle(
                          color: AppColors.navy,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),

                      const SizedBox(height: 8),

                      TextField(
                        controller: titleController,

                        autofocus: !isEdit,

                        textInputAction: TextInputAction.next,

                        onChanged: (value) {
                          title = value;
                        },

                        decoration: const InputDecoration(
                          hintText: 'เช่น กินข้าวเย็นด้วยกัน',

                          prefixIcon: Icon(Icons.edit_calendar_outlined),
                        ),
                      ),

                      const SizedBox(height: 18),

                      // =================================
                      // DESCRIPTION
                      // =================================
                      Text(
                        'รายละเอียด',
                        style: TextStyle(
                          color: AppColors.navy,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),

                      const SizedBox(height: 8),

                      TextField(
                        controller: descriptionController,

                        minLines: 3,
                        maxLines: 5,

                        onChanged: (value) {
                          description = value;
                        },

                        decoration: const InputDecoration(
                          hintText: 'รายละเอียดเพิ่มเติม...',

                          alignLabelWithHint: true,
                        ),
                      ),

                      const SizedBox(height: 20),

                      // =================================
                      // VISIBILITY (แก้ไข: เปลี่ยนที่เมนู ส่วนตัว/แชร์กลุ่ม)
                      // =================================
                      if (!isEdit) ...[
                        Text(
                          'ใครสามารถเห็นกิจกรรมนี้?',
                          style: TextStyle(
                            color: AppColors.navy,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),

                        const SizedBox(height: 5),

                        Text(
                          'เลือกว่ากิจกรรมนี้เป็นเรื่องส่วนตัวหรือแชร์กับกลุ่ม',
                          style: TextStyle(
                            color: AppColors.muted,
                            fontSize: 10,
                          ),
                        ),

                        const SizedBox(height: 12),

                        Row(
                          children: [
                            Expanded(
                              child: _VisibilityChoice(
                                icon: Icons.lock_outline_rounded,

                                title: 'ส่วนตัว',

                                subtitle: 'เฉพาะคุณ',

                                selected: selectedVisibility == 'private',

                                onTap: () {
                                  setSheetState(() {
                                    selectedVisibility = 'private';
                                  });
                                },
                              ),
                            ),

                            const SizedBox(width: 10),

                            Expanded(
                              child: _VisibilityChoice(
                                icon: Icons.groups_rounded,

                                title: 'กลุ่ม',

                                subtitle: hasFamily
                                    ? 'สมาชิกเห็นได้'
                                    : 'ยังไม่มี Family',

                                selected: selectedVisibility == 'family',

                                enabled: hasFamily,

                                onTap: () {
                                  if (!hasFamily) {
                                    return;
                                  }

                                  setSheetState(() {
                                    selectedVisibility = 'family';
                                  });
                                },
                              ),
                            ),
                          ],
                        ),

                        if (!hasFamily) ...[
                          const SizedBox(height: 10),

                          Container(
                            padding: const EdgeInsets.all(11),

                            decoration: BoxDecoration(
                              color: AppColors.warm.withValues(alpha: 0.10),

                              borderRadius: BorderRadius.circular(14),
                            ),

                            child: Row(
                              children: [
                                Icon(
                                  Icons.info_outline_rounded,
                                  color: AppColors.warm,
                                  size: 18,
                                ),

                                SizedBox(width: 8),

                                Expanded(
                                  child: Text(
                                    'เข้าร่วมหรือสร้างกลุ่มก่อน จึงจะแชร์กิจกรรมได้',
                                    style: TextStyle(
                                      color: AppColors.muted,
                                      fontSize: 10,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                      const SizedBox(height: 20),

                      // =================================
                      // DATE
                      // =================================
                      Text(
                        'วันและเวลา',
                        style: TextStyle(
                          color: AppColors.navy,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),

                      const SizedBox(height: 8),

                      InkWell(
                        onTap: selectDateTime,

                        borderRadius: BorderRadius.circular(18),

                        child: Container(
                          padding: const EdgeInsets.all(15),

                          decoration: BoxDecoration(
                            color: AppColors.fill,

                            borderRadius: BorderRadius.circular(18),

                            border: Border.all(color: AppColors.border),
                          ),

                          child: Row(
                            children: [
                              Container(
                                width: 42,
                                height: 42,

                                decoration: BoxDecoration(
                                  color: AppColors.primary.withValues(
                                    alpha: 0.09,
                                  ),

                                  borderRadius: BorderRadius.circular(13),
                                ),

                                child: Icon(
                                  Icons.calendar_month_rounded,
                                  color: AppColors.primary,
                                ),
                              ),

                              const SizedBox(width: 12),

                              Expanded(
                                child: Text(
                                  selectedDateTime == null
                                      ? 'เลือกวันและเวลา'
                                      : formatDateTime(selectedDateTime!),

                                  style: TextStyle(
                                    color: selectedDateTime == null
                                        ? AppColors.muted
                                        : AppColors.navy,

                                    fontSize: 12,

                                    fontWeight: selectedDateTime == null
                                        ? FontWeight.w500
                                        : FontWeight.w700,
                                  ),
                                ),
                              ),

                              Icon(
                                Icons.chevron_right_rounded,
                                color: AppColors.muted,
                              ),
                            ],
                          ),
                        ),
                      ),

                      if (selectedDateTime != null)
                        Align(
                          alignment: Alignment.centerRight,

                          child: TextButton(
                            onPressed: () {
                              setSheetState(() {
                                selectedDateTime = null;
                              });
                            },

                            child: const Text('ล้างวันและเวลา'),
                          ),
                        ),

                      const SizedBox(height: 23),

                      // =================================
                      // CREATE
                      // =================================
                      ElevatedButton.icon(
                        onPressed: () {
                          final cleanTitle = title.trim();

                          if (cleanTitle.isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('กรุณาใส่ชื่อกิจกรรม'),
                              ),
                            );

                            return;
                          }

                          Navigator.of(sheetContext).pop({
                            'title': cleanTitle,

                            'description': description.trim(),

                            'activity_date': selectedDateTime,

                            'visibility': selectedVisibility,
                          });
                        },

                        icon: Icon(
                          isEdit
                              ? Icons.save_outlined
                              : selectedVisibility == 'family'
                              ? Icons.group_add_rounded
                              : Icons.add_task_rounded,
                        ),
                        label: Text(
                          isEdit
                              ? 'บันทึกการแก้ไข'
                              : selectedVisibility == 'family'
                              ? 'สร้างและแชร์กับกลุ่ม'
                              : 'สร้างกิจกรรมส่วนตัว',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    // ทิ้ง controller หลังฟอร์มปิดเสร็จ (ระหว่างแอนิเมชันปิด ช่องกรอกยังใช้อยู่)
    Future<void>.delayed(const Duration(seconds: 1), () {
      titleController.dispose();
      descriptionController.dispose();
    });

    if (!mounted || result == null) {
      return;
    }

    await Future<void>.delayed(const Duration(milliseconds: 250));

    if (!mounted) return;

    final bool saved = isEdit
        ? await updateActivity(editing, result)
        : await createActivity(
            title: result['title'].toString(),
            description: result['description']?.toString() ?? '',
            activityDate: result['activity_date'] as DateTime?,
            visibility: result['visibility']?.toString() ?? 'private',
          );

    // บันทึกไม่สำเร็จ → เปิดฟอร์มเดิมพร้อมข้อมูลที่กรอกไว้ (ปิดฟอร์มได้ถ้าไม่ต้องการ)
    if (!saved && mounted) {
      await showCreateActivitySheet(editing: editing, draft: result);
    }
  }

  // =====================================================
  // UPDATE API
  // =====================================================

  Future<bool> updateActivity(
    Map<String, dynamic> activity,
    Map<String, dynamic> values,
  ) async {
    final dynamic id = activity['id'];

    if (id is! num) return true;

    setState(() => isCreating = true);

    try {
      final String description = values['description']?.toString() ?? '';

      final result = await ActivityService.updateActivity(
        activityId: id.toInt(),
        title: values['title'].toString(),
        description: description.isEmpty ? null : description,
        activityDate: values['activity_date'] as DateTime?,
      );

      if (!mounted) return true;

      if (result['status'] == true) {
        await loadActivities();

        if (mounted) showMessage('บันทึกการแก้ไขแล้ว');

        return true;
      }

      showMessage(result['message']?.toString() ?? 'บันทึกไม่สำเร็จ');

      // ข้อมูลไม่ถูกต้อง (422) → เปิดฟอร์มเดิมให้แก้
      // ไม่มีสิทธิ์แล้ว (ออกจากกลุ่ม / ถูกลบ) → ไม่ต้องเปิดฟอร์มซ้ำ
      return result['errors'] == null;
    } catch (e) {
      if (mounted) showMessage(ApiHelper.messageOf(e));

      return false;
    } finally {
      if (mounted) setState(() => isCreating = false);
    }
  }

  // =====================================================
  // CREATE API
  // =====================================================

  Future<bool> createActivity({
    required String title,
    required String description,
    required String visibility,
    DateTime? activityDate,
  }) async {
    setState(() {
      isCreating = true;
    });

    try {
      final result = await ActivityService.createActivity(
        title: title,

        description: description.isEmpty ? null : description,

        activityDate: activityDate,

        visibility: visibility,
      );

      if (!mounted) return true;

      if (result['status'] == true) {
        await loadActivities();

        if (!mounted) return true;

        showMessage(
          visibility == 'family'
              ? 'แชร์กิจกรรมกับกลุ่มแล้ว'
              : 'สร้างกิจกรรมส่วนตัวแล้ว',
        );

        return true;
      }

      showMessage(result['message']?.toString() ?? 'เพิ่มกิจกรรมไม่สำเร็จ');

      return false;
    } catch (e) {
      if (mounted) showMessage(ApiHelper.messageOf(e));

      return false;
    } finally {
      if (mounted) {
        setState(() {
          isCreating = false;
        });
      }
    }
  }

  // =====================================================
  // TOGGLE
  // =====================================================

  Future<void> toggleActivity(Map<String, dynamic> activity) async {
    if (!canManage(activity)) {
      showMessage('เฉพาะผู้สร้างกิจกรรมเท่านั้นที่เปลี่ยนสถานะได้');

      return;
    }

    final id = activity['id'];

    if (id is! num) {
      return;
    }

    try {
      final result = await ActivityService.toggleActivity(id.toInt());

      if (!mounted) return;

      if (result['status'] == true) {
        await loadActivities();
      } else {
        showMessage(result['message'] ?? 'อัปเดตกิจกรรมไม่สำเร็จ');
      }
    } catch (e) {
      if (!mounted) return;

      showMessage('เกิดข้อผิดพลาด: $e');
    }
  }

  // =====================================================
  // CHANGE VISIBILITY
  // =====================================================

  Future<void> changeVisibility(
    Map<String, dynamic> activity,
    String newVisibility,
  ) async {
    if (!canManage(activity)) {
      showMessage('เฉพาะผู้สร้างกิจกรรมเท่านั้นที่เปลี่ยนการมองเห็นได้');

      return;
    }

    final id = activity['id'];

    if (id is! num) {
      return;
    }

    if (newVisibility == 'family' && !hasFamily) {
      showMessage('คุณต้องมีกลุ่มก่อนจึงจะแชร์กิจกรรมได้');

      return;
    }

    try {
      final result = await ActivityService.updateVisibility(
        activityId: id.toInt(),

        visibility: newVisibility,
      );

      if (!mounted) return;

      if (result['status'] == true) {
        await loadActivities();

        if (!mounted) return;

        showMessage(
          newVisibility == 'family'
              ? 'แชร์กิจกรรมกับกลุ่มแล้ว'
              : 'เปลี่ยนเป็นกิจกรรมส่วนตัวแล้ว',
        );
      } else {
        showMessage(result['message'] ?? 'เปลี่ยนการมองเห็นไม่สำเร็จ');
      }
    } catch (e) {
      if (!mounted) return;

      showMessage('เกิดข้อผิดพลาด: $e');
    }
  }

  // =====================================================
  // DELETE
  // =====================================================

  Future<void> deleteActivity(Map<String, dynamic> activity) async {
    if (!canManage(activity)) {
      showMessage('เฉพาะผู้สร้างกิจกรรมเท่านั้นที่ลบได้');
      return;
    }

    final id = activity['id'];

    if (id is! num) {
      return;
    }

    final title = activity['title']?.toString() ?? 'กิจกรรม';

    final confirm = await showDialog<bool>(
      context: context,

      builder: (dialogContext) {
        return AlertDialog(
          icon: Icon(
            Icons.delete_outline_rounded,

            color: AppColors.danger,

            size: 38,
          ),

          title: const Text('ลบกิจกรรม?', textAlign: TextAlign.center),

          content: Text(
            'ต้องการลบ “$title” หรือไม่?',
            textAlign: TextAlign.center,
          ),

          actionsAlignment: MainAxisAlignment.center,

          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(false);
              },

              child: const Text('ยกเลิก'),
            ),

            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),

              onPressed: () {
                Navigator.of(dialogContext).pop(true);
              },

              child: const Text('ลบ'),
            ),
          ],
        );
      },
    );

    if (confirm != true || !mounted) {
      return;
    }

    await Future<void>.delayed(const Duration(milliseconds: 250));

    try {
      final result = await ActivityService.deleteActivity(id.toInt());

      if (!mounted) return;

      if (result['status'] == true) {
        await loadActivities();

        if (!mounted) return;

        showMessage('ลบกิจกรรมแล้ว');
      } else {
        showMessage(result['message'] ?? 'ลบกิจกรรมไม่สำเร็จ');
      }
    } catch (e) {
      if (!mounted) return;

      showMessage('เกิดข้อผิดพลาด: $e');
    }
  }

  // =====================================================
  // DATE
  // =====================================================

  static String formatDateTime(DateTime date) {
    const months = [
      '',
      'ม.ค.',
      'ก.พ.',
      'มี.ค.',
      'เม.ย.',
      'พ.ค.',
      'มิ.ย.',
      'ก.ค.',
      'ส.ค.',
      'ก.ย.',
      'ต.ค.',
      'พ.ย.',
      'ธ.ค.',
    ];

    final hour = date.hour.toString().padLeft(2, '0');

    final minute = date.minute.toString().padLeft(2, '0');

    return '${date.day} '
        '${months[date.month]} '
        '${date.year} • '
        '$hour:$minute น.';
  }

  DateTime? parseDate(dynamic value) {
    if (value == null) {
      return null;
    }

    try {
      return DateTime.parse(value.toString()).toLocal();
    } catch (_) {
      return null;
    }
  }

  String activityDateText(dynamic value) {
    final date = parseDate(value);

    if (date == null) {
      return 'ไม่กำหนดเวลา';
    }

    return formatDateTime(date);
  }

  // =====================================================
  // PLANNER HEADER
  // =====================================================

  // ตัวเลขจากเซิร์ฟเวอร์ (นับทุกกิจกรรม ไม่ใช่เฉพาะหน้าที่โหลด)
  Widget buildPlannerHeader() {
    final total = counts['all'] ?? activities.length;

    final completed = counts['completed'] ?? 0;

    final familyCount = counts['family'] ?? 0;
    final progress = total == 0 ? 0.0 : completed / total;

    return Container(
      padding: const EdgeInsets.all(22),

      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF172554), Color(0xFF4650D8), Color(0xFF656BFF)],
        ),

        borderRadius: BorderRadius.circular(28),

        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.20),
            blurRadius: 30,
            offset: const Offset(0, 12),
          ),
        ],
      ),

      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,

        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),

                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.13),

                  borderRadius: BorderRadius.circular(99),
                ),

                child: const Text(
                  'FAMILY PLANNER',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.3,
                  ),
                ),
              ),

              const Spacer(),

              Text(
                '${(progress * 100).round()}%',

                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 23,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),

          const Text(
            'ทุกแผนสำคัญ\nเมื่อทำไปด้วยกัน',
            style: TextStyle(
              color: Colors.white,
              fontSize: 25,
              height: 1.18,
              fontWeight: FontWeight.w800,
            ),
          ),

          const SizedBox(height: 18),

          ClipRRect(
            borderRadius: BorderRadius.circular(99),

            child: LinearProgressIndicator(
              value: progress,

              minHeight: 8,

              backgroundColor: Colors.white.withValues(alpha: 0.14),

              valueColor: AlwaysStoppedAnimation<Color>(AppColors.warm),
            ),
          ),

          const SizedBox(height: 17),

          Row(
            children: [
              _PlannerStat(value: '$total', label: 'ทั้งหมด'),

              const SizedBox(width: 8),

              _PlannerStat(value: '$completed', label: 'สำเร็จ'),

              const SizedBox(width: 8),

              _PlannerStat(value: '$familyCount', label: 'แชร์แล้ว'),
            ],
          ),
        ],
      ),
    );
  }

  // =====================================================
  // FILTERS
  // =====================================================

  // ตัวกรอง (เซิร์ฟเวอร์กรองจากกิจกรรมทั้งหมด) + จำนวนของแต่ละตัวกรอง
  Widget buildFilters() {
    const List<(String, String, IconData?)> filters = [
      ('all', 'ทั้งหมด', null),
      ('today', 'วันนี้', Icons.today_rounded),
      ('overdue', 'เกินกำหนด', Icons.alarm_rounded),
      ('completed', 'เสร็จแล้ว', Icons.task_alt_rounded),
      ('mine', 'ของฉัน', Icons.person_rounded),
      ('family', 'กลุ่ม', Icons.groups_rounded),
    ];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final (key, label, icon) in filters) ...[
            _FilterChip(
              text: switch (counts[key]) {
                final int count when key != 'all' && count > 0 =>
                  '$label $count',
                _ => label,
              },
              icon: icon,
              selected: selectedFilter == key,
              onTap: () => changeFilter(key),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  // =====================================================
  // ACTIVITY CARD
  // =====================================================

  Widget buildActivityCard(Map<String, dynamic> activity) {
    final completed = isCompleted(activity);

    final mine = isMine(activity);

    final manageable = canManage(activity);

    final shared = visibility(activity) == 'family';

    final creator = ownerName(activity);

    final creatorImageUrl = ownerImageUrl(activity);

    final title = activity['title']?.toString() ?? 'กิจกรรม';

    final description = activity['description']?.toString() ?? '';

    return AnimatedOpacity(
      opacity: completed ? 0.72 : 1,

      duration: const Duration(milliseconds: 200),

      child: Container(
        margin: const EdgeInsets.only(bottom: 12),

        padding: const EdgeInsets.fromLTRB(14, 14, 8, 14),

        decoration: BoxDecoration(
          color: AppColors.surface,

          borderRadius: BorderRadius.circular(22),

          border: AppDecorations.cardBorder,

          boxShadow: [
            BoxShadow(
              color: AppColors.navy.withValues(alpha: 0.03),

              blurRadius: 18,

              offset: const Offset(0, 7),
            ),
          ],
        ),

        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,

          children: [
            // ===========================================
            // STATUS ICON
            // ===========================================

            InkWell(
              onTap: manageable
                  ? () {
                      toggleActivity(activity);
                    }
                  : null,

              borderRadius: BorderRadius.circular(99),

              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),

                width: 46,
                height: 46,

                decoration: BoxDecoration(
                  color: completed
                      ? AppColors.success
                      : shared
                      ? AppColors.sky.withValues(alpha: 0.12)
                      : AppColors.primary.withValues(alpha: 0.09),

                  shape: BoxShape.circle,
                ),

                child: Icon(
                  completed
                      ? Icons.check_rounded
                      : shared
                      ? Icons.groups_rounded
                      : Icons.lock_outline_rounded,

                  color: completed
                      ? Colors.white
                      : shared
                      ? AppColors.sky
                      : AppColors.primary,
                ),
              ),
            ),

            const SizedBox(width: 13),

            // ===========================================
            // CONTENT
            // ===========================================
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,

                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,

                          style: TextStyle(
                            color: AppColors.navy,

                            fontSize: 15,

                            fontWeight: FontWeight.w800,

                            decoration: completed
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                        ),
                      ),

                      _VisibilityBadge(family: shared),
                    ],
                  ),

                  const SizedBox(height: 7),

                  Row(
                    children: [
                      buildOwnerAvatar(
                        name: creator,
                        imageUrl: creatorImageUrl,
                      ),

                      const SizedBox(width: 7),

                      Expanded(
                        child: Text(
                          mine ? 'สร้างโดยคุณ' : 'สร้างโดย $creator',

                          maxLines: 1,

                          overflow: TextOverflow.ellipsis,

                          style: TextStyle(
                            color: AppColors.muted,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ],
                  ),

                  if (description.isNotEmpty) ...[
                    const SizedBox(height: 8),

                    Text(
                      description,

                      style: TextStyle(
                        color: AppColors.muted,

                        fontSize: 12,

                        height: 1.4,
                      ),
                    ),
                  ],

                  const SizedBox(height: 10),

                  Row(
                    children: [
                      Icon(
                        Icons.schedule_rounded,

                        color: AppColors.muted,

                        size: 14,
                      ),

                      const SizedBox(width: 5),

                      Expanded(
                        child: Text(
                          activityDateText(activity['activity_date']),

                          style: TextStyle(
                            color: AppColors.muted,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ],
                  ),

                  if (!manageable && shared) ...[
                    const SizedBox(height: 9),

                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 6,
                      ),

                      decoration: BoxDecoration(
                        color: AppColors.sky.withValues(alpha: 0.07),

                        borderRadius: BorderRadius.circular(10),
                      ),

                      child: Row(
                        mainAxisSize: MainAxisSize.min,

                        children: [
                          Icon(
                            Icons.visibility_outlined,

                            color: AppColors.sky,

                            size: 13,
                          ),

                          SizedBox(width: 5),

                          Text(
                            'กิจกรรมที่แชร์โดยสมาชิก',

                            style: TextStyle(
                              color: AppColors.muted,
                              fontSize: 9,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),

            // ===========================================
            // OWNER MENU
            // ===========================================
            if (manageable)
              PopupMenuButton<String>(
                tooltip: 'จัดการ',

                onSelected: (value) {
                  if (value == 'edit') {
                    showCreateActivitySheet(editing: activity);
                  }

                  if (value == 'toggle') {
                    toggleActivity(activity);
                  }
                  if (value == 'private') {
                    changeVisibility(activity, 'private');
                  }

                  if (value == 'family') {
                    changeVisibility(activity, 'family');
                  }

                  if (value == 'delete') {
                    deleteActivity(activity);
                  }
                },

                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'edit',

                    child: Row(
                      children: [
                        Icon(Icons.edit_outlined, color: AppColors.primary),

                        const SizedBox(width: 10),

                        const Text('แก้ไข'),
                      ],
                    ),
                  ),

                  PopupMenuItem(
                    value: 'toggle',

                    child: Row(
                      children: [
                        Icon(
                          completed
                              ? Icons.restart_alt_rounded
                              : Icons.check_circle_outline_rounded,

                          color: AppColors.primary,
                        ),

                        const SizedBox(width: 10),

                        Text(completed ? 'ทำอีกครั้ง' : 'ทำเสร็จแล้ว'),
                      ],
                    ),
                  ),

                  if (shared)
                    PopupMenuItem(
                      value: 'private',

                      child: Row(
                        children: [
                          Icon(
                            Icons.lock_outline_rounded,

                            color: AppColors.primary,
                          ),

                          SizedBox(width: 10),

                          Text('เปลี่ยนเป็นส่วนตัว'),
                        ],
                      ),
                    )
                  else
                    PopupMenuItem(
                      value: 'family',

                      enabled: hasFamily,

                      child: Row(
                        children: [
                          Icon(
                            Icons.groups_rounded,

                            color: hasFamily ? AppColors.sky : AppColors.muted,
                          ),

                          const SizedBox(width: 10),

                          Text(hasFamily ? 'แชร์กับกลุ่ม' : 'ยังไม่มีกลุ่ม'),
                        ],
                      ),
                    ),

                  const PopupMenuDivider(),

                  PopupMenuItem(
                    value: 'delete',

                    child: Row(
                      children: [
                        Icon(
                          Icons.delete_outline_rounded,

                          color: AppColors.danger,
                        ),

                        SizedBox(width: 10),

                        Text('ลบกิจกรรม'),
                      ],
                    ),
                  ),
                ],
              )
            else
              Padding(
                padding: EdgeInsets.only(top: 12, right: 8),

                child: Icon(
                  Icons.visibility_outlined,

                  color: AppColors.muted,

                  size: 18,
                ),
              ),
          ],
        ),
      ),
    );
  }

  // =====================================================
  // EMPTY
  // =====================================================

  // ตัวกรองนี้ไม่มีกิจกรรม (ยังมีในตัวกรองอื่น)
  Widget buildFilterEmpty() {
    const Map<String, String> messages = {
      'mine': 'ยังไม่มีกิจกรรมที่คุณสร้าง',
      'family': 'ยังไม่มีกิจกรรมที่แชร์ในกลุ่ม',
      'today': 'วันนี้ไม่มีกิจกรรม',
      'overdue': 'ไม่มีกิจกรรมที่เกินกำหนด เยี่ยมมาก!',
      'completed': 'ยังไม่มีกิจกรรมที่ทำเสร็จ',
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 50, horizontal: 20),
      child: Column(
        children: [
          Icon(Icons.filter_alt_off_outlined, size: 40, color: AppColors.muted),
          const SizedBox(height: 10),
          Text(
            messages[selectedFilter] ?? 'ไม่มีกิจกรรม',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.muted, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget buildEmptyState() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 25, vertical: 45),

      decoration: BoxDecoration(
        color: AppColors.surface,

        borderRadius: BorderRadius.circular(25),

        border: AppDecorations.cardBorder,
        boxShadow: AppDecorations.cardShadow,
      ),

      child: Column(
        children: [
          Container(
            width: 82,
            height: 82,

            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.08),

              shape: BoxShape.circle,
            ),

            child: Icon(
              Icons.calendar_month_outlined,

              color: AppColors.primary,

              size: 37,
            ),
          ),

          const SizedBox(height: 18),

          Text(
            'ยังไม่มีกิจกรรม',
            style: TextStyle(
              color: AppColors.navy,
              fontSize: 19,
              fontWeight: FontWeight.w800,
            ),
          ),

          const SizedBox(height: 7),

          Text(
            'สร้างกิจกรรมส่วนตัว หรือแชร์แผนให้กลุ่มได้',

            textAlign: TextAlign.center,

            style: TextStyle(color: AppColors.muted, fontSize: 12),
          ),

          const SizedBox(height: 20),

          SizedBox(
            width: 210,

            child: ElevatedButton.icon(
              onPressed: showCreateActivitySheet,

              icon: const Icon(Icons.add_rounded),

              label: const Text('เพิ่มกิจกรรม'),
            ),
          ),
        ],
      ),
    );
  }

  // =====================================================
  // MESSAGE
  // =====================================================

  void showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // =====================================================
  // UI
  // =====================================================

  @override
  Widget build(BuildContext context) {
    final displayed = filteredActivities;

    return Scaffold(
      backgroundColor: Colors.transparent,

      // ยังไม่มีกิจกรรม → ใช้ปุ่มในการ์ดว่างแทน (ไม่ให้มีปุ่มซ้อนกัน 2 ปุ่ม)
      floatingActionButton:
          displayed.isEmpty && !isLoading && selectedFilter == 'all'
          ? null
          : FloatingActionButton.extended(
              heroTag: 'add_activity',

              onPressed: isCreating ? null : showCreateActivitySheet,

              icon: isCreating
                  ? const SizedBox(
                      width: 18,
                      height: 18,

                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.add_rounded),

              label: const Text('เพิ่มกิจกรรม'),
            ),

      body: RefreshIndicator(
        color: AppColors.primary,
        onRefresh: loadActivities,
        // เลื่อนใกล้ท้ายรายการ → โหลดหน้าถัดไป
        child: NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification.metrics.extentAfter < 400) loadMore();

            return false;
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),

            padding: const EdgeInsets.fromLTRB(17, 12, 17, 105),

            children: [
              buildPlannerHeader(),

              const SizedBox(height: 25),

              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,

                      children: [
                        Text(
                          'กิจกรรม',
                          style: TextStyle(
                            color: AppColors.navy,
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),

                        SizedBox(height: 3),

                        Text(
                          'แผนส่วนตัวและกิจกรรมของกลุ่ม',

                          style: TextStyle(
                            color: AppColors.muted,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),

                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 5,
                    ),

                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.09),

                      borderRadius: BorderRadius.circular(99),
                    ),

                    child: Text(
                      '${counts[selectedFilter] ?? displayed.length} รายการ',

                      style: TextStyle(
                        color: AppColors.primary,

                        fontSize: 10,

                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 14),

              buildFilters(),

              const SizedBox(height: 15),

              if (isLoading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 60),

                  child: Center(child: CircularProgressIndicator()),
                )
              else if (displayed.isEmpty)
                selectedFilter == 'all' ? buildEmptyState() : buildFilterEmpty()
              else ...[
                ...displayed.map(buildActivityCard),
                if (isLoadingMore)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 18),
                    child: Center(child: CircularProgressIndicator()),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// =======================================================
// VISIBILITY SELECTOR
// =======================================================

class _VisibilityChoice extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  final bool selected;
  final bool enabled;

  final VoidCallback onTap;

  const _VisibilityChoice({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onTap : null,

      borderRadius: BorderRadius.circular(18),

      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),

        padding: const EdgeInsets.all(14),

        decoration: BoxDecoration(
          color: !enabled
              ? AppColors.fill
              : selected
              ? AppColors.primary.withValues(alpha: 0.08)
              : AppColors.surface,

          borderRadius: BorderRadius.circular(18),

          border: Border.all(
            color: selected && enabled ? AppColors.primary : AppColors.border,

            width: selected && enabled ? 1.5 : 1,
          ),
        ),

        child: Column(
          children: [
            Container(
              width: 42,
              height: 42,

              decoration: BoxDecoration(
                color: selected && enabled ? AppColors.primary : AppColors.fill,

                shape: BoxShape.circle,
              ),

              child: Icon(
                icon,

                color: selected && enabled ? Colors.white : AppColors.muted,

                size: 20,
              ),
            ),

            const SizedBox(height: 9),

            Text(
              title,

              style: TextStyle(
                color: enabled ? AppColors.navy : AppColors.muted,

                fontSize: 13,

                fontWeight: FontWeight.w800,
              ),
            ),

            const SizedBox(height: 3),

            Text(
              subtitle,

              textAlign: TextAlign.center,

              style: TextStyle(color: AppColors.muted, fontSize: 9),
            ),
          ],
        ),
      ),
    );
  }
}

// =======================================================
// VISIBILITY BADGE
// =======================================================

class _VisibilityBadge extends StatelessWidget {
  final bool family;

  const _VisibilityBadge({required this.family});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 7),

      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),

      decoration: BoxDecoration(
        color: family
            ? AppColors.sky.withValues(alpha: 0.10)
            : AppColors.primary.withValues(alpha: 0.08),

        borderRadius: BorderRadius.circular(99),
      ),

      child: Row(
        mainAxisSize: MainAxisSize.min,

        children: [
          Icon(
            family ? Icons.groups_rounded : Icons.lock_outline_rounded,

            color: family ? AppColors.sky : AppColors.primary,

            size: 11,
          ),

          const SizedBox(width: 4),

          Text(
            family ? 'กลุ่ม' : 'ส่วนตัว',

            style: TextStyle(
              color: family ? AppColors.sky : AppColors.primary,

              fontSize: 8,

              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

// =======================================================
// FILTER
// =======================================================

class _FilterChip extends StatelessWidget {
  final String text;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;

  const _FilterChip({
    required this.text,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,

      borderRadius: BorderRadius.circular(99),

      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),

        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),

        decoration: BoxDecoration(
          color: selected ? AppColors.primary : AppColors.surface,

          borderRadius: BorderRadius.circular(99),

          border: Border.all(
            color: selected ? AppColors.primary : AppColors.border,
          ),
        ),

        child: Row(
          mainAxisSize: MainAxisSize.min,

          children: [
            if (icon != null) ...[
              Icon(
                icon,

                size: 15,

                color: selected ? Colors.white : AppColors.muted,
              ),

              const SizedBox(width: 5),
            ],

            Text(
              text,

              style: TextStyle(
                color: selected ? Colors.white : AppColors.muted,

                fontSize: 11,

                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =======================================================
// PLANNER STAT
// =======================================================

class _PlannerStat extends StatelessWidget {
  final String value;
  final String label;

  const _PlannerStat({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),

        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.10),

          borderRadius: BorderRadius.circular(15),
        ),

        child: Column(
          children: [
            Text(
              value,

              style: const TextStyle(
                color: Colors.white,

                fontSize: 18,

                fontWeight: FontWeight.w800,
              ),
            ),

            const SizedBox(height: 2),

            Text(
              label,

              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.67),
                fontSize: 9,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
