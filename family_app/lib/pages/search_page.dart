import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_helper.dart';
import '../services/search_service.dart';
import '../theme/app_theme.dart';
import '../widgets/user_avatar.dart';
import 'feed_page.dart';
import 'user_profile_page.dart';

// =======================================================
// ค้นหา
// - ชุมชน (ปุ่มค้นหาในหน้าหลัก): แท็บ "โพสต์" (ข้อความโพสต์ชุมชน) / "ผู้ใช้" (ชื่อที่แสดง)
// - ในกลุ่ม (ปุ่มค้นหาในฟีดกลุ่ม): เฉพาะโพสต์ในกลุ่มที่อยู่ตอนนี้ ไม่ปนกับชุมชน
//
// - รอหยุดพิมพ์ 400 มิลลิวินาที หรือกดปุ่มค้นหาบนคีย์บอร์ด / ช่องว่าง → ไม่เรียก API
// - คำค้นใหม่ → ผลและการแบ่งหน้าเริ่มใหม่ (สร้างรายการใหม่ด้วย key ของคำค้น
//   ผลของคำเก่าที่ตอบช้าถูกทิ้งเพราะรายการเก่าถูกปิดไปแล้ว)
// - แท็บที่ยังไม่เปิดดูไม่ค้น / สลับแท็บแล้วรายการและตำแหน่งเลื่อนยังอยู่ (IndexedStack)
// - เปิดโพสต์/โปรไฟล์แล้วกลับมา → คำค้น แท็บ และตำแหน่งเลื่อนเดิม
// - ไม่เก็บประวัติการค้นหา
// =======================================================

enum SearchArea { community, family }

class SearchPage extends StatefulWidget {
  final SearchArea area;

  const SearchPage({super.key, this.area = SearchArea.community});

  // รอหยุดพิมพ์ก่อนค้นหา
  static const Duration debounce = Duration(milliseconds: 400);

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage>
    with SingleTickerProviderStateMixin {
  final TextEditingController controller = TextEditingController();
  final FocusNode focus = FocusNode();

  late final TabController tabs = TabController(
    length: inGroup ? 1 : 2,
    vsync: this,
  );

  Timer? debounceTimer;

  // คำค้นที่ใช้อยู่ (ตัดช่องว่างหัวท้ายแล้ว) — ว่าง = ยังไม่ค้น
  String query = '';

  // แท็บที่เปิดดูแล้วสำหรับคำค้นนี้ (แท็บอื่นยังไม่ค้น)
  final Set<int> openedTabs = {0};

  bool get inGroup => widget.area == SearchArea.family;

  @override
  void initState() {
    super.initState();

    tabs.addListener(() {
      if (!tabs.indexIsChanging) {
        setState(() => openedTabs.add(tabs.index));
      }
    });
  }

  void onChanged(String text) {
    debounceTimer?.cancel();

    final String value = text.trim();

    // ช่องว่าง → แสดงคำแนะนำทันที ไม่เรียก API
    if (value.isEmpty) {
      apply('');
      return;
    }

    setState(() {}); // ปุ่มล้างคำค้น

    debounceTimer = Timer(SearchPage.debounce, () => apply(value));
  }

  void submit(String text) {
    debounceTimer?.cancel();
    apply(text.trim());
  }

  void apply(String value) {
    if (!mounted) return;

    setState(() {
      if (value == query) return;

      query = value;
      openedTabs
        ..clear()
        ..add(tabs.index);
    });
  }

  void clear() {
    debounceTimer?.cancel();
    controller.clear();
    apply('');
    focus.requestFocus();
  }

  @override
  void dispose() {
    debounceTimer?.cancel();
    tabs.dispose();
    controller.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: controller,
          focusNode: focus,
          autofocus: true,
          textInputAction: TextInputAction.search,
          inputFormatters: [
            LengthLimitingTextInputFormatter(SearchService.maxLength),
          ],
          onChanged: onChanged,
          onSubmitted: submit,
          decoration: InputDecoration(
            hintText: inGroup ? 'ค้นหาโพสต์ในกลุ่ม' : 'ค้นหาโพสต์หรือผู้ใช้',
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: controller.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'ล้างคำค้น',
                    onPressed: clear,
                    icon: const Icon(Icons.close_rounded),
                  ),
            isDense: true,
          ),
        ),
        actions: const [SizedBox(width: 12)],
        bottom: inGroup
            ? PreferredSize(
                preferredSize: const Size.fromHeight(40),
                child: buildGroupBanner(),
              )
            : TabBar(
                controller: tabs,
                tabs: const [
                  Tab(text: 'โพสต์'),
                  Tab(text: 'ผู้ใช้'),
                ],
              ),
      ),
      body: query.isEmpty
          ? buildHint()
          : AnimatedBuilder(
              animation: tabs,
              builder: (context, _) => IndexedStack(
                index: tabs.index,
                children: [
                  openedTabs.contains(0)
                      ? FeedPage(
                          key: ValueKey(
                            'search-posts-${widget.area.name}-$query',
                          ),
                          scope: inGroup
                              ? FeedScope.family
                              : FeedScope.community,
                          searchQuery: query,
                          searchScope: inGroup ? 'family' : 'community',
                        )
                      : const SizedBox.shrink(),
                  if (!inGroup)
                    openedTabs.contains(1)
                        ? UserSearchResults(
                            key: ValueKey('search-users-$query'),
                            query: query,
                          )
                        : const SizedBox.shrink(),
                ],
              ),
            ),
    );
  }

  // บอกให้ชัดว่ากำลังค้นหาในกลุ่ม
  Widget buildGroupBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      color: AppColors.primary.withValues(alpha: 0.08),
      child: Row(
        children: [
          Icon(Icons.groups_rounded, size: 18, color: AppColors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'ค้นหาในกลุ่ม · เฉพาะโพสต์ในกลุ่มของคุณ',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppColors.primary,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget buildHint() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 64, 32, 32),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        Icon(
          inGroup ? Icons.manage_search_rounded : Icons.travel_explore_rounded,
          size: 52,
          color: AppColors.muted,
        ),
        const SizedBox(height: 14),
        Text(
          inGroup
              ? 'พิมพ์คำเพื่อค้นหาข้อความในโพสต์ของกลุ่ม'
              : 'พิมพ์คำเพื่อค้นหาโพสต์ในชุมชน หรือชื่อผู้ใช้',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.navy, fontSize: 15, height: 1.5),
        ),
        const SizedBox(height: 6),
        Text(
          'ใส่หลายคำคั่นด้วยช่องว่างได้ ผลลัพธ์ต้องมีทุกคำ',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.muted, fontSize: 12.5),
        ),
      ],
    );
  }
}

