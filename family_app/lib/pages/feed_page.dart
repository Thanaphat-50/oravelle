import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_compress/video_compress.dart';

import '../config/app_info.dart';
import '../services/post_events.dart';
import '../services/post_service.dart';
import '../services/search_service.dart';
import '../services/social_service.dart';
import '../theme/app_theme.dart';
import '../widgets/comment_media.dart';
import '../widgets/comment_sheet.dart';
import '../widgets/community_sheets.dart';
import '../widgets/hashtag_text.dart';
import '../widgets/photo_viewer.dart';
import '../widgets/post_categories.dart';
import '../widgets/share_sheet.dart';
import 'group_chat_page.dart';
import 'post_detail_page.dart';
import 'post_edit_page.dart';
import 'search_page.dart';
import 'user_profile_page.dart';
import 'video_player_page.dart';

// ฟีด "ครอบครัว" (เฉพาะครอบครัว) และ "ชุมชน" (ทุกคนในแอป)
enum FeedScope { family, community, mine }

// ฟีดชุมชนในหน้าหลัก (สลับด้วยแถบด้านบนของหน้าหลัก)
// forYou = เรียงตามความสนใจ / latest = ล่าสุด / videos = เฉพาะวิดีโอ
enum CommunityFeedMode { forYou, latest, videos }

// ข้อมูลของแต่ละฟีด แยกกันเพื่อสลับแท็บได้โดยไม่ต้องโหลดใหม่
class _ScopeFeed {
  List<Map<String, dynamic>> posts = [];

  bool isLoading = true;
  bool isLoadingMore = false;

  // โหลดครั้งแรกสำเร็จแล้ว
  bool loaded = false;

  // ข้อความ Error เมื่อโหลดครั้งแรกไม่สำเร็จ
  String? loadError;

  // การแบ่งหน้า (ใช้กับฟีดชุมชน)
  int page = 1;
  bool hasMore = false;

  // ผลค้นหา: แบ่งหน้าแบบ cursor (ส่ง next_cursor ของหน้าก่อน)
  String? cursor;

  // โหลดหน้าถัดไปไม่สำเร็จ → รายการเดิมยังอยู่ แสดงปุ่มลองใหม่ (ไม่โหลดซ้ำเองตอนเลื่อน)
  bool loadMoreFailed = false;
}

// ฟีดโพสต์ ใช้ได้หลายแบบ
// - FeedScope.community: หน้าหลัก (ทุกครอบครัวเห็น)
// - searchQuery:         ผลค้นหาโพสต์ (หน้าค้นหา) searchScope = community / family
//                        คำค้นใหม่ → หน้าค้นหาสร้าง FeedPage ใหม่ด้วย key ใหม่ (ผลของคำเก่าถูกทิ้ง)
// - FeedScope.family:    แท็บครอบครัว (เฉพาะครอบครัว)
// - FeedScope.mine:      โพสต์ของฉัน (ครอบครัว + ชุมชน)
// - hashtag:            โพสต์ชุมชนที่มี #แท็กนี้ (หน้าแฮชแท็ก)
// - authorId:           โพสต์ของผู้ใช้คนเดียวที่เราเห็นได้ (หน้าโปรไฟล์)
//                        ครอบครัวเดียวกัน + ชุมชน
// - postId:              โพสต์เดียว (เปิดจากการแจ้งเตือน)
//                        scope จะใช้ตามโพสต์ที่โหลดมา
class FeedPage extends StatefulWidget {
  final FeedScope scope;

  final int? postId;

  // แสดงเฉพาะโพสต์ของผู้ใช้คนนี้ (หน้าโปรไฟล์)
  final int? authorId;

  // แสดงแทนหัวข้อฟีด (เช่น ข้อมูลโปรไฟล์)
  final Widget? header;

  // บล็อกผู้ใช้จากเมนูโพสต์สำเร็จ (หน้าโปรไฟล์ใช้อัปเดตสถานะ)
  final ValueChanged<int>? onUserBlocked;

  // ยังไม่มีครอบครัว: ดูได้อย่างเดียว กดโพสต์/แชร์ในแอป → ชวนไปสร้าง/เข้าร่วมครอบครัว
  final VoidCallback? onJoinFamily;

  // ฟีดชุมชน: สำหรับคุณ / ล่าสุด / วิดีโอ (แต่ละแบบเป็นหน้าแยกในหน้าหลัก)
  final CommunityFeedMode communityMode;

  // หน้าแฮชแท็ก: เฉพาะโพสต์ชุมชนที่มีแท็กนี้
  final String? hashtag;

  // ดึงลงเพื่อรีเฟรช → ให้หน้าที่ใช้ header โหลดข้อมูลของตัวเองใหม่ด้วย
  final Future<void> Function()? onRefresh;

  // แถวกรองหมวดอยู่ที่หน้าแม่ (อยู่กับที่ ไม่เลื่อนตามตอนปัดซ้าย-ขวา)
  // category = หมวดที่หน้าแม่เลือก / onCategoryChanged = หน้านี้ล้างตัวกรองเอง
  // (เช่น หลังโพสต์หมวดอื่น) ไม่ส่ง onCategoryChanged → แสดงแถวกรองในฟีดเอง
  final String? category;
  final ValueChanged<String?>? onCategoryChanged;

  // โพสต์ของฉัน (scope mine): community = เฉพาะชุมชน / family = เฉพาะในกลุ่ม
  // null = ทั้งหมด — เปลี่ยนค่า → โหลดใหม่ตั้งแต่หน้าแรก (เซิร์ฟเวอร์กรองทุกหน้า)
  final String? mineVisibility;

  // หน้าค้นหา: ผลค้นหาโพสต์ด้วยคำนี้ (แตะการ์ดเพื่อเปิดโพสต์)
  // searchScope: community = ชุมชน / family = ในกลุ่มที่อยู่ตอนนี้
  final String? searchQuery;
  final String searchScope;

  // หน้า "โพสต์ที่บันทึก": รายการที่บันทึกไว้ (ล่าสุดก่อน) ยกเลิกบันทึกแล้วหายจากรายการ
  final bool savedOnly;

  const FeedPage({
    super.key,
    required this.scope,
    this.postId,
    this.authorId,
    this.header,
    this.onUserBlocked,
    this.onJoinFamily,
    this.communityMode = CommunityFeedMode.forYou,
    this.hashtag,
    this.onRefresh,
    this.category,
    this.onCategoryChanged,
    this.mineVisibility,
    this.searchQuery,
    this.searchScope = 'community',
    this.savedOnly = false,
  });

  @override
  State<FeedPage> createState() => _FeedPageState();
}

class _FeedPageState extends State<FeedPage> {
  // ความยาวสูงสุดของโพสต์ ตรงกับ Laravel (content max:5000)
  static const int maxPostLength = 5000;

  // จำนวนรูปสูงสุดต่อโพสต์ ตรงกับ Laravel (images max:10)
  static const int maxPostImages = 10;

  // จำนวนความคิดเห็นที่แสดงก่อนกด "ดูก่อนหน้า"
  static const int collapsedCommentCount = 2;

  // สีของป้าย/ปุ่มฝั่งชุมชน (โหมดมืดใช้โทนสว่างกว่าให้อ่านง่าย)
  static Color get communityColor => communityAccentColor;

  // สีปุ่มถูกใจ
  static const Color likeColor = Color(0xFFE5486B);

  final TextEditingController postController = TextEditingController();

  // แฮชแท็กของโพสต์ชุมชน (ช่องแยกจากข้อความ)
  final TextEditingController hashtagController = TextEditingController();

  final List<String> composeHashtags = [];

  // ช่องแฮชแท็กเปิดอยู่ (กดปุ่ม # ในแถบเครื่องมือ)
  bool showHashtagField = false;

  final FocusNode hashtagFocus = FocusNode();

  final ScrollController scrollController = ScrollController();

  final ImagePicker imagePicker = ImagePicker();

  // รูปที่เลือกไว้สำหรับโพสต์ที่กำลังเขียน
  final List<XFile> pickedImages = [];

  // วิดีโอที่เลือกไว้ (โพสต์ละ 1 วิดีโอ ใช้แทนรูป)
  PostVideoFile? pickedVideo;

  // ขั้นตอนตอนส่ง (บีบอัด / อัปโหลดวิดีโอ)
  String? postingStatus;

  // ตรงกับ Laravel (PostVideo::MAX_SECONDS / MAX_KB)
  static const int maxVideoSeconds = 60;
  static const int maxVideoBytes = 50 * 1024 * 1024;

  // บีบอัดเฉพาะไฟล์ที่ใหญ่กว่านี้ และรอไม่เกินนี้ (เครื่องช้า → ใช้ไฟล์เดิม)
  static const int compressAboveBytes = 20 * 1024 * 1024;
  static const Duration compressTimeLimit = Duration(minutes: 2);

  bool isPosting = false;

  // หน้าต่างเขียนโพสต์ (เปิดจากปุ่ม + ลอยมุมขวาล่าง)
  // ร่างโพสต์เก็บไว้ที่หน้านี้ ปิดหน้าต่างไปแล้วเปิดใหม่ข้อความยังอยู่
  BuildContext? composerContext;
  String? composerError;

  // เพิ่มค่าทุกครั้งที่ร่างโพสต์เปลี่ยน → หน้าต่างเขียนโพสต์วาดใหม่
  final ValueNotifier<int> composerVersion = ValueNotifier<int>(0);

  // ฟีดนี้เป็นของครอบครัวหรือชุมชน
  // (กำหนดจากหน้าที่เปิด / โหมดโพสต์เดียวใช้ตามโพสต์ที่โหลดมา)
  FeedScope get scope => singlePostScope ?? widget.scope;

  FeedScope? singlePostScope;

  bool get isSinglePost => widget.postId != null;

  bool get isAuthorFeed => widget.authorId != null;

  bool get isHashtagFeed => widget.hashtag != null;

  bool get isSearchFeed => widget.searchQuery != null;

  bool get isSavedFeed => widget.savedOnly;

  // ผลค้นหา / โพสต์ที่บันทึก: แบ่งหน้าแบบ cursor และแตะการ์ดเพื่อเปิดโพสต์
  bool get isListFeed => isSearchFeed || isSavedFeed;

  // ฟีดหลักที่เขียนโพสต์ได้ (ชุมชน / ครอบครัว)
  bool get isMainFeed =>
      !isSinglePost &&
      !isAuthorFeed &&
      !isHashtagFeed &&
      !isListFeed &&
      scope != FeedScope.mine;

  // ฟีดที่โหลดทีละหน้า
  bool get isPaged =>
      !isSinglePost &&
      (isListFeed || scope == FeedScope.community || scope == FeedScope.mine);

  final _ScopeFeed feed = _ScopeFeed();

  Map<String, dynamic>? currentUser;

  bool communityTermsAccepted = false;

  // ฟีดชุมชนหลัก (หน้าหลัก)
  bool get isCommunityMain => isMainFeed && scope == FeedScope.community;

  // สำหรับคุณ: เรียงตามความสนใจ + แนะนำคนที่ชอบเรื่องเดียวกัน
  bool get forYou =>
      isCommunityMain && widget.communityMode == CommunityFeedMode.forYou;

  bool get videosOnly =>
      isCommunityMain && widget.communityMode == CommunityFeedMode.videos;

  // คนที่อาจชอบเรื่องเดียวกับเรา (แสดงในแท็บ "สำหรับคุณ")
  List<Map<String, dynamic>> suggestions = [];

  final Set<int> followedIds = {};

  final Set<int> followBusy = {};

  // โพสต์ที่กำลังแชร์ (กันกดซ้ำ)
  final Set<int> sharingPostIds = {};

  // โพสต์ที่กำลังลบ (แสดง Loading บนการ์ด)
  final Set<int> deletingPostIds = {};

  // โพสต์ที่กดดูความคิดเห็นทั้งหมดแล้ว
  final Set<int> expandedPostIds = {};

  // โพสต์ที่กำลังส่งการถูกใจไป Server (กันกดรัว)
  final Set<int> likingPostIds = {};

  // หมวดของโพสต์ชุมชนที่กำลังเขียน
  String composeCategory = 'general';

  // โพสต์ครอบครัว: แสดงข้อความนี้บนแผนที่ด้วย
  bool composeShowOnMap = false;

  // ข้อความสั้นที่กดใส่ได้เลยตอนเปิด "แสดงบนแผนที่"
  static const List<String> quickMapStatuses = [
    'ทำงานอยู่',
    'กำลังเดินทาง',
    'ถึงบ้านแล้ว',
    'ออกไปข้างนอก',
    'เรียนอยู่',
  ];

  // โพสต์ที่กำลังตั้งค่าแผนที่ (กันกดซ้ำ)
  final Set<int> mapUpdatingPostIds = {};

  // หมวดที่กรองฟีดชุมชนอยู่ (null = ทั้งหมด)
  String? filterCategory;

  // เพิ่มทุกครั้งที่เปลี่ยนตัวกรอง
  // ผลโหลดของตัวกรองเก่าที่ตอบกลับช้าจะถูกทิ้ง
  int feedGeneration = 0;

  bool get categoryFromParent => widget.onCategoryChanged != null;

  // โพสต์ถูกแก้/เปลี่ยนจากหน้าอื่น → อัปเดตรายการในหน้านี้ (รวมต้นฉบับในโพสต์แชร์)
  StreamSubscription<PostChange>? postChanges;

  @override
  void initState() {
    super.initState();
    if (categoryFromParent) filterCategory = widget.category;
    scrollController.addListener(onScroll);
    postChanges = PostEvents.changes.listen((change) {
      bool touched = PostEvents.apply(feed.posts, change);

      // หน้าโพสต์ที่บันทึก: ยกเลิกบันทึกสำเร็จ (จากหน้าไหนก็ได้) → เอาออกจากรายการ
      if (isSavedFeed && change.fields['saved_confirmed'] == false) {
        feed.posts.removeWhere((post) => postIdOf(post) == change.postId);
        touched = true;
      }

      if (touched && mounted) setState(() {});
    });
    loadPosts();

    if (forYou) loadSuggestions();
  }