// =======================================================
// ผลค้นหาผู้ใช้ (ชื่อที่แสดงและรูปเท่านั้น) — แตะเพื่อเปิดโปรไฟล์
// ติดตาม/บล็อกทำจากหน้าโปรไฟล์เดิม
// =======================================================

class UserSearchResults extends StatefulWidget {
  final String query;

  const UserSearchResults({super.key, required this.query});

  @override
  State<UserSearchResults> createState() => _UserSearchResultsState();
}

class _UserSearchResultsState extends State<UserSearchResults> {
  final ScrollController scroll = ScrollController();

  List<Map<String, dynamic>> users = [];
  String? cursor;
  bool hasMore = false;

  bool isLoading = true;
  bool isLoadingMore = false;
  String? loadError;
  bool loadMoreFailed = false;

  @override
  void initState() {
    super.initState();
    scroll.addListener(onScroll);
    load();
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  void onScroll() {
    if (!scroll.hasClients) return;

    if (scroll.position.pixels >= scroll.position.maxScrollExtent - 400) {
      load(more: true);
    }
  }

  Future<void> load({bool more = false, bool retry = false}) async {
    if (more) {
      if (isLoading || isLoadingMore || !hasMore) return;
      if (loadMoreFailed && !retry) return;

      setState(() {
        isLoadingMore = true;
        loadMoreFailed = false;
      });
    }

    try {
      final result = await SearchService.users(
        query: widget.query,
        cursor: more ? cursor : null,
      );

      if (!mounted) return;

      final dynamic raw = result['users'];

      if (result['status'] == true && raw is List) {
        final List<Map<String, dynamic>> page = raw
            .whereType<Map>()
            .map((user) => Map<String, dynamic>.from(user))
            .toList();

        setState(() {
          if (more) {
            final Set<dynamic> seen = users.map((user) => user['id']).toSet();
            users.addAll(page.where((user) => !seen.contains(user['id'])));
          } else {
            users = page;
          }

          cursor = result['next_cursor']?.toString();
          hasMore = result['has_more'] == true;
          loadError = null;
        });
      } else {
        fail(more, result['message']?.toString() ?? 'ค้นหาไม่สำเร็จ');
      }
    } catch (e) {
      if (mounted) fail(more, ApiHelper.messageOf(e));
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
          isLoadingMore = false;
        });
      }
    }
  }

  // โหลดเพิ่มไม่สำเร็จ → รายการเดิมยังอยู่ + ปุ่มลองใหม่
  void fail(bool more, String message) {
    setState(() {
      if (more) {
        loadMoreFailed = true;
      } else {
        loadError = message;
      }
    });
  }

  Future<void> openProfile(Map<String, dynamic> user) async {
    final dynamic id = user['id'];

    if (id is! num) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            UserProfilePage(userId: id.toInt(), name: user['name']?.toString()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (loadError != null && users.isEmpty) {
      return buildMessage(
        icon: Icons.cloud_off_rounded,
        color: AppColors.danger,
        title: 'ค้นหาไม่สำเร็จ',
        message: loadError!,
        action: OutlinedButton.icon(
          onPressed: () {
            setState(() {
              isLoading = true;
              loadError = null;
            });
            load();
          },
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: const Text('ลองอีกครั้ง'),
        ),
      );
    }

    if (users.isEmpty) {
      return buildMessage(
        icon: Icons.person_search_rounded,
        color: AppColors.muted,
        title: 'ไม่พบผู้ใช้สำหรับคำว่า “${widget.query}”',
        message: 'ค้นจากชื่อที่แสดงในชุมชน ลองใช้คำอื่นหรือคำที่สั้นลง',
      );
    }

    return ListView.separated(
      controller: scroll,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      itemCount: users.length + 1,
      separatorBuilder: (_, index) => index < users.length - 1
          ? const Divider(height: 1)
          : const SizedBox.shrink(),
      itemBuilder: (context, index) {
        if (index == users.length) return buildFooter();

        final Map<String, dynamic> user = users[index];
        final String name = user['name']?.toString() ?? 'สมาชิก';
        final String? note = user['is_me'] == true
            ? 'คุณ'
            : user['is_family'] == true
            ? 'สมาชิกในกลุ่มของคุณ'
            : null;

        return ListTile(
          key: ValueKey('search-user-${user['id']}'),
          contentPadding: const EdgeInsets.symmetric(horizontal: 6),
          leading: UserAvatar(
            user: {
              'name': name,
              'profile_photo_url': user['profile_image_url'],
            },
          ),
          title: Text(
            name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppColors.navy,
              fontWeight: FontWeight.w700,
            ),
          ),
          subtitle: note == null
              ? null
              : Text(note, style: TextStyle(color: AppColors.muted)),
          trailing: Icon(Icons.chevron_right_rounded, color: AppColors.muted),
          onTap: () => openProfile(user),
        );
      },
    );
  }

  Widget buildFooter() {
    if (isLoadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (loadMoreFailed) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          children: [
            Text(
              'โหลดเพิ่มไม่สำเร็จ',
              style: TextStyle(color: AppColors.muted, fontSize: 12),
            ),
            const SizedBox(height: 6),
            OutlinedButton.icon(
              onPressed: () => load(more: true, retry: true),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('ลองอีกครั้ง'),
            ),
          ],
        ),
      );
    }

    if (hasMore) return const SizedBox(height: 40);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Center(
        child: Text(
          'ไม่มีผลค้นหาเพิ่มแล้ว',
          style: TextStyle(color: AppColors.muted, fontSize: 12),
        ),
      ),
    );
  }

  Widget buildMessage({
    required IconData icon,
    required Color color,
    required String title,
    required String message,
    Widget? action,
  }) {
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(28, 56, 28, 28),
      children: [
        Icon(icon, size: 46, color: color),
        const SizedBox(height: 12),
        Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.navy,
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.muted, fontSize: 13, height: 1.5),
        ),
        if (action != null) ...[
          const SizedBox(height: 14),
          Center(child: action),
        ],
      ],
    );
  }
}