  String apiScope(FeedScope value) {
    switch (value) {
      case FeedScope.community:
        return 'community';
      case FeedScope.mine:
        return 'mine';
      case FeedScope.family:
        return 'family';
    }
  }

  // =====================================================
  // โหลดโพสต์
  // loadMore = true → โหลดหน้าถัดไปต่อท้าย (ฟีดชุมชน)
  // retry = true → กดลองใหม่หลังโหลดหน้าถัดไปไม่สำเร็จ
  // =====================================================

  Future<void> loadPosts({bool loadMore = false, bool retry = false}) async {
    if (isSinglePost) {
      if (!loadMore) await loadSinglePost();
      return;
    }

    final state = feed;

    if (loadMore) {
      if (state.isLoading || state.isLoadingMore || !state.hasMore) {
        return;
      }

      // ล้มเหลวแล้ว → รอผู้ใช้กดลองใหม่ (ไม่ยิงซ้ำทุกครั้งที่เลื่อน)
      if (state.loadMoreFailed && !retry) return;

      setState(() {
        state.isLoadingMore = true;
        state.loadMoreFailed = false;
      });
    }

    final int page = loadMore ? state.page + 1 : 1;

    final int generation = feedGeneration;

    try {
      final result = isSearchFeed
          ? await SearchService.posts(
              query: widget.searchQuery!,
              scope: widget.searchScope,
              cursor: loadMore ? state.cursor : null,
            )
          : isSavedFeed
          ? await PostService.savedPosts(cursor: loadMore ? state.cursor : null)
          : await PostService.getPosts(
              scope: isAuthorFeed ? 'user' : apiScope(scope),
              page: page,
              category: isMainFeed ? filterCategory : null,
              userId: widget.authorId,
              sort: forYou ? 'for_you' : null,
              media: videosOnly ? 'video' : null,
              hashtag: widget.hashtag,
              visibility: scope == FeedScope.mine
                  ? widget.mineVisibility
                  : null,
            );

      if (!mounted || generation != feedGeneration) return;

      if (result['status'] == true) {
        final dynamic rawPosts = result['posts'];

        final List<Map<String, dynamic>> newPosts = rawPosts is List
            ? rawPosts
                  .whereType<Map>()
                  .map((item) => Map<String, dynamic>.from(item))
                  .toList()
            : [];

        setState(() {
          if (loadMore) {
            // กันโพสต์ซ้ำ (มีโพสต์ใหม่เข้ามาระหว่างเลื่อน)
            final existingIds = state.posts.map(postIdOf).toSet();

            state.posts.addAll(
              newPosts.where((post) => !existingIds.contains(postIdOf(post))),
            );
          } else {
            state.posts = newPosts;
          }

          state.page = page;
          state.hasMore = result['has_more'] == true;
          state.cursor = result['next_cursor']?.toString();
          state.loadMoreFailed = false;
          state.loaded = true;
          state.loadError = null;

          applyCurrentUser(result['current_user'] ?? result['user']);
        });
      } else {
        if (loadMore) state.loadMoreFailed = true;

        handleLoadError(result['message']?.toString() ?? 'โหลดโพสต์ไม่สำเร็จ');
      }
    } catch (e) {
      if (!mounted || generation != feedGeneration) return;

      if (loadMore) state.loadMoreFailed = true;

      handleLoadError(e.toString());
    } finally {
      if (mounted && generation == feedGeneration) {
        setState(() {
          state.isLoading = false;
          state.isLoadingMore = false;
        });
      }
    }
  }

  // ยังไม่มีครอบครัว → อธิบาย แล้วพาไปแท็บครอบครัว
  Future<void> askToJoinFamily() async {
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(Icons.groups_rounded, color: AppColors.primary, size: 34),
        title: const Text('ต้องมีกลุ่มก่อน'),
        content: const Text(
          'สร้างกลุ่มใหม่ หรือเข้าร่วมด้วยรหัสเชิญ/คำเชิญ '
          'แล้วจะโพสต์และแชร์ในแอปได้',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('ไว้ทีหลัง'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('ไปที่กลุ่มสมาชิก'),
          ),
        ],
      ),
    );

    if (go == true) widget.onJoinFamily?.call();
  }

  Future<void> refreshFeed() async {
    if (forYou) loadSuggestions();

    final Future<void>? headerRefresh = widget.onRefresh?.call();

    await loadPosts();
    await headerRefresh;
  }

  // =====================================================
  // แนะนำคนที่ชอบเรื่องเดียวกัน + ติดตาม
  // =====================================================

  Future<void> loadSuggestions() async {
    try {
      final result = await SocialService.suggestions();

      final dynamic users = result['users'];

      if (!mounted || result['status'] != true || users is! List) return;

      setState(() {
        suggestions = users
            .whereType<Map>()
            .map((user) => Map<String, dynamic>.from(user))
            .toList();

        followedIds.clear();
      });
    } catch (_) {
      // โหลดไม่ได้ → ไม่แสดงส่วนแนะนำ
    }
  }

  Future<void> toggleFollow(Map<String, dynamic> user) async {
    final dynamic rawId = user['id'];

    if (rawId is! num) return;

    final int id = rawId.toInt();

    if (followBusy.contains(id)) return;

    final bool follow = !followedIds.contains(id);

    setState(() => followBusy.add(id));

    try {
      final result = await SocialService.setFollowing(id, follow);

      if (!mounted) return;

      if (result['status'] == true) {
        setState(() {
          if (result['is_following'] == true) {
            followedIds.add(id);
          } else {
            followedIds.remove(id);
          }
        });
      } else {
        showMessage(result['message']?.toString() ?? 'ทำรายการไม่สำเร็จ');
      }
    } catch (e) {
      if (mounted) showMessage(e.toString());
    } finally {
      if (mounted) setState(() => followBusy.remove(id));
    }
  }

  // =====================================================
  // แชร์: ส่งต่อไปแอปอื่น / แชร์ในชุมชน / ส่งให้ครอบครัว
  // =====================================================

  Future<void> openShareSheet(Map<String, dynamic> post) async {
    final int? postId = postIdOf(post);

    if (postId == null || sharingPostIds.contains(postId)) return;

    final String? channel = await showShareChannelSheet(context);

    if (channel == null || !mounted) return;

    if (channel == 'external') {
      await shareExternally(post, postId);
      return;
    }

    if (widget.onJoinFamily != null) {
      await askToJoinFamily();
      return;
    }

    if (channel == 'community' && !communityTermsAccepted) {
      final bool ok = await ensureCommunityTerms();

      if (!ok || !mounted) return;
    }

    final String? note = await askShareNote(context, channel);

    if (note == null || !mounted) return;

    await sendShare(postId, channel, note);
  }

  // เปิดหน้าแชร์ของมือถือ (ส่งข้อความของโพสต์ต้นฉบับ)
  Future<void> shareExternally(Map<String, dynamic> post, int postId) async {
    final dynamic shared = post['shared_post'];

    final Map<String, dynamic> original = shared is Map
        ? Map<String, dynamic>.from(shared)
        : post;

    final dynamic user = original['user'];

    final String name = user is Map
        ? (user['name']?.toString() ?? 'สมาชิก')
        : 'สมาชิก';

    final String content = original['content']?.toString().trim() ?? '';

    final String text = [
      if (content.isNotEmpty) content,
      '— $name ในแอป ${AppInfo.name}',
    ].join('\n\n');

    try {
      final ShareResult result = await SharePlus.instance.share(
        ShareParams(text: text, subject: 'โพสต์จากแอป ${AppInfo.name}'),
      );

      // ปิดหน้าแชร์ไปโดยไม่ได้ส่ง → ไม่นับ
      if (result.status == ShareResultStatus.dismissed) return;

      await sendShare(postId, 'external', null, quiet: true);
    } catch (_) {
      if (mounted) showMessage('เปิดหน้าแชร์ไม่ได้');
    }
  }

  Future<void> sendShare(
    int postId,
    String channel,
    String? note, {
    bool quiet = false,
  }) async {
    if (sharingPostIds.contains(postId)) return;

    setState(() => sharingPostIds.add(postId));

    try {
      final result = await SocialService.sharePost(
        postId,
        channel: channel,
        content: note,
      );

      if (!mounted) return;

      if (result['status'] == true) {
        final dynamic originalId = result['post_id'];

        final dynamic count = result['shares_count'];

        final dynamic newPost = result['post'];

        setState(() {
          for (final item in feed.posts) {
            if (postIdOf(item) == originalId) item['shares_count'] = count;
          }

          // แชร์แล้วเห็นทันทีในฟีดที่เปิดอยู่
          final bool showHere =
              newPost is Map &&
              isMainFeed &&
              ((channel == 'family' && scope == FeedScope.family) ||
                  (channel == 'community' &&
                      scope == FeedScope.community &&
                      !forYou &&
                      !videosOnly &&
                      filterCategory == null));

          if (showHere) {
            feed.posts.insert(0, Map<String, dynamic>.from(newPost));
          }
        });

        if (!quiet) showMessage(result['message']?.toString() ?? 'แชร์แล้ว');
      } else if (result['code'] == 'terms_required') {
        setState(() => communityTermsAccepted = false);

        showMessage(
          result['message']?.toString() ?? 'กรุณายอมรับกฎชุมชนก่อนโพสต์',
        );
      } else {
        showMessage(result['message']?.toString() ?? 'แชร์ไม่สำเร็จ');
      }
    } catch (e) {
      if (mounted) showMessage(e.toString());
    } finally {
      if (mounted) setState(() => sharingPostIds.remove(postId));
    }
  }

  // โหมดโพสต์เดียว: โหลดโพสต์จาก postId
  Future<void> loadSinglePost() async {
    try {
      final result = await PostService.getPost(widget.postId!);

      if (!mounted) return;

      final dynamic raw = result['post'];

      if (result['status'] == true && raw is Map) {
        final post = Map<String, dynamic>.from(raw);

        setState(() {
          feed.posts = [post];
          feed.hasMore = false;
          feed.loaded = true;
          feed.loadError = null;

          singlePostScope = isCommunityPost(post)
              ? FeedScope.community
              : FeedScope.family;

          // เปิดความคิดเห็นทั้งหมด (มาจากการแจ้งเตือนความคิดเห็น)
          final int? id = postIdOf(post);
          if (id != null) expandedPostIds.add(id);

          applyCurrentUser(result['current_user']);
        });
      } else {
        handleLoadError(
          result['message']?.toString() ?? 'ไม่พบโพสต์นี้ หรือโพสต์ถูกลบไปแล้ว',
        );
      }
    } catch (e) {
      if (mounted) handleLoadError(e.toString());
    } finally {
      if (mounted) {
        setState(() {
          feed.isLoading = false;
        });
      }
    }
  }

  @override
  void didUpdateWidget(covariant FeedPage oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (categoryFromParent && widget.category != oldWidget.category) {
      changeFilter(widget.category);
    }

    if (scope == FeedScope.mine &&
        widget.mineVisibility != oldWidget.mineVisibility) {
      restartFeed();
    }
  }

  // ตัวกรองโพสต์ของฉันเปลี่ยน → ล้างรายการแล้วโหลดหน้าแรกใหม่
  // (ผลของตัวกรองเก่าที่ตอบกลับช้าถูกทิ้งด้วย feedGeneration)
  Future<void> restartFeed() async {
    setState(() {
      feedGeneration++;

      feed.posts = [];
      feed.isLoading = true;
      feed.isLoadingMore = false;
      feed.loadMoreFailed = false;
      feed.loadError = null;
      feed.hasMore = false;

      expandedPostIds.clear();
    });

    await loadPosts();
  }

  // เลือกหมวดที่จะกรองฟีดชุมชน → ล้างฟีดแล้วโหลดใหม่
  Future<void> changeFilter(String? category) async {
    if (category == filterCategory) return;

    setState(() {
      filterCategory = category;
      feedGeneration++;

      feed.posts = [];
      feed.isLoading = true;
      feed.isLoadingMore = false;
      feed.loadMoreFailed = false;
      feed.loadError = null;
      feed.hasMore = false;

      expandedPostIds.clear();
    });

    await loadPosts();
  }

  void applyCurrentUser(dynamic userData) {
    if (userData is! Map) return;

    currentUser = Map<String, dynamic>.from(userData);

    communityTermsAccepted = userData['community_terms_accepted'] == true;
  }

  // ยังไม่มีโพสต์ในจอ → แสดงการ์ด "ลองอีกครั้ง"
  // มีโพสต์อยู่แล้ว → แจ้งด้วย SnackBar
  void handleLoadError(String message) {
    if (feed.posts.isEmpty) {
      setState(() {
        feed.loadError = message;
      });
    } else {
      showMessage(message);
    }
  }

  Future<void> retryLoad() async {
    setState(() {
      feed.isLoading = true;
      feed.loadError = null;
    });

    await loadPosts();
  }

  // เลื่อนใกล้ท้ายฟีด → โหลดหน้าถัดไป
  void onScroll() {
    if (!isPaged || !scrollController.hasClients) {
      return;
    }

    final position = scrollController.position;

    if (position.pixels >= position.maxScrollExtent - 600) {
      loadPosts(loadMore: true);
    }
  }

  // =====================================================
  // กฎชุมชน: ต้องยอมรับก่อนโพสต์ชุมชนครั้งแรก
  // =====================================================

  Future<bool> ensureCommunityTerms() async {
    final bool accepted = await showCommunityRulesDialog(context);

    if (!accepted || !mounted) return false;

    try {
      final result = await PostService.acceptCommunityTerms();

      if (!mounted) return false;

      if (result['status'] == true) {
        setState(() {
          communityTermsAccepted = true;
        });

        return true;
      }

      showMessage(
        result['message']?.toString() ?? 'บันทึกการยอมรับกฎไม่สำเร็จ',
      );
    } catch (e) {
      if (mounted) {
        showMessage(e.toString());
      }
    }

    return false;
  }

  // =====================================================
  // สร้างโพสต์
  // =====================================================

  // เลือกรูปจากเครื่อง (รวมแล้วไม่เกิน 10 รูป)
  // ย่อรูปก่อนส่ง เหมือนรูปโปรไฟล์ เพื่อให้อัปโหลดเร็ว
  Future<void> pickImages() async {
    dismissKeyboard();

    final int remaining = maxPostImages - pickedImages.length;

    if (remaining <= 0) {
      composerMessage('แนบรูปได้สูงสุด $maxPostImages รูป');
      return;
    }

    try {
      final List<XFile> images = await imagePicker.pickMultiImage(
        limit: remaining,
        maxWidth: 1600,
        imageQuality: 80,
      );

      if (!mounted || images.isEmpty) return;

      // เครื่องรุ่นเก่าบางรุ่นไม่จำกัดจำนวนให้ → ตัดเอง
      updateComposer(() {
        pickedImages.addAll(images.take(remaining));
        composerError = images.length > remaining
            ? 'แนบรูปได้สูงสุด $maxPostImages รูป'
            : null;
      });
    } catch (e) {
      if (!mounted) return;

      composerMessage('เลือกรูปไม่สำเร็จ กรุณาลองอีกครั้ง');
    }
  }

  // เปลี่ยนร่างโพสต์ แล้วให้หน้าต่างเขียนโพสต์วาดใหม่ด้วย
  void updateComposer(VoidCallback change) {
    setState(change);

    composerVersion.value++;
  }

  // ข้อความ Error: แสดงในหน้าต่างเขียนโพสต์ถ้าเปิดอยู่ (SnackBar ถูกบัง)
  void composerMessage(String message) {
    if (composerContext != null) {
      updateComposer(() => composerError = message);
    } else {
      showMessage(message);
    }
  }

  // =====================================================
  // หน้าต่างเขียนโพสต์ (Bottom Sheet)
  // =====================================================

  Future<void> openComposer() async {
    composerError = null;

    if (scope == FeedScope.community) loadPopularHashtags();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: AppColors.surface,
      builder: (sheetContext) {
        composerContext = sheetContext;

        return Padding(
          // ยกหน้าต่างขึ้นเหนือคีย์บอร์ด
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
          ),
          child: ValueListenableBuilder<int>(
            valueListenable: composerVersion,
            builder: (context, version, child) {
              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: buildComposer(),
              );
            },
          ),
        );
      },
    );

    composerContext = null;
    composerError = null;
  }

  void closeComposer() {
    final BuildContext? sheet = composerContext;

    if (sheet != null && sheet.mounted) {
      Navigator.of(sheet).pop();
    }
  }

  Future<void> createPost() async {
    // ช่องแฮชแท็กยังพิมพ์ค้างอยู่ → นับด้วย
    if (hashtagController.text.trim().isNotEmpty) {
      addHashtags(hashtagController.text);
      hashtagController.clear();
    }

    // แฮชแท็กต่อท้ายข้อความ เช่น "แกงเขียวหวาน #ทำอาหาร #อร่อย"
    final String tags = scope == FeedScope.community
        ? composeHashtags.map((tag) => '#$tag').join(' ')
        : '';

    final String content = [
      postController.text.trim(),
      tags,
    ].where((part) => part.isNotEmpty).join(' ');

    final List<String> imagePaths = pickedImages
        .map((image) => image.path)
        .toList();

    if (content.isEmpty && imagePaths.isEmpty && pickedVideo == null) {
      composerMessage('กรุณาพิมพ์ข้อความ หรือเพิ่มรูป/วิดีโอก่อนโพสต์');
      return;
    }

    final FeedScope target = scope;

    if (target == FeedScope.community && !communityTermsAccepted) {
      final bool ok = await ensureCommunityTerms();

      if (!ok || !mounted) return;
    }

    updateComposer(() {
      isPosting = true;
      composerError = null;
    });

    final String? category = target == FeedScope.community
        ? composeCategory
        : null;

    // แผนที่แสดงเฉพาะข้อความ (โพสต์ที่มีแต่รูปไม่แสดง)
    final bool showOnMap =
        target == FeedScope.family && composeShowOnMap && content.isNotEmpty;

    try {
      PostVideoFile? video;

      if (pickedVideo != null) {
        video = await prepareVideo(pickedVideo!);

        if (video == null || !mounted) return;

        updateComposer(() => postingStatus = 'กำลังโพสต์…');
      }

      final result = await PostService.createPost(
        content,
        visibility: apiScope(target),
        category: category,
        imagePaths: imagePaths,
        showOnMap: showOnMap,
        video: video,
      );

      if (!mounted) return;

      if (result['status'] == true) {
        postController.clear();

        hashtagController.clear();

        composeHashtags.clear();

        showHashtagField = false;

        dismissKeyboard();

        // กรองหมวดอื่นอยู่ → กลับไป "ทั้งหมด" ให้เห็นโพสต์ที่เพิ่งแชร์
        final bool clearFilter =
            filterCategory != null && filterCategory != category;

        updateComposer(() {
          pickedImages.clear();

          pickedVideo = null;

          composeCategory = 'general';

          composeShowOnMap = false;

          if (clearFilter) {
            filterCategory = null;
            feedGeneration++;
          }
        });

        if (clearFilter) widget.onCategoryChanged?.call(null);

        closeComposer();

        if (scrollController.hasClients) {
          scrollController.jumpTo(0);
        }

        await loadPosts();

        if (!mounted) return;

        showMessage(
          target == FeedScope.community
              ? 'แชร์ในชุมชนแล้ว'
              : showOnMap
              ? 'แชร์ให้กลุ่มแล้ว และแสดงบนแผนที่ 12 ชั่วโมง'
              : 'แชร์ให้กลุ่มแล้ว',
        );
      } else if (result['code'] == 'terms_required') {
        setState(() {
          communityTermsAccepted = false;
        });

        composerMessage(
          result['message']?.toString() ?? 'กรุณายอมรับกฎชุมชนก่อนโพสต์',
        );
      } else {
        composerMessage(result['message']?.toString() ?? 'โพสต์ไม่สำเร็จ');
      }
    } catch (e) {
      if (!mounted) return;

      composerMessage(e.toString());
    } finally {
      if (mounted) {
        updateComposer(() {
          isPosting = false;
          postingStatus = null;
        });
      }
    }
  }

  // =====================================================
  // วิดีโอ: เลือก / ถ่าย → บีบอัด 720p → อัปโหลด
  // =====================================================

  Future<void> pickVideo() async {
    dismissKeyboard();

    final ImageSource? source = await showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                Icons.video_library_outlined,
                color: AppColors.primary,
              ),
              title: const Text('เลือกจากคลังวิดีโอ'),
              onTap: () => Navigator.of(sheetContext).pop(ImageSource.gallery),
            ),
            ListTile(
              leading: Icon(Icons.videocam_outlined, color: AppColors.primary),
              title: const Text('ถ่ายวิดีโอ'),
              subtitle: const Text('ยาวไม่เกิน $maxVideoSeconds วินาที'),
              onTap: () => Navigator.of(sheetContext).pop(ImageSource.camera),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (source == null || !mounted) return;

    try {
      final XFile? file = await imagePicker.pickVideo(
        source: source,
        maxDuration: const Duration(seconds: maxVideoSeconds),
      );

      if (file == null || !mounted) return;

      final MediaInfo info = await VideoCompress.getMediaInfo(file.path);

      final double seconds = (info.duration ?? 0) / 1000;

      if (seconds > maxVideoSeconds + 1) {
        composerMessage('วิดีโอต้องยาวไม่เกิน $maxVideoSeconds วินาที');
        return;
      }

      File? thumbnail;

      try {
        thumbnail = await VideoCompress.getFileThumbnail(
          file.path,
          quality: 70,
        );
      } catch (_) {
        // ไม่มีรูปตัวอย่างก็โพสต์ได้
      }

      if (!mounted) return;

      updateComposer(() {
        pickedVideo = PostVideoFile(
          filePath: file.path,
          thumbnailPath: thumbnail?.path,
          durationSeconds: seconds.round(),
          // video_compress หมุนขนาดตามการถ่าย (แนวตั้ง/แนวนอน) ให้แล้ว
          width: info.width,
          height: info.height,
        );

        composerError = null;
      });
    } catch (e) {
      if (mounted) composerMessage('เลือกวิดีโอไม่สำเร็จ กรุณาลองอีกครั้ง');
    }
  }

  // บีบอัดเป็น 720p (คืนที่อยู่ไฟล์ที่ได้ / ไม่สำเร็จหรือนานเกิน → ไฟล์เดิม)
  Future<String> compressVideo(String path) async {
    updateComposer(() => postingStatus = 'กำลังบีบอัดวิดีโอ…');

    final Subscription progress = VideoCompress.compressProgress$.subscribe((
      value,
    ) {
      if (mounted) {
        updateComposer(
          () => postingStatus = 'กำลังบีบอัดวิดีโอ ${value.round()}%',
        );
      }
    });

    try {
      final MediaInfo? compressed = await VideoCompress.compressVideo(
        path,
        quality: VideoQuality.Res1280x720Quality,
        includeAudio: true,
      ).timeout(compressTimeLimit);

      return compressed?.path ?? path;
    } catch (_) {
      await VideoCompress.cancelCompression();

      return path;
    } finally {
      progress.unsubscribe();
    }
  }

  // บีบอัด → ขอลิงก์ → อัปโหลดตรงเข้า Bucket (ถ้า Server ให้ลิงก์มา)
  // คืน null เมื่อไม่สำเร็จ (แสดงข้อความในหน้าต่างเขียนโพสต์แล้ว)
  Future<PostVideoFile?> prepareVideo(PostVideoFile picked) async {
    String path = picked.filePath;

    // ไฟล์เล็กอยู่แล้ว → ส่งเลย ไม่ต้องรอบีบอัด
    if (await File(path).length() > compressAboveBytes) {
      path = await compressVideo(path);
    }

    if (await File(path).length() > maxVideoBytes) {
      composerMessage('วิดีโอใหญ่เกิน 50 MB กรุณาเลือกวิดีโอที่สั้นลง');
      return null;
    }

    PostVideoFile video = PostVideoFile(
      filePath: path,
      thumbnailPath: picked.thumbnailPath,
      durationSeconds: picked.durationSeconds,
      width: picked.width,
      height: picked.height,
    );

    updateComposer(() => postingStatus = 'กำลังอัปโหลดวิดีโอ…');

    final ticket = await PostService.videoUploadTicket();

    if (ticket['status'] != true) {
      composerMessage(
        ticket['message']?.toString() ?? 'อัปโหลดวิดีโอไม่สำเร็จ',
      );
      return null;
    }

    final dynamic upload = ticket['upload'];

    if (upload is Map) {
      final dynamic rawHeaders = upload['headers'];

      final bool ok = await PostService.uploadVideoFile(
        url: upload['url'].toString(),
        headers: rawHeaders is Map
            ? rawHeaders.map((key, value) => MapEntry('$key', '$value'))
            : const {},
        filePath: path,
      );

      if (!ok) {
        composerMessage('อัปโหลดวิดีโอไม่สำเร็จ กรุณาลองอีกครั้ง');
        return null;
      }

      video = video.withUploadedPath(upload['path'].toString());
    }

    return video;
  }

  // =====================================================
  // ลบโพสต์
  // =====================================================

  // โพสต์ที่กำลังบันทึก/ยกเลิก (กันกดซ้ำ)
  final Set<int> savingPostIds = {};

  // บันทึก / ยกเลิกบันทึก: แสดงผลทันทีทุกหน้า (PostEvents) ไม่สำเร็จ → คืนสถานะเดิม + แจ้ง
  Future<void> toggleSave(Map<String, dynamic> post, int postId) async {
    if (savingPostIds.contains(postId)) return;

    final bool wasSaved = post['saved_by_me'] == true;

    savingPostIds.add(postId);
    PostEvents.emit(postId, {'saved_by_me': !wasSaved});

    try {
      final result = wasSaved
          ? await PostService.unsavePost(postId)
          : await PostService.savePost(postId);

      if (result['status'] != true) {
        throw Exception(result['message'] ?? 'ทำรายการไม่สำเร็จ');
      }

      PostEvents.emit(postId, {
        'saved_by_me': !wasSaved,
        'saved_confirmed': !wasSaved,
      });

      if (mounted) {
        showMessage(wasSaved ? 'ยกเลิกบันทึกแล้ว' : 'บันทึกโพสต์แล้ว');
      }
    } catch (e) {
      PostEvents.emit(postId, {'saved_by_me': wasSaved});

      if (mounted) {
        final String text = e.toString().replaceFirst('Exception: ', '');
        showMessage(
          text.isEmpty
              ? (wasSaved ? 'ยกเลิกบันทึกไม่สำเร็จ' : 'บันทึกโพสต์ไม่สำเร็จ')
              : text,
        );
      }
    } finally {
      savingPostIds.remove(postId);
    }
  }

  // แก้ไขข้อความโพสต์ของตัวเอง → ทุกหน้าที่แสดงโพสต์นี้อัปเดตตาม (PostEvents)
  // หน้านี้ยังเปิดอยู่ข้างหลัง → ตำแหน่งเลื่อนและคำค้นเดิม
  Future<void> editPost(Map<String, dynamic> post) async {
    final Map<String, dynamic>? updated = await Navigator.of(context)
        .push<Map<String, dynamic>>(
          MaterialPageRoute(builder: (_) => PostEditPage(post: post)),
        );

    if (updated == null) return;

    PostEvents.edited(updated);

    if (mounted) showMessage('บันทึกการแก้ไขแล้ว');
  }

  Future<void> confirmDeletePost(int postId) async {
    dismissKeyboard();

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          icon: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: AppColors.danger.withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.delete_outline_rounded,
              color: AppColors.danger,
              size: 28,
            ),
          ),
          title: const Text('ลบโพสต์นี้?'),
          content: const Text(
            'โพสต์และความคิดเห็นทั้งหมดจะถูกลบถาวร\n'
            'และไม่สามารถกู้คืนได้',
            textAlign: TextAlign.center,
          ),
          actionsPadding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          actions: [
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 48),
                      foregroundColor: AppColors.navy,
                    ),
                    onPressed: () {
                      Navigator.of(dialogContext).pop(false);
                    },
                    child: const Text('ยกเลิก'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.danger,
                      minimumSize: const Size(0, 48),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                    onPressed: () {
                      Navigator.of(dialogContext).pop(true);
                    },
                    child: const Text('ลบโพสต์'),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );

    if (confirmed == true) {
      await deletePost(postId);
    }
  }

  Future<void> deletePost(int postId) async {
    setState(() {
      deletingPostIds.add(postId);
    });

    try {
      final result = await PostService.deletePost(postId);

      if (!mounted) return;

      if (result['status'] == true) {
        setState(() {
          removePost(postId);
        });

        showMessage(result['message']?.toString() ?? 'ลบโพสต์แล้ว');
      } else {
        showMessage(result['message']?.toString() ?? 'ลบโพสต์ไม่สำเร็จ');
      }
    } catch (e) {
      if (!mounted) return;

      showMessage(e.toString());
    } finally {
      if (mounted) {
        setState(() {
          deletingPostIds.remove(postId);
        });
      }
    }
  }

  void removePost(int postId) {
    feed.posts.removeWhere((post) => postIdOf(post) == postId);

    expandedPostIds.remove(postId);
  }

  // =====================================================
  // ถูกใจ / ยกเลิกถูกใจ
  // เปลี่ยนบนจอทันที ถ้า Server ตอบผิดพลาดค่อยคืนค่าเดิม
  // =====================================================

  Future<void> toggleLike(Map<String, dynamic> post, int postId) async {
    if (likingPostIds.contains(postId)) return;

    final bool wasLiked = isLikedByMe(post);

    final int oldCount = likesCountOf(post);

    void restore() {
      post['liked_by_me'] = wasLiked;
      post['likes_count'] = oldCount;
    }

    setState(() {
      likingPostIds.add(postId);

      post['liked_by_me'] = !wasLiked;
      post['likes_count'] = wasLiked
          ? (oldCount > 0 ? oldCount - 1 : 0)
          : oldCount + 1;
    });

    try {
      final result = await PostService.toggleLike(postId);

      if (!mounted) return;

      if (result['status'] == true) {
        // ใช้ตัวเลขจริงจาก Server (มีคนอื่นกดพร้อมกันได้)
        setState(() {
          post['liked_by_me'] = result['liked'] == true;
          post['likes_count'] = result['likes_count'] ?? post['likes_count'];
        });
      } else {
        setState(restore);

        showMessage(result['message']?.toString() ?? 'ถูกใจไม่สำเร็จ');
      }
    } catch (e) {
      if (!mounted) return;

      setState(restore);

      showMessage(e.toString());
    } finally {
      if (mounted) {
        setState(() {
          likingPostIds.remove(postId);
        });
      }
    }
  }

  // =====================================================
  // รายงานโพสต์ชุมชน
  // =====================================================

  Future<void> reportPost(int postId) async {
    dismissKeyboard();

    final String? reason = await showReportReasonSheet(context);

    if (reason == null || !mounted) return;

    try {
      final result = await PostService.reportPost(
        postId: postId,
        reason: reason,
      );

      if (!mounted) return;

      if (result['status'] == true) {
        // ซ่อนโพสต์ที่รายงานจากจอของเราทันที
        setState(() {
          removePost(postId);
        });

        showMessage(result['message']?.toString() ?? 'ขอบคุณที่รายงาน');
      } else {
        showMessage(result['message']?.toString() ?? 'รายงานไม่สำเร็จ');
      }
    } catch (e) {
      if (!mounted) return;

      showMessage(e.toString());
    }
  }

  // =====================================================
  // บล็อกผู้ใช้ในชุมชน
  // =====================================================

  Future<void> blockAuthor(int userId, String name) async {
    dismissKeyboard();

    final bool confirmed = await showBlockUserDialog(context, name);

    if (!confirmed || !mounted) return;

    try {
      final result = await PostService.blockUser(userId);

      if (!mounted) return;

      if (result['status'] == true) {
        setState(() {
          removeUserFromCommunity(userId);
        });

        widget.onUserBlocked?.call(userId);

        showMessage(result['message']?.toString() ?? 'บล็อก $name แล้ว');
      } else {
        showMessage(result['message']?.toString() ?? 'บล็อกไม่สำเร็จ');
      }
    } catch (e) {
      if (!mounted) return;

      showMessage(e.toString());
    }
  }

  // เอาโพสต์และความคิดเห็นของคนที่บล็อกออกจากฟีดชุมชน
  void removeUserFromCommunity(int userId) {
    feed.posts.removeWhere((post) => authorIdOf(post) == userId);

    for (final post in feed.posts) {
      final dynamic comments = post['comments'];

      if (comments is List) {
        post['comments'] = comments
            .where(
              (comment) =>
                  !(comment is Map &&
                      comment['user_id']?.toString() == userId.toString()),
            )
            .toList();
      }
    }
  }

  // =====================================================
  // ความคิดเห็นของคนอื่นในฟีดชุมชน: รายงาน / บล็อก
  // =====================================================

  Future<void> openCommentActions({
    required int commentId,
    required int? authorId,
    required String authorName,
  }) async {
    dismissKeyboard();

    final String? action = await showCommentActionsSheet(
      context,
      authorName: authorName,
    );

    if (!mounted || action == null) return;

    if (action == 'report') {
      await reportComment(commentId);
    } else if (action == 'block' && authorId != null) {
      await blockAuthor(authorId, authorName);
    }
  }

  Future<void> reportComment(int commentId) async {
    final String? reason = await showReportReasonSheet(
      context,
      title: 'รายงานความคิดเห็นนี้',
    );

    if (reason == null || !mounted) return;

    try {
      final result = await PostService.reportComment(
        commentId: commentId,
        reason: reason,
      );

      if (!mounted) return;

      if (result['status'] == true) {
        // ซ่อนความคิดเห็นที่รายงานจากจอของเราทันที
        setState(() {
          removeComment(commentId);
        });

        showMessage(result['message']?.toString() ?? 'ขอบคุณที่รายงาน');
      } else {
        showMessage(result['message']?.toString() ?? 'รายงานไม่สำเร็จ');
      }
    } catch (e) {
      if (!mounted) return;

      showMessage(e.toString());
    }
  }

  void removeComment(int commentId) {
    for (final post in feed.posts) {
      final dynamic comments = post['comments'];

      if (comments is List) {
        post['comments'] = comments
            .where(
              (comment) =>
                  !(comment is Map &&
                      comment['id']?.toString() == commentId.toString()),
            )
            .toList();
      }
    }
  }

  // =====================================================
  // Comment
  // ใช้ local String แทน Controller
  // เพื่อป้องกัน Dialog lifecycle error เดิม
  // =====================================================

  // ความคิดเห็น: แผ่นเลื่อนขึ้นแบบเดียวกับหน้าวิดีโอ (แนบรูป/GIF/วิดีโอได้)
  Future<void> openComments(int postId) async {
    dismissKeyboard();

    Map<String, dynamic>? post;

    for (final item in feed.posts) {
      if (postIdOf(item) == postId) post = item;
    }

    if (post == null) return;

    await showCommentsSheet(
      context,
      post: post,
      myId: (currentUser?['id'] as num?)?.toInt(),
      onChanged: () {
        if (mounted) setState(() {});
      },
    );
  }

  // ปิดคีย์บอร์ดของกล่องเขียนโพสต์
  // ใช้ primaryFocus.unfocus() เพื่อไม่ให้ Flutter คืนโฟกัส
  // กลับไปที่ช่องพิมพ์หลังปิด Dialog / Bottom Sheet
  void dismissKeyboard() {
    FocusManager.instance.primaryFocus?.unfocus();
  }

  // =====================================================
  // SnackBar
  // =====================================================

  void showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // =====================================================
  // HELPERS
  // =====================================================

  int? postIdOf(Map<String, dynamic> post) {
    final dynamic id = post['id'];

    return id is num ? id.toInt() : null;
  }

  int? authorIdOf(Map<String, dynamic> post) {
    final dynamic id =
        post['user_id'] ??
        (post['user'] is Map ? (post['user'] as Map)['id'] : null);

    return id is num ? id.toInt() : int.tryParse('$id');
  }

  bool isCommunityPost(Map<String, dynamic> post) {
    return post['visibility'] == 'community';
  }

  // URL รูปในโพสต์ ตามลำดับที่ Server ส่งมา
  List<String> imageUrlsOf(Map<String, dynamic> post) {
    final dynamic images = post['images'];

    if (images is! List) return const [];

    return images
        .whereType<Map>()
        .map((image) => image['url']?.toString() ?? '')
        .where((url) => url.isNotEmpty)
        .toList();
  }

  int likesCountOf(Map<String, dynamic> post) {
    final dynamic count = post['likes_count'];

    return count is num ? count.toInt() : int.tryParse('$count') ?? 0;
  }

  bool isLikedByMe(Map<String, dynamic> post) {
    final dynamic liked = post['liked_by_me'];

    return liked == true || liked == 1;
  }

  // ใช้ is_mine จาก Laravel ถ้ามี
  // ถ้าไม่มี (Server เวอร์ชันเก่า) เทียบ user_id กับผู้ใช้ปัจจุบัน
  bool isMine(Map<String, dynamic> post) {
    final dynamic mine = post['is_mine'];

    if (mine is bool) {
      return mine;
    }

    final dynamic myId = currentUser?['id'];

    return myId != null && post['user_id']?.toString() == myId.toString();
  }

  // วันที่บนหัวการ์ดโพสต์: ไม่ถึงชั่วโมง = X นาทีที่แล้ว / วันนี้ / เมื่อวาน / 1 พ.ย. (ปีอื่นมีปี)
  String postDate(dynamic value) {
    final DateTime? date = DateTime.tryParse(value?.toString() ?? '')
        ?.toLocal();

    if (date == null) return '';

    final DateTime now = DateTime.now();
    final Duration age = now.difference(date);

    if (age.inMinutes < 1) return 'เมื่อสักครู่';
    if (age.inMinutes < 60) return '${age.inMinutes} นาทีที่แล้ว';

    final int days = DateTime(
      now.year,
      now.month,
      now.day,
    ).difference(DateTime(date.year, date.month, date.day)).inDays;

    if (days == 0) return 'วันนี้';
    if (days == 1) return 'เมื่อวาน';

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

    return date.year == now.year
        ? '${date.day} ${months[date.month]}'
        : '${date.day} ${months[date.month]} ${date.year + 543}';
  }

  String formatDate(dynamic value) {
    if (value == null) {
      return '';
    }

    try {
      final date = DateTime.parse(value.toString()).toLocal();

      final difference = DateTime.now().difference(date);

      if (difference.inMinutes < 1) {
        return 'เมื่อสักครู่';
      }

      if (difference.inMinutes < 60) {
        return '${difference.inMinutes} นาทีที่แล้ว';
      }

      if (difference.inHours < 24) {
        return '${difference.inHours} ชั่วโมงที่แล้ว';
      }

      if (difference.inDays < 7) {
        return '${difference.inDays} วันที่แล้ว';
      }

      final day = date.day.toString().padLeft(2, '0');

      final month = date.month.toString().padLeft(2, '0');

      return '$day/$month/${date.year}';
    } catch (_) {
      return '';
    }
  }

  // ตัวอักษรบน Avatar
  // ชื่อไทยที่ขึ้นต้นด้วยสระหน้า (เ แ โ ใ ไ) ใช้พยัญชนะตัวถัดไป
  // และไม่เอาวรรณยุกต์ เช่น "แม่" → "ม", "พ่อ" → "พ"
  String getInitial(dynamic name) {
    final text = name?.toString().trim() ?? '';

    if (text.isEmpty) {
      return '?';
    }

    final runes = text.runes.toList();

    const leadingVowels = 'เแโใไ';

    final int index =
        runes.length > 1 &&
            leadingVowels.contains(String.fromCharCode(runes.first))
        ? 1
        : 0;

    return String.fromCharCode(runes[index]).toUpperCase();
  }

  // รองรับชื่อ key หลายแบบจาก API
  String? getProfileImage(dynamic user) {
    if (user is! Map) {
      return null;
    }

    const possibleKeys = [
      'profile_image_url',
      'profile_photo_url',
      'profile_image',
      'avatar_url',
      'avatar',
      'photo_url',
      'photo',
      'image_url',
      'image',
    ];

    for (final key in possibleKeys) {
      final value = user[key]?.toString().trim();

      if (value != null && value.isNotEmpty && value.toLowerCase() != 'null') {
        return value;
      }
    }

    return null;
  }

  BoxDecoration cardDecoration() {
    return AppDecorations.card(radius: 24);
  }

  // =====================================================
  // Avatar
  // =====================================================

  // กดรูป/ชื่อ → เปิดโปรไฟล์ในชุมชน
  // (ไม่เปิดซ้ำเมื่ออยู่ในหน้าโปรไฟล์ของคนนั้นอยู่แล้ว)
  Widget buildProfileLink({
    required int? userId,
    required String name,
    required Widget child,
  }) {
    if (userId == null || userId == widget.authorId) return child;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => openUserProfile(userId, name),
      child: child,
    );
  }

  // กดแท็กเดียวกับหน้าที่เปิดอยู่ → ไม่ต้องเปิดซ้ำ
  void openHashtag(String tag) {
    if (widget.hashtag?.toLowerCase() == tag.toLowerCase()) return;

    openHashtagPage(context, tag);
  }

  void openUserProfile(int userId, String name) {
    dismissKeyboard();

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => UserProfilePage(
          userId: userId,
          name: name,
          onBlockChanged: (blocked) {
            if (!mounted) return;

            // บล็อก → ซ่อนโพสต์ของเขาจากฟีดนี้ / เลิกบล็อก → โหลดใหม่
            if (blocked) {
              setState(() => removeUserFromCommunity(userId));
            } else {
              loadPosts();
            }
          },
        ),
      ),
    );
  }

  // โพสต์ของเราที่ถูกซ่อนจากชุมชน (หน้าโพสต์ของฉัน)
  Widget buildHiddenNotice() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.07),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.visibility_off_outlined,
            size: 16,
            color: AppColors.danger,
          ),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'ซ่อนจากชุมชนแล้ว เพราะถูกรายงาน (รอผู้ดูแลตรวจ)',
              style: TextStyle(
                color: AppColors.danger,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget buildAvatar({
    required String name,
    String? imageUrl,
    double radius = 22,
  }) {
    final double size = radius * 2;

    Widget fallbackAvatar() {
      return Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.primary, Color(0xFF7B80FF)],
          ),
          shape: BoxShape.circle,
        ),
        child: Text(
          getInitial(name),
          style: TextStyle(
            color: Colors.white,
            fontSize: radius * 0.72,
            fontWeight: FontWeight.w800,
          ),
        ),
      );
    }

    final bool hasImage = imageUrl != null && imageUrl.trim().isNotEmpty;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: AppColors.navy.withValues(alpha: 0.10),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipOval(
        child: hasImage
            ? Image.network(
                imageUrl.trim(),
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) {
                  return fallbackAvatar();
                },
              )
            : fallbackAvatar(),
      ),
    );
  }

  // =====================================================
  // ปุ่ม + ลอยมุมขวาล่าง (มีจุดเมื่อมีร่างโพสต์ค้างอยู่)
  // =====================================================

  Widget buildComposeButton() {
    final bool community = scope == FeedScope.community;

    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: postController,
      builder: (context, value, child) {
        final bool hasDraft =
            value.text.trim().isNotEmpty ||
            pickedImages.isNotEmpty ||
            pickedVideo != null;

        return FloatingActionButton(
          heroTag: null,
          tooltip: community ? 'โพสต์ในชุมชน' : 'โพสต์ถึงกลุ่ม',
          backgroundColor: community ? communityColor : AppColors.primary,
          foregroundColor: Colors.white,
          shape: const CircleBorder(),
          onPressed: widget.onJoinFamily == null
              ? openComposer
              : askToJoinFamily,
          child: Badge(
            isLabelVisible: hasDraft,
            smallSize: 10,
            backgroundColor: AppColors.warm,
            child: const Icon(Icons.add_rounded, size: 30),
          ),
        );
      },
    );
  }

  // =====================================================
  // เนื้อหาหน้าต่างเขียนโพสต์
  // =====================================================

  // =====================================================
  // แฮชแท็กแนะนำตอนเขียนโพสต์ชุมชน
  // พิมพ์ # แล้ว → แท็กยอดนิยมที่ขึ้นต้นตรงกัน / ยังไม่พิมพ์ → แท็กยอดนิยม
  // =====================================================

  // โหลดครั้งเดียวต่อการเปิดแอป
  static List<String>? popularHashtags;

  Future<void> loadPopularHashtags() async {
    if (popularHashtags != null) return;

    try {
      final result = await PostService.popularHashtags();

      final dynamic raw = result['hashtags'];

      if (result['status'] != true || raw is! List) return;

      popularHashtags = raw
          .whereType<Map>()
          .map((tag) => tag['name']?.toString() ?? '')
          .where((name) => name.isNotEmpty)
          .toList();

      composerVersion.value++;
    } catch (_) {
      // ไม่มีแท็กแนะนำก็ยังโพสต์ได้
    }
  }

  // ใส่ได้ตรงกับ Laravel (Hashtag::MAX_PER_POST)
  static const int maxPostHashtags = 10;

  // คำที่พิมพ์ → แท็ก (ตัด # ออก) / null = ใช้ไม่ได้ เช่น มีเครื่องหมายอื่นปน
  String? cleanHashtag(String raw) {
    final String tag = raw.trim().replaceFirst(RegExp(r'^#+'), '');

    if (tag.isEmpty) return null;

    final RegExpMatch? match = hashtagPattern.firstMatch('#$tag');

    if (match == null || match.group(1) != tag || !isCountedHashtag(tag)) {
      return null;
    }

    return tag;
  }

  // เพิ่มหลายคำได้ในครั้งเดียว (คั่นด้วยเว้นวรรค / จุลภาค)
  void addHashtags(String raw) {
    final List<String> words = raw
        .split(RegExp(r'[\s,]+'))
        .where((word) => word.isNotEmpty)
        .toList();

    if (words.isEmpty) return;

    updateComposer(() {
      composerError = null;

      for (final word in words) {
        final String? tag = cleanHashtag(word);

        if (tag == null) {
          composerError = 'แฮชแท็กใช้ได้เฉพาะตัวอักษร ตัวเลข และ _';
          continue;
        }

        final bool exists = composeHashtags.any(
          (item) => item.toLowerCase() == tag.toLowerCase(),
        );

        if (exists) continue;

        if (composeHashtags.length >= maxPostHashtags) {
          composerError = 'ใส่แฮชแท็กได้สูงสุด $maxPostHashtags แท็ก';
          break;
        }

        composeHashtags.add(tag);
      }
    });
  }

  // พิมพ์เว้นวรรค / จุลภาค → คำก่อนหน้ากลายเป็นป้ายแท็ก
  void onHashtagTyping(String value) {
    if (!value.contains(RegExp(r'[\s,]'))) return;

    final List<String> parts = value.split(RegExp(r'[\s,]+'));

    // คำสุดท้ายที่ยังพิมพ์ไม่จบ เก็บไว้ในช่องต่อ
    final String rest = RegExp(r'[\s,]$').hasMatch(value)
        ? ''
        : parts.removeLast();

    addHashtags(parts.join(' '));

    hashtagController.value = TextEditingValue(
      text: rest,
      selection: TextSelection.collapsed(offset: rest.length),
    );
  }

  // =====================================================
  // ช่องแฮชแท็ก (โพสต์ชุมชน) แยกจากข้อความ
  // ตอนโพสต์นำไปต่อท้ายข้อความ (createPost)
  // =====================================================

  Widget buildHashtagField() {
    final inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide.none,
    );

    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: hashtagController,
      builder: (context, value, child) {
        final String typed = value.text
            .trim()
            .replaceFirst(RegExp(r'^#+'), '')
            .toLowerCase();

        // แท็กยอดนิยมที่ยังไม่ได้ใส่ (พิมพ์อยู่ → เฉพาะที่ขึ้นต้นตรงกัน)
        final List<String> suggestions = (popularHashtags ?? const <String>[])
            .where(
              (tag) =>
                  !composeHashtags.any((item) => item.toLowerCase() == tag),
            )
            .where((tag) => typed.isEmpty || tag.startsWith(typed))
            .take(8)
            .toList();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 12),
            TextField(
              controller: hashtagController,
              focusNode: hashtagFocus,
              textInputAction: TextInputAction.done,
              onChanged: onHashtagTyping,
              onSubmitted: (text) {
                addHashtags(text);
                hashtagController.clear();
              },
              decoration: InputDecoration(
                hintText: 'แฮชแท็ก เช่น ทำอาหาร แล้วกดเว้นวรรค',
                prefixIcon: Icon(Icons.tag_rounded, color: communityColor),
                isDense: true,
                filled: true,
                fillColor: AppColors.fill,
                border: inputBorder,
                enabledBorder: inputBorder,
                focusedBorder: inputBorder.copyWith(
                  borderSide: BorderSide(
                    color: communityColor.withValues(alpha: 0.45),
                    width: 1.4,
                  ),
                ),
              ),
            ),
            if (composeHashtags.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final tag in composeHashtags)
                    InputChip(
                      label: Text('#$tag'),
                      onDeleted: () =>
                          updateComposer(() => composeHashtags.remove(tag)),
                      labelStyle: TextStyle(
                        color: communityColor,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                      deleteIconColor: communityColor,
                      backgroundColor: communityColor.withValues(alpha: 0.10),
                      side: BorderSide.none,
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ],
            if (suggestions.isNotEmpty) ...[
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    Text(
                      'ยอดนิยม',
                      style: TextStyle(color: AppColors.muted, fontSize: 12),
                    ),
                    const SizedBox(width: 6),
                    for (final tag in suggestions) ...[
                      ActionChip(
                        label: Text('#$tag'),
                        onPressed: () {
                          addHashtags(tag);
                          hashtagController.clear();
                        },
                        labelStyle: TextStyle(
                          color: communityColor,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                        side: BorderSide(
                          color: communityColor.withValues(alpha: 0.25),
                        ),
                        backgroundColor: communityColor.withValues(alpha: 0.06),
                        visualDensity: VisualDensity.compact,
                      ),
                      const SizedBox(width: 6),
                    ],
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget buildComposer() {
    final inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: BorderSide.none,
    );

    final bool community = scope == FeedScope.community;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // หัว: รูป + โพสต์ไปที่ไหน ใครเห็น / ชุมชน: ปุ่มเลือกหมวด
        Row(
          children: [
            buildAvatar(
              name: currentUser?['name']?.toString() ?? 'F',
              imageUrl: getProfileImage(currentUser),
              radius: 19,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    community ? 'โพสต์ในชุมชน' : 'โพสต์ถึงกลุ่ม',
                    style: TextStyle(
                      color: AppColors.navy,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Row(
                    children: [
                      Icon(
                        community
                            ? Icons.public_rounded
                            : Icons.lock_outline_rounded,
                        size: 13,
                        color: AppColors.muted,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        community ? 'ทุกคนในชุมชนเห็น' : 'เฉพาะกลุ่ม',
                        style: TextStyle(color: AppColors.muted, fontSize: 12),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (community) buildCategoryButton(),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: postController,
                autofocus: true,
                minLines: 4,
                maxLines: 10,
                maxLength: maxPostLength,
                textCapitalization: TextCapitalization.sentences,

                // แสดงตัวนับเมื่อใกล้ถึงขีดจำกัด
                buildCounter:
                    (
                      context, {
                      required currentLength,
                      required isFocused,
                      required maxLength,
                    }) {
                      if (currentLength < maxPostLength - 500) {
                        return null;
                      }

                      return Text(
                        '$currentLength/$maxPostLength',
                        style: TextStyle(color: AppColors.muted, fontSize: 11),
                      );
                    },

                decoration: InputDecoration(
                  hintText: scope == FeedScope.community
                      ? 'แชร์เรื่องราวให้ทุกคนในชุมชน...'
                      : 'มีอะไรอยากเล่าให้คนในกลุ่มฟังไหม?',
                  filled: true,
                  fillColor: AppColors.fill,
                  contentPadding: const EdgeInsets.all(16),
                  border: inputBorder,
                  enabledBorder: inputBorder,
                  focusedBorder: inputBorder.copyWith(
                    borderSide: BorderSide(
                      color: AppColors.primary.withValues(alpha: 0.45),
                      width: 1.4,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        if (community && (showHashtagField || composeHashtags.isNotEmpty))
          buildHashtagField(),
        if (pickedImages.isNotEmpty) ...[
          const SizedBox(height: 12),
          buildPickedImages(),
        ],
        if (pickedVideo != null) ...[
          const SizedBox(height: 12),
          buildPickedVideo(),
        ],
        if (scope == FeedScope.family) ...[
          const SizedBox(height: 12),
          buildMapStatusOption(),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            // แถบเครื่องมือ: รูป / วิดีโอ / แฮชแท็ก
            Expanded(
              child: Row(
                children: [
                  buildAddPhotoButton(),
                  const SizedBox(width: 8),
                  buildAddVideoButton(),
                  if (community) ...[
                    const SizedBox(width: 8),
                    buildHashtagButton(),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),

            // ปุ่มแชร์กดได้เมื่อมีข้อความหรือมีรูป
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: postController,
              builder: (context, value, child) {
                final bool canPost =
                    (value.text.trim().isNotEmpty ||
                        composeHashtags.isNotEmpty ||
                        pickedImages.isNotEmpty ||
                        pickedVideo != null) &&
                    !isPosting;

                return FilledButton.icon(
                  onPressed: canPost ? createPost : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: AppColors.primary.withValues(
                      alpha: 0.30,
                    ),
                    disabledForegroundColor: Colors.white,
                    minimumSize: const Size(0, 42),
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: isPosting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.send_rounded, size: 17),
                  label: Text(isPosting ? 'กำลังส่ง' : 'แชร์'),
                );
              },
            ),
          ],
        ),
        if (isPosting && postingStatus != null) ...[
          const SizedBox(height: 10),
          Text(
            postingStatus!,
            style: TextStyle(
              color: AppColors.primary,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
        if (composerError != null) ...[
          const SizedBox(height: 10),
          Text(
            composerError!,
            style: TextStyle(
              color: AppColors.danger,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }

  // โพสต์ครอบครัว: สวิตช์ "แสดงบนแผนที่" + ข้อความสั้นให้กดใส่
  Widget buildMapStatusOption() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
      decoration: BoxDecoration(
        color: composeShowOnMap ? AppColors.softPrimary : AppColors.fill,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.add_location_alt_outlined,
                size: 20,
                color: composeShowOnMap ? AppColors.primary : AppColors.muted,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'แสดงข้อความนี้บนแผนที่',
                      style: TextStyle(
                        color: AppColors.navy,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      'สมาชิกในกลุ่มเห็นข้างตำแหน่งของคุณ 12 ชั่วโมง',
                      style: TextStyle(color: AppColors.muted, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              Switch(
                value: composeShowOnMap,
                onChanged: isPosting
                    ? null
                    : (value) {
                        updateComposer(() => composeShowOnMap = value);
                      },
              ),
            ],
          ),
          if (composeShowOnMap) ...[
            const SizedBox(height: 2),
            buildChipStrip([
              for (final text in quickMapStatuses)
                ActionChip(
                  label: Text(text),
                  labelStyle: TextStyle(
                    color: AppColors.primary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                  backgroundColor: AppColors.surface,
                  side: BorderSide(
                    color: AppColors.primary.withValues(alpha: 0.25),
                  ),
                  shape: const StadiumBorder(),
                  visualDensity: VisualDensity.compact,
                  onPressed: isPosting
                      ? null
                      : () {
                          postController.text = text;
                          postController.selection = TextSelection.collapsed(
                            offset: text.length,
                          );
                        },
                ),
            ]),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

  // เมนูโพสต์: แสดงบนแผนที่ / เอาออกจากแผนที่
  Future<void> toggleMapStatus(Map<String, dynamic> post, int postId) async {
    if (mapUpdatingPostIds.contains(postId)) return;

    final bool show = post['on_map'] != true;

    setState(() => mapUpdatingPostIds.add(postId));

    try {
      final result = await PostService.setOnMap(postId, show);

      if (!mounted) return;

      if (result['status'] == true) {
        setState(() {
          // แสดงได้ทีละ 1 ข้อความ → โพสต์อื่นของเราออกจากแผนที่
          if (show) {
            for (final other in feed.posts) {
              if (isMine(other)) other['on_map'] = false;
            }
          }

          post['on_map'] = show;
        });
      }

      showMessage(
        result['message']?.toString() ??
            (result['status'] == true ? 'บันทึกแล้ว' : 'ตั้งค่าไม่สำเร็จ'),
      );
    } catch (e) {
      if (mounted) showMessage(e.toString());
    } finally {
      if (mounted) setState(() => mapUpdatingPostIds.remove(postId));
    }
  }

  // ป้าย "บนแผนที่" ข้างเวลาโพสต์
  Widget buildOnMapBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: AppColors.softPrimary,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.location_on_rounded, size: 11, color: AppColors.primary),
          const SizedBox(width: 2),
          Text(
            'บนแผนที่',
            style: TextStyle(
              color: AppColors.primary,
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  // ปุ่ม 📷 เพิ่มรูป (แสดงจำนวนที่เลือกแล้ว)
  Widget buildAddPhotoButton() {
    final int count = pickedImages.length;

    return Tooltip(
      message: 'เพิ่มรูป',
      child: Material(
        color: AppColors.softPrimary,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: isPosting || pickedVideo != null ? null : pickImages,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.add_photo_alternate_outlined,
                  size: 18,
                  // เลือกวิดีโอแล้ว → แนบรูปไม่ได้
                  color: pickedVideo == null
                      ? AppColors.primary
                      : AppColors.primary.withValues(alpha: 0.35),
                ),
                if (count > 0) ...[
                  const SizedBox(width: 4),
                  Text(
                    '$count/$maxPostImages',
                    style: TextStyle(
                      color: AppColors.primary,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ปุ่ม 🎬 เพิ่มวิดีโอ (โพสต์ละ 1 วิดีโอ ใช้แทนรูป)
  // ปุ่ม # : เปิด/ปิดช่องแฮชแท็ก (มีแท็กแล้ว → แสดงจำนวน ช่องเปิดค้าง)
  Widget buildHashtagButton() {
    final int count = composeHashtags.length;

    final bool active = showHashtagField || count > 0;

    return Tooltip(
      message: 'เพิ่มแฮชแท็ก',
      child: Material(
        color: active
            ? communityColor.withValues(alpha: 0.14)
            : AppColors.softPrimary,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: isPosting
              ? null
              : () {
                  final bool open = !showHashtagField || count > 0;

                  updateComposer(() => showHashtagField = open);

                  if (open) {
                    WidgetsBinding.instance.addPostFrameCallback(
                      (_) => hashtagFocus.requestFocus(),
                    );
                  }
                },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.tag_rounded,
                  size: 18,
                  color: active ? communityColor : AppColors.primary,
                ),
                if (count > 0) ...[
                  const SizedBox(width: 4),
                  Text(
                    '$count',
                    style: TextStyle(
                      color: communityColor,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ปุ่มหมวดของโพสต์ชุมชน (กดแล้วเลือกจากรายการ)
  Widget buildCategoryButton() {
    final PostCategory category =
        findPostCategory(composeCategory) ?? postCategories.first;

    return Material(
      color: category.color.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: isPosting ? null : pickCategory,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(category.icon, size: 16, color: category.color),
              const SizedBox(width: 5),
              Text(
                category.label,
                style: TextStyle(
                  color: category.color,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Icon(Icons.expand_more_rounded, size: 18, color: category.color),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> pickCategory() async {
    final String? key = await showModalBottomSheet<String>(
      context: composerContext ?? context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        // จอเล็กเลื่อนดูได้
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(
                  'หมวดของโพสต์',
                  style: TextStyle(
                    color: AppColors.navy,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              for (final category in postCategories)
                ListTile(
                  visualDensity: VisualDensity.compact,
                  leading: Icon(category.icon, color: category.color),
                  title: Text(category.label),
                  trailing: category.key == composeCategory
                      ? Icon(Icons.check_rounded, color: AppColors.primary)
                      : null,
                  onTap: () => Navigator.of(sheetContext).pop(category.key),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );

    if (key != null && mounted) {
      updateComposer(() => composeCategory = key);
    }
  }

  Widget buildAddVideoButton() {
    final bool enabled =
        !isPosting && pickedImages.isEmpty && pickedVideo == null;

    return Tooltip(
      message: 'เพิ่มวิดีโอ',
      child: Material(
        color: AppColors.softPrimary,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: enabled ? pickVideo : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Icon(
              Icons.videocam_outlined,
              size: 18,
              color: enabled
                  ? AppColors.primary
                  : AppColors.primary.withValues(alpha: 0.35),
            ),
          ),
        ),
      ),
    );
  }

  // วิดีโอที่เลือกไว้: รูปตัวอย่าง + ความยาว กด ✕ เพื่อเอาออก
  Widget buildPickedVideo() {
    final PostVideoFile video = pickedVideo!;

    const double size = 112;

    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Container(
            width: size,
            height: size,
            color: Colors.black,
            child: video.thumbnailPath == null
                ? const Icon(Icons.videocam_rounded, color: Colors.white54)
                : Image.file(
                    File(video.thumbnailPath!),
                    width: size,
                    height: size,
                    fit: BoxFit.cover,
                  ),
          ),
        ),
        const Positioned.fill(
          child: Center(
            child: Icon(
              Icons.play_circle_fill_rounded,
              color: Colors.white,
              size: 34,
            ),
          ),
        ),
        if (video.durationSeconds != null)
          Positioned(
            left: 6,
            bottom: 6,
            child: buildDurationBadge(video.durationSeconds!),
          ),
        Positioned(
          top: 4,
          right: 4,
          child: GestureDetector(
            onTap: isPosting
                ? null
                : () => updateComposer(() => pickedVideo = null),
            child: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.close_rounded,
                size: 15,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget buildDurationBadge(int seconds) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  // วิดีโอในโพสต์: รูปตัวอย่าง + ปุ่มเล่น แตะเพื่อเปิดดูเต็มจอ
  Widget buildVideo(Map<String, dynamic> video) {
    final String? url = video['url']?.toString();

    final String? thumbnail = video['thumbnail_url']?.toString();

    final double? width = (video['width'] as num?)?.toDouble();

    final double? height = (video['height'] as num?)?.toDouble();

    // แนวตั้งแสดงแค่ 3:4 ไม่ให้การ์ดยาวเกิน
    final double ratio =
        (width != null && height != null && width > 0 && height > 0)
        ? (width / height).clamp(0.75, 1.9)
        : 16 / 9;

    final int? seconds = (video['duration_seconds'] as num?)?.toInt();

    return GestureDetector(
      onTap: url == null
          ? null
          : () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => VideoPlayerPage(url: url)),
            ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: AspectRatio(
          aspectRatio: ratio,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: Colors.black),
              if (thumbnail != null)
                Image.network(
                  thumbnail,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) =>
                      const SizedBox.shrink(),
                ),
              Center(
                child: Container(
                  width: 62,
                  height: 62,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 42,
                  ),
                ),
              ),
              if (seconds != null)
                Positioned(
                  right: 10,
                  bottom: 10,
                  child: buildDurationBadge(seconds),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // รูปที่เลือกไว้ เลื่อนดูแนวนอน กด ✕ เพื่อเอาออก
  Widget buildPickedImages() {
    const double size = 76;

    return SizedBox(
      height: size,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: pickedImages.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final XFile image = pickedImages[index];

          return Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Image.file(
                  File(image.path),
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                  cacheWidth: 240,
                ),
              ),
              Positioned(
                top: 4,
                right: 4,
                child: Semantics(
                  button: true,
                  label: 'เอารูปที่ ${index + 1} ออก',
                  child: GestureDetector(
                    onTap: isPosting
                        ? null
                        : () {
                            updateComposer(() {
                              pickedImages.removeAt(index);
                            });
                          },
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.close_rounded,
                        size: 15,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // เลือกหมวดของโพสต์ชุมชนที่กำลังเขียน
  // กรองฟีดชุมชนตามหมวด ("ทั้งหมด" + 5 หมวด)
  Widget buildCategoryFilter() {
    return CategoryFilterStrip(
      selected: filterCategory,
      onChanged: changeFilter,
    );
  }

  // แถวชิปเลื่อนซ้าย-ขวาได้
  Widget buildChipStrip(List<Widget> chips) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (int i = 0; i < chips.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            chips[i],
          ],
        ],
      ),
    );
  }

  // บอกว่าโพสต์นี้ใครจะเห็น (ตามหน้าที่เปิดอยู่)
  Widget buildChip({
    required IconData icon,
    required String label,
    Color? color,
    IconData? trailingIcon,
  }) {
    color ??= AppColors.primary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (trailingIcon != null) ...[
            const SizedBox(width: 2),
            Icon(trailingIcon, size: 16, color: color),
          ],
        ],
      ),
    );
  }

  // =====================================================
  // หัวข้อรายการโพสต์
  // =====================================================

  Widget buildSectionHeader() {
    if (scope == FeedScope.community) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // สำหรับคุณ / ล่าสุด / วิดีโอ อยู่ที่แถบด้านบนของหน้าหลัก
          // ผู้ใช้ที่บล็อก: ตั้งค่า → ความเป็นส่วนตัว
          if (!categoryFromParent) buildCategoryFilter(),
          if (forYou && suggestions.isNotEmpty) ...[
            if (!categoryFromParent) const SizedBox(height: 16),
            buildSuggestions(),
          ],
        ],
      );
    }

    return Row(
      children: [
        Text(
          'ล่าสุดในกลุ่ม',
          style: TextStyle(
            color: AppColors.navy,
            fontSize: 19,
            fontWeight: FontWeight.w800,
          ),
        ),
        const Spacer(),
        // แชทกลุ่ม (ห้องเดียวของกลุ่ม)
        IconButton(
          tooltip: 'แชทกลุ่ม',
          onPressed: () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => const GroupChatPage())),
          icon: Icon(Icons.forum_outlined, color: AppColors.primary),
        ),
        // ค้นหาเฉพาะโพสต์ในกลุ่ม (แยกจากค้นหาชุมชน)
        IconButton(
          tooltip: 'ค้นหาในกลุ่ม',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const SearchPage(area: SearchArea.family),
            ),
          ),
          icon: Icon(Icons.search_rounded, color: AppColors.primary),
        ),
        if (!feed.isLoading && feed.posts.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.09),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '${feed.posts.length} โพสต์',
              style: TextStyle(
                color: AppColors.primary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
      ],
    );
  }

  Widget buildSuggestions() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'คนที่อาจชอบเรื่องเดียวกับคุณ',
          style: TextStyle(
            color: AppColors.navy,
            fontSize: 14.5,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 186,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            itemCount: suggestions.length,
            separatorBuilder: (context, index) => const SizedBox(width: 10),
            itemBuilder: (context, index) =>
                buildSuggestionCard(suggestions[index]),
          ),
        ),
      ],
    );
  }

  Widget buildSuggestionCard(Map<String, dynamic> user) {
    final int? id = user['id'] is num ? (user['id'] as num).toInt() : null;

    final String name = user['name']?.toString() ?? 'สมาชิก';

    final bool following = id != null && followedIds.contains(id);

    final bool busy = id != null && followBusy.contains(id);

    return Container(
      width: 148,
      padding: const EdgeInsets.fromLTRB(10, 14, 10, 10),
      decoration: AppDecorations.card(radius: 18),
      child: Column(
        children: [
          buildProfileLink(
            userId: id,
            name: name,
            child: buildAvatar(
              name: name,
              imageUrl: getProfileImage(user),
              radius: 25,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.navy,
              fontSize: 13.5,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            user['reason']?.toString() ?? '',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.muted, fontSize: 11, height: 1.3),
          ),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            height: 34,
            child: following
                ? OutlinedButton(
                    onPressed: busy ? null : () => toggleFollow(user),
                    style: OutlinedButton.styleFrom(
                      padding: EdgeInsets.zero,
                      textStyle: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    child: const Text('ติดตามแล้ว'),
                  )
                : FilledButton(
                    onPressed: busy ? null : () => toggleFollow(user),
                    style: FilledButton.styleFrom(
                      padding: EdgeInsets.zero,
                      textStyle: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    child: const Text('ติดตาม'),
                  ),
          ),
        ],
      ),
    );
  }

  // โพสต์ที่แชร์ต่อมา: แสดงโพสต์ต้นฉบับย่อ แตะเพื่อเปิดดูเต็ม
  Widget buildSharedPost(Map<String, dynamic> post) {
    final dynamic raw = post['shared_post'];

    if (raw is! Map) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.fill,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Icon(Icons.link_off_rounded, color: AppColors.muted, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'โพสต์ต้นฉบับถูกลบ หรือไม่สามารถแสดงได้',
                style: TextStyle(color: AppColors.muted, fontSize: 13),
              ),
            ),
          ],
        ),
      );
    }

    final Map<String, dynamic> original = Map<String, dynamic>.from(raw);

    final int? originalId = postIdOf(original);

    final dynamic user = original['user'];

    final String name = user is Map
        ? (user['name']?.toString() ?? 'สมาชิก')
        : 'สมาชิก';

    final String content = original['content']?.toString().trim() ?? '';

    final List<String> images = imageUrlsOf(original);

    final PostCategory? category = original['category'] == null
        ? null
        : findPostCategory(original['category'].toString());

    return Material(
      color: AppColors.fill,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: originalId == null
            ? null
            : () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => PostDetailPage(postId: originalId),
                ),
              ),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  buildAvatar(
                    name: name,
                    imageUrl: getProfileImage(user),
                    radius: 14,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.navy,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  if (category != null) CategoryBadge(category: category),
                ],
              ),
              if (content.isNotEmpty) ...[
                const SizedBox(height: 8),
                HashtagText(
                  content,
                  onTagTap: openHashtag,
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.navy,
                    fontSize: 14.5,
                    height: 1.5,
                  ),
                ),
              ],
              if (original['video'] is Map) ...[
                const SizedBox(height: 10),
                buildVideo(Map<String, dynamic>.from(original['video'] as Map)),
              ],
              if (images.isNotEmpty) ...[
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(
                    images.first,
                    height: 170,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) =>
                        const SizedBox.shrink(),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget buildShareButton(Map<String, dynamic> post, int postId) {
    final bool busy = sharingPostIds.contains(postId);

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: busy ? null : () => openShareSheet(post),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.share_outlined, color: AppColors.navy, size: 21),
              const SizedBox(width: 7),
              Text(
                'แชร์',
                style: TextStyle(
                  color: AppColors.navy,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // =====================================================
  // Post Card
  // =====================================================

  // หน้าค้นหา: แตะการ์ด → เปิดโพสต์ (ตรวจสิทธิ์ใหม่ตอนเปิด) / ฟีดอื่นไม่เปลี่ยน
  Widget openPostOnTap(int? postId, Widget card) {
    if (!isListFeed || postId == null) return card;

    return GestureDetector(
      key: ValueKey('search-post-$postId'),
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => PostDetailPage(postId: postId))),
      child: card,
    );
  }

  Widget buildPostCard(Map<String, dynamic> post) {
    final dynamic user = post['user'];

    final String name = user is Map
        ? (user['name']?.toString() ?? 'สมาชิก')
        : 'สมาชิก';

    final List<dynamic> comments = (post['comments'] as List?) ?? [];

    final int? postId = postIdOf(post);

    final bool mine = isMine(post);

    final bool community = isCommunityPost(post);

    final bool deleting = postId != null && deletingPostIds.contains(postId);

    final PostCategory? category = community
        ? findPostCategory(post['category'] ?? 'general')
        : null;

    final String content = post['content']?.toString().trim() ?? '';

    final List<String> imageUrls = imageUrlsOf(post);

    return openPostOnTap(
      postId,
      AnimatedOpacity(
        key: ValueKey('post-$postId'),
        duration: const Duration(milliseconds: 200),
        opacity: deleting ? 0.45 : 1,
        child: IgnorePointer(
          ignoring: deleting,
          child: Container(
            margin: const EdgeInsets.only(bottom: 14),
            decoration: cardDecoration(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ===========================================
                // Header
                // ===========================================

                if (post['is_hidden'] == true) buildHiddenNotice(),

                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 4, 0),
                  child: Row(
                    children: [
                      buildProfileLink(
                        userId: authorIdOf(post),
                        name: name,
                        child: buildAvatar(
                          name: name,
                          imageUrl: getProfileImage(user),
                          radius: 21,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: buildProfileLink(
                                    userId: authorIdOf(post),
                                    name: name,
                                    child: Text(
                                      name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: AppColors.navy,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                ),
                                if (mine) ...[
                                  const SizedBox(width: 6),
                                  buildYouBadge(),
                                ],
                              ],
                            ),
                            const SizedBox(height: 3),
                            Row(
                              children: [
                                // "หมวด • วันที่" (โพสต์ครอบครัว: "กลุ่ม • วันที่")
                                Flexible(
                                  child: Text(
                                    // ข้อความเคยเปลี่ยนจริง → "· แก้ไขแล้ว"
                                    '${category?.label ?? (community ? 'ชุมชน' : 'กลุ่ม')} • '
                                    '${postDate(post['created_at'])}'
                                    '${post['edited_at'] != null ? ' · แก้ไขแล้ว' : ''}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: AppColors.muted,
                                      fontSize: 11.5,
                                    ),
                                  ),
                                ),
                                if (!community && post['on_map'] == true) ...[
                                  const SizedBox(width: 6),
                                  buildOnMapBadge(),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                      if (deleting)
                        const Padding(
                          padding: EdgeInsets.all(15),
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      // ทุกโพสต์ที่เห็นได้มีเมนู (บันทึกโพสต์) / รายงาน-บล็อกเฉพาะชุมชน
                      else if (postId != null)
                        buildPostMenu(post, postId, mine)
                      else
                        const SizedBox(width: 12, height: 48),
                    ],
                  ),
                ),

                // ===========================================
                // Content (โพสต์ที่มีแต่รูปไม่แสดงช่องข้อความ)
                // ===========================================
                if (content.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      10,
                      16,
                      imageUrls.isEmpty ? 14 : 10,
                    ),
                    child: HashtagText(
                      content,
                      onTagTap: openHashtag,
                      style: TextStyle(
                        color: AppColors.navy,
                        fontSize: 15.5,
                        height: 1.55,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),

                // ===========================================
                // โพสต์ที่แชร์ต่อมา (โพสต์ต้นฉบับย่อ)
                // ===========================================
                if (post['shared_post_id'] != null)
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      content.isEmpty ? 10 : 0,
                      16,
                      14,
                    ),
                    child: buildSharedPost(post),
                  ),

                // ===========================================
                // Images
                // ===========================================
                if (imageUrls.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      content.isEmpty ? 10 : 0,
                      16,
                      14,
                    ),
                    child: buildImageGrid(imageUrls),
                  ),

                // ===========================================
                // Video
                // ===========================================
                if (post['video'] is Map)
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      content.isEmpty ? 10 : 0,
                      16,
                      14,
                    ),
                    child: buildVideo(
                      Map<String, dynamic>.from(post['video'] as Map),
                    ),
                  ),

                // ===========================================
                // Action Bar
                // ===========================================
                // Wrap: ตัวอักษรใหญ่/จอเล็ก → ปุ่มขึ้นบรรทัดใหม่แทนล้นจอ
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    spacing: 10,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (postId != null) buildLikeButton(post, postId),

                      // ปุ่มความคิดเห็น: ยังไม่มี = ชวนเขียน / มีแล้ว = จำนวน
                      if (postId != null)
                        buildCommentButton(postId, comments.length),

                      // แชร์ได้เฉพาะโพสต์ชุมชน (หรือโพสต์ที่แชร์ต่อมาจากชุมชน)
                      if (postId != null &&
                          (community || post['shared_post'] is Map))
                        buildShareButton(post, postId),
                    ],
                  ),
                ),

                // ===========================================
                // Comments
                // ===========================================
                if (comments.isNotEmpty)
                  buildCommentsSection(
                    postId: postId,
                    comments: comments,
                    community: community,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // =====================================================
  // ตารางรูปในโพสต์
  // 1 รูป: เต็มกว้าง / 2 รูป: คู่ / 3 รูป: ใหญ่ 1 + เล็ก 2
  // 4 รูปขึ้นไป: ตาราง 2×2 ช่องสุดท้ายแสดง +N
  // =====================================================

  Widget buildImageGrid(List<String> urls) {
    const double gap = 4;

    Widget tile(int index, {int extra = 0}) {
      return buildImageTile(urls, index, extra: extra);
    }

    Widget pair(Widget first, Widget second, {bool vertical = false}) {
      final children = [
        Expanded(child: first),
        vertical ? const SizedBox(height: gap) : const SizedBox(width: gap),
        Expanded(child: second),
      ];

      return vertical ? Column(children: children) : Row(children: children);
    }

    final Widget grid = switch (urls.length) {
      1 => AspectRatio(aspectRatio: 4 / 3, child: tile(0)),
      2 => AspectRatio(aspectRatio: 2, child: pair(tile(0), tile(1))),
      3 => AspectRatio(
        aspectRatio: 4 / 3,
        child: Row(
          children: [
            Expanded(flex: 2, child: tile(0)),
            const SizedBox(width: gap),
            Expanded(child: pair(tile(1), tile(2), vertical: true)),
          ],
        ),
      ),
      _ => AspectRatio(
        aspectRatio: 1,
        child: pair(
          pair(tile(0), tile(1)),
          pair(tile(2), tile(3, extra: urls.length - 4)),
          vertical: true,
        ),
      ),
    };

    return ClipRRect(borderRadius: BorderRadius.circular(16), child: grid);
  }

  Widget buildImageTile(List<String> urls, int index, {int extra = 0}) {
    final Color placeholder = AppColors.fill;

    return Semantics(
      button: true,
      label: 'ดูรูปที่ ${index + 1} จาก ${urls.length}',
      child: GestureDetector(
        onTap: () {
          dismissKeyboard();

          showPhotoViewer(context, urls: urls, initialIndex: index);
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.network(
              urls[index],
              fit: BoxFit.cover,
              cacheWidth: 900,
              loadingBuilder: (context, child, progress) {
                return progress == null
                    ? child
                    : ColoredBox(color: placeholder);
              },
              errorBuilder: (context, error, stackTrace) {
                return ColoredBox(
                  color: placeholder,
                  child: Icon(
                    Icons.broken_image_outlined,
                    color: AppColors.muted,
                  ),
                );
              },
            ),
            if (extra > 0)
              ColoredBox(
                color: Colors.black.withValues(alpha: 0.45),
                child: Center(
                  child: Text(
                    '+$extra',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ปุ่ม ❤️ + จำนวนถูกใจ
  Widget buildLikeButton(Map<String, dynamic> post, int postId) {
    final bool liked = isLikedByMe(post);

    final int count = likesCountOf(post);

    final Color color = liked ? likeColor : AppColors.navy;

    return Semantics(
      button: true,
      toggled: liked,
      label: liked ? 'ยกเลิกถูกใจ' : 'ถูกใจ',
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: () {
            toggleLike(post, postId);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // หัวใจเด้งเล็กน้อยตอนกด
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  transitionBuilder: (child, animation) {
                    return ScaleTransition(scale: animation, child: child);
                  },
                  child: Icon(
                    liked
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    key: ValueKey(liked),
                    color: color,
                    size: 21,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  count > 0 ? '$count' : 'ถูกใจ',
                  style: TextStyle(
                    color: color,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget buildYouBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.sky.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: const Text(
        'คุณ',
        style: TextStyle(
          color: Color(0xFF0B7FA6),
          fontSize: 10.5,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  // เมนู ⋯
  // - โพสต์ของเรา: ลบโพสต์ (+ โพสต์ครอบครัวที่มีข้อความ: แสดง/เอาออกจากแผนที่)
  // - โพสต์ชุมชนของคนอื่น: รายงาน / บล็อก
  Widget buildPostMenu(Map<String, dynamic> post, int postId, bool mine) {
    final int? authorId = authorIdOf(post);

    final bool canMap =
        mine &&
        !isCommunityPost(post) &&
        (post['content']?.toString().trim().isNotEmpty ?? false);

    final bool onMap = post['on_map'] == true;

    final dynamic user = post['user'];

    final String authorName = user is Map
        ? (user['name']?.toString() ?? 'สมาชิก')
        : 'สมาชิก';

    return PopupMenuButton<String>(
      tooltip: 'ตัวเลือกโพสต์',
      position: PopupMenuPosition.under,
      icon: Icon(Icons.more_horiz_rounded, color: AppColors.muted),
      onSelected: (value) {
        switch (value) {
          case 'map':
            toggleMapStatus(post, postId);
          case 'edit':
            editPost(post);
          case 'save':
            toggleSave(post, postId);
          case 'delete':
            confirmDeletePost(postId);
          case 'report':
            reportPost(postId);
          case 'block':
            if (authorId != null) {
              blockAuthor(authorId, authorName);
            }
        }
      },
      itemBuilder: (context) {
        final bool saved = post['saved_by_me'] == true;

        return [
          buildMenuItem(
            value: 'save',
            icon: saved
                ? Icons.bookmark_remove_outlined
                : Icons.bookmark_add_outlined,
            label: saved ? 'ยกเลิกบันทึก' : 'บันทึกโพสต์',
            color: AppColors.navy,
          ),
          if (canMap)
            buildMenuItem(
              value: 'map',
              icon: onMap
                  ? Icons.location_off_outlined
                  : Icons.add_location_alt_outlined,
              label: onMap ? 'เอาออกจากแผนที่' : 'แสดงบนแผนที่',
              color: AppColors.navy,
            ),
          // โพสต์ที่ถูกซ่อน (รายงาน/ทีมงาน) แก้ไม่ได้ — เซิร์ฟเวอร์ตรวจซ้ำ
          if (mine && post['is_hidden'] != true)
            buildMenuItem(
              value: 'edit',
              icon: Icons.edit_outlined,
              label: 'แก้ไขโพสต์',
              color: AppColors.navy,
            ),
          if (mine)
            buildMenuItem(
              value: 'delete',
              icon: Icons.delete_outline_rounded,
              label: 'ลบโพสต์',
              color: AppColors.danger,
            ),
          if (!mine && isCommunityPost(post))
            buildMenuItem(
              value: 'report',
              icon: Icons.flag_outlined,
              label: 'รายงานโพสต์',
              color: AppColors.navy,
            ),
          if (!mine && authorId != null && isCommunityPost(post))
            buildMenuItem(
              value: 'block',
              icon: Icons.block_rounded,
              label: 'บล็อก $authorName',
              color: AppColors.danger,
            ),
        ];
      },
    );
  }

  PopupMenuItem<String> buildMenuItem({
    required String value,
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  // =====================================================
  // Comments Section
  // แสดงล่าสุด 2 รายการ กด "ดูก่อนหน้า" เพื่อดูทั้งหมด
  // =====================================================

  Widget buildCommentButton(int postId, int count) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () => openComments(postId),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.chat_bubble_outline_rounded,
                color: AppColors.navy,
                size: 21,
              ),
              const SizedBox(width: 7),
              // ตัวอักษรใหญ่มาก → ตัดท้ายแทนล้นปุ่ม
              Flexible(
                child: Text(
                  count > 0 ? '$count' : 'ความคิดเห็น',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.navy,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ช่อง "เขียนความคิดเห็น..." ใต้ความคิดเห็น (กดแล้วเปิดหน้าต่างเขียน)
  Widget buildCommentPrompt(int postId) {
    final dynamic me = currentUser;

    final String myName = me is Map ? (me['name']?.toString() ?? 'คุณ') : 'คุณ';

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          buildAvatar(name: myName, imageUrl: getProfileImage(me), radius: 15),
          const SizedBox(width: 9),
          Expanded(
            child: Material(
              color: AppColors.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(999),
                side: BorderSide(color: AppColors.border),
              ),
              child: InkWell(
                customBorder: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(999),
                ),
                onTap: () => openComments(postId),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Text(
                    'เขียนความคิดเห็น...',
                    style: TextStyle(color: AppColors.muted, fontSize: 13.5),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget buildCommentsSection({
    required int? postId,
    required List<dynamic> comments,
    required bool community,
  }) {
    final bool expanded = postId != null && expandedPostIds.contains(postId);

    final List<dynamic> visibleComments =
        expanded || comments.length <= collapsedCommentCount
        ? comments
        : comments.sublist(comments.length - collapsedCommentCount);

    final int hiddenCount = comments.length - visibleComments.length;

    final bool canCollapse =
        expanded && comments.length > collapsedCommentCount;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (postId != null && (hiddenCount > 0 || canCollapse))
            TextButton(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                minimumSize: const Size(0, 36),
                foregroundColor: AppColors.muted,
                textStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              onPressed: () {
                setState(() {
                  if (expanded) {
                    expandedPostIds.remove(postId);
                  } else {
                    expandedPostIds.add(postId);
                  }
                });
              },
              child: Text(
                hiddenCount > 0
                    ? 'ดูความคิดเห็นก่อนหน้า ($hiddenCount)'
                    : 'ซ่อนความคิดเห็นเก่า',
              ),
            ),
          ...visibleComments.map(
            (comment) => buildComment(comment, community: community),
          ),
          if (postId != null) buildCommentPrompt(postId),
        ],
      ),
    );
  }

  // ความคิดเห็นแบบฟองข้อความ: ชื่อ + ข้อความในฟอง / เวลาใต้ฟอง
  Widget buildComment(dynamic comment, {required bool community}) {
    final dynamic commentUser = comment is Map ? comment['user'] : null;

    final String commentName = commentUser is Map
        ? (commentUser['name']?.toString() ?? 'สมาชิก')
        : 'สมาชิก';

    final dynamic createdAt = comment is Map ? comment['created_at'] : null;

    final String content = comment is Map
        ? (comment['content']?.toString() ?? '')
        : '';

    final dynamic rawId = comment is Map ? comment['id'] : null;

    final int? commentId = rawId is num ? rawId.toInt() : null;

    final dynamic rawAuthorId = comment is Map ? comment['user_id'] : null;

    final int? authorId = rawAuthorId is num ? rawAuthorId.toInt() : null;

    final dynamic myId = currentUser?['id'];

    final bool mine =
        myId != null && authorId != null && myId.toString() == '$authorId';

    // ความคิดเห็นของคนอื่นในโพสต์ชุมชน → รายงาน / บล็อกได้
    final bool canAct = community && commentId != null && !mine;

    void openActions() {
      if (commentId == null) return;

      openCommentActions(
        commentId: commentId,
        authorId: authorId,
        authorName: commentName,
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: canAct ? openActions : null,
      child: Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            buildProfileLink(
              userId: authorId,
              name: commentName,
              child: buildAvatar(
                name: commentName,
                imageUrl: getProfileImage(commentUser),
                radius: 16,
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ฟองข้อความสีเทาอ่อน (กว้างตามข้อความ)
                  Container(
                    padding: const EdgeInsets.fromLTRB(13, 8, 13, 9),
                    decoration: BoxDecoration(
                      color: AppColors.fill,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        buildProfileLink(
                          userId: authorId,
                          name: commentName,
                          child: Text(
                            commentName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.navy,
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        if (content.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          HashtagText(
                            content,
                            onTagTap: openHashtag,
                            style: TextStyle(
                              color: AppColors.navy,
                              fontSize: 14.5,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  // รูป / GIF / วิดีโอที่แนบ (ย่อ แตะเพื่อดูเต็มจอ)
                  if (comment is Map && comment['media'] is Map)
                    Padding(
                      padding: const EdgeInsets.only(top: 6, left: 4),
                      child: CommentMediaThumb(
                        media: Map<String, dynamic>.from(
                          comment['media'] as Map,
                        ),
                      ),
                    ),
                  // เวลา + ⋯ ใต้ฟอง
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 3, 0, 0),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (createdAt != null)
                          Text(
                            formatDate(createdAt),
                            style: TextStyle(
                              color: AppColors.muted,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        if (canAct) ...[
                          const SizedBox(width: 10),
                          InkWell(
                            borderRadius: BorderRadius.circular(999),
                            onTap: openActions,
                            child: Padding(
                              padding: EdgeInsets.symmetric(horizontal: 4),
                              child: Icon(
                                Icons.more_horiz_rounded,
                                size: 18,
                                color: AppColors.muted,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // =====================================================
  // Empty / Error State
  // =====================================================

  Widget buildEmptyState() {
    // โหมดโพสต์เดียว: โพสต์ถูกลบ/รายงานไปแล้วระหว่างเปิดดู
    if (isSinglePost) {
      return buildStateCard(
        icon: Icons.inbox_outlined,
        color: AppColors.muted,
        title: 'ไม่มีโพสต์นี้แล้ว',
        message: 'โพสต์อาจถูกลบหรือซ่อนไปแล้ว',
      );
    }

    if (isAuthorFeed) {
      return buildStateCard(
        icon: Icons.article_outlined,
        color: AppColors.primary,
        title: 'ยังไม่มีโพสต์',
        message: 'โพสต์ของผู้ใช้นี้ที่คุณเห็นได้จะแสดงที่นี่',
      );
    }

    if (scope == FeedScope.mine) {
      return switch (widget.mineVisibility) {
        'community' => buildStateCard(
          icon: Icons.public_rounded,
          color: communityColor,
          title: 'ยังไม่มีโพสต์ในชุมชน',
          message: 'โพสต์ที่คุณแชร์ให้ทุกคนในชุมชนเห็นจะแสดงที่นี่',
        ),
        'family' => buildStateCard(
          icon: Icons.groups_rounded,
          color: AppColors.primary,
          title: 'ยังไม่มีโพสต์ในกลุ่ม',
          message: 'โพสต์ที่คุณแชร์ในกลุ่มจะแสดงที่นี่ เห็นเฉพาะสมาชิกในกลุ่ม',
        ),
        _ => buildStateCard(
          icon: Icons.edit_note_rounded,
          color: AppColors.primary,
          title: 'ยังไม่มีโพสต์',
          message: 'โพสต์ที่คุณแชร์ทั้งในกลุ่มและชุมชนจะแสดงที่นี่',
        ),
      };
    }

    if (isSavedFeed) {
      return buildStateCard(
        icon: Icons.bookmark_border_rounded,
        color: AppColors.primary,
        title: 'ยังไม่มีโพสต์ที่บันทึก',
        message: 'กด ⋯ บนโพสต์ แล้วเลือก "บันทึกโพสต์" เพื่อเก็บไว้อ่านทีหลัง',
      );
    }

    if (isSearchFeed) {
      final bool inGroup = widget.searchScope == 'family';

      return buildStateCard(
        icon: Icons.search_off_rounded,
        color: inGroup ? AppColors.primary : communityColor,
        title: 'ไม่พบโพสต์สำหรับคำว่า “${widget.searchQuery}”',
        message: inGroup
            ? 'ลองใช้คำอื่น หรือคำที่สั้นลง (ค้นเฉพาะโพสต์ในกลุ่มของคุณ)'
            : 'ลองใช้คำอื่น หรือคำที่สั้นลง',
      );
    }

    final PostCategory? filter = findPostCategory(filterCategory);

    if (isHashtagFeed) {
      return buildStateCard(
        icon: Icons.tag_rounded,
        color: communityColor,
        title: 'ยังไม่มีโพสต์ #${widget.hashtag}',
        message: 'โพสต์ในชุมชนที่ใส่ #${widget.hashtag} จะแสดงที่นี่',
      );
    }

    if (videosOnly) {
      return buildStateCard(
        icon: Icons.smart_display_rounded,
        color: communityColor,
        title: filter == null
            ? 'ยังไม่มีวิดีโอในชุมชน'
            : 'ยังไม่มีวิดีโอหมวด "${filter.label}"',
        message: 'กด + แล้วเลือกวิดีโอ เพื่อเป็นคนแรกที่แชร์วิดีโอ',
      );
    }

    if (scope == FeedScope.community && filter != null) {
      return buildStateCard(
        icon: filter.icon,
        color: filter.color,
        title: 'ยังไม่มีโพสต์หมวด "${filter.label}"',
        message: 'ลองดูหมวดอื่น หรือเป็นคนแรกที่แชร์ในหมวดนี้',
      );
    }

    if (scope == FeedScope.community) {
      return buildStateCard(
        icon: Icons.public_rounded,
        color: communityColor,
        title: 'ชุมชนยังเงียบอยู่',
        message: 'เป็นคนแรกที่แชร์เรื่องราวให้ทุกคนเห็น',
      );
    }

    return buildStateCard(
      icon: Icons.forum_outlined,
      color: AppColors.primary,
      title: 'กลุ่มยังเงียบอยู่',
      message: 'เริ่มต้นแชร์เรื่องราวแรกของกลุ่มกันเลย',
    );
  }

  Widget buildErrorState() {
    return buildStateCard(
      icon: Icons.cloud_off_rounded,
      color: AppColors.danger,
      title: isSearchFeed ? 'ค้นหาไม่สำเร็จ' : 'โหลดโพสต์ไม่สำเร็จ',
      message: feed.loadError ?? 'กรุณาลองใหม่อีกครั้ง',
      action: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(minimumSize: const Size(170, 46)),
        onPressed: retryLoad,
        icon: const Icon(Icons.refresh_rounded, size: 18),
        label: const Text('ลองอีกครั้ง'),
      ),
    );
  }

  Widget buildStateCard({
    required IconData icon,
    required Color color,
    required String title,
    required String message,
    Widget? action,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      decoration: cardDecoration(),
      child: Column(
        children: [
          Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.09),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 34, color: color),
          ),
          const SizedBox(height: 18),
          Text(
            title,
            style: TextStyle(
              color: AppColors.navy,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.muted,
              fontSize: 13.5,
              height: 1.5,
            ),
          ),
          if (action != null) ...[const SizedBox(height: 18), action],
        ],
      ),
    );
  }

  // =====================================================
  // UI
  // =====================================================

  List<Widget> buildFeedItems() {
    if (feed.isLoading) {
      return const [_PostSkeleton(), _PostSkeleton()];
    }

    if (feed.loadError != null && feed.posts.isEmpty) {
      return [buildErrorState()];
    }

    if (feed.posts.isEmpty) {
      return [buildEmptyState()];
    }

    return [...feed.posts.map(buildPostCard), if (isPaged) buildFeedFooter()];
  }

  // ท้ายฟีดชุมชน: กำลังโหลดเพิ่ม / ไม่มีโพสต์เพิ่มแล้ว
  Widget buildFeedFooter() {
    if (feed.isLoadingMore) {
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

    if (feed.loadMoreFailed) {
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
              onPressed: () => loadPosts(loadMore: true, retry: true),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('ลองอีกครั้ง'),
            ),
          ],
        ),
      );
    }

    if (feed.hasMore) {
      return const SizedBox(height: 40);
    }

    return Padding(
      padding: EdgeInsets.symmetric(vertical: 14),
      child: Center(
        child: Text(
          isSearchFeed ? 'ไม่มีผลค้นหาเพิ่มแล้ว' : 'ไม่มีโพสต์เพิ่มแล้ว',
          style: TextStyle(color: AppColors.muted, fontSize: 12),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        RefreshIndicator(
          color: AppColors.primary,
          onRefresh: refreshFeed,
          child: ListView(
            controller: scrollController,
            physics: const AlwaysScrollableScrollPhysics(),

            // เว้นด้านล่างไว้ไม่ให้ปุ่ม + บังโพสต์สุดท้าย
            padding: EdgeInsets.fromLTRB(16, 12, 16, isMainFeed ? 96 : 32),
            children: [
              // ฟีดหลักมีหัวข้อ + ตัวกรอง / หน้าโปรไฟล์ใช้ header ของตัวเอง
              if (widget.header != null) ...[
                widget.header!,
                const SizedBox(height: 14),
              ] else if (isMainFeed) ...[
                buildSectionHeader(),
                const SizedBox(height: 12),
              ],
              ...buildFeedItems(),
            ],
          ),
        ),
        if (isMainFeed)
          Positioned(right: 16, bottom: 16, child: buildComposeButton()),
      ],
    );
  }

  @override
  void dispose() {
    postChanges?.cancel();

    composerVersion.dispose();

    postController.dispose();

    hashtagController.dispose();

    hashtagFocus.dispose();

    scrollController.dispose();

    super.dispose();
  }
}

// =======================================================
// Skeleton ระหว่างโหลดโพสต์
// =======================================================

class _PostSkeleton extends StatefulWidget {
  const _PostSkeleton();

  @override
  State<_PostSkeleton> createState() => _PostSkeletonState();
}

class _PostSkeletonState extends State<_PostSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  late final Animation<double> opacity = Tween<double>(
    begin: 0.45,
    end: 1,
  ).animate(controller);

  Widget bar(double width, double height) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: AppColors.fill,
        borderRadius: BorderRadius.circular(8),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: opacity,
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(24),
          border: AppDecorations.cardBorder,
          boxShadow: AppDecorations.cardShadow,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: AppColors.fill,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    bar(110, 12),
                    const SizedBox(height: 7),
                    bar(70, 10),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 18),
            bar(double.infinity, 12),
            const SizedBox(height: 9),
            bar(double.infinity, 12),
            const SizedBox(height: 9),
            bar(170, 12),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    controller.dispose();

    super.dispose();
  }
}
