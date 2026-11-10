<?php

namespace App\Http\Controllers;

use App\Http\Controllers\Concerns\PresentsPosts;
use App\Models\AppNotification;
use App\Models\FamilyMember;
use App\Models\Hashtag;
use App\Models\Interaction;
use App\Models\Post;
use App\Models\PostLike;
use App\Models\PostReport;
use App\Models\PostVideo;
use App\Models\User;
use App\Services\FeedRanker;
use App\Support\MediaStorage;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Str;
use Illuminate\Validation\Rule;
use RuntimeException;
use Throwable;

class PostController extends Controller
{
    use PresentsPosts;

    // จำนวนโพสต์ชุมชนต่อหน้า
    private const COMMUNITY_PAGE_SIZE = 20;

    // รูปในโพสต์: จำนวนสูงสุด และขนาดสูงสุดต่อรูป (KB)
    private const MAX_IMAGES = 10;
    private const MAX_IMAGE_KB = 4096;

    // =====================================================
    // ดู Post
    //
    // ?scope=family    (ค่าเริ่มต้น) โพสต์ในครอบครัว
    // ?scope=community &page=N      โพสต์ชุมชนของทุกคน
    //                  &sort=for_you เรียงตามความสนใจของเรา (ไม่ส่ง = ล่าสุด)
    //                  &category=qa กรองตามหมวด (ไม่ส่ง = ทุกหมวด)
    //                  &user_id=5   เฉพาะโพสต์ชุมชนของผู้ใช้คนนี้ (แอปเวอร์ชันเก่า)
    // ?scope=user      &user_id=5   หน้าโปรไฟล์: โพสต์ของคนนี้ที่เราเห็นได้
    //                  &page=N      (ครอบครัวเดียวกัน + ชุมชน)
    // ?scope=mine      &page=N      โพสต์ของเราเอง (ครอบครัว + ชุมชน)
    //                  &visibility=community|family  ตัวกรองหน้าโปรไฟล์
    // =====================================================

    public function index(Request $request)
    {
        $user = $request->user();

        $membership = FamilyMember::where(
            'user_id',
            $user->id
        )->first();

        // ยังไม่มีครอบครัว: ดูฟีดชุมชน โพสต์ในหน้าโปรไฟล์ และโพสต์ชุมชนของตัวเองได้
        // (ฟีดครอบครัวต้องมีครอบครัว)
        if (!$membership && !in_array($request->query('scope'), ['community', 'user', 'mine'], true)) {
            return response()->json([
                'status' => false,
                'message' => 'คุณยังไม่ได้อยู่ในกลุ่ม',
                'posts' => [],
            ], 403);
        }

        if ($request->query('scope') === 'community') {
            $data = $request->validate([
                'category' => ['nullable', Rule::in(Post::CATEGORIES)],
                'user_id' => 'nullable|integer',
                'sort' => 'nullable|in:for_you,latest',
                // media=video → เฉพาะโพสต์ที่มีวิดีโอ (แท็บ "วิดีโอ" เรียงล่าสุดก่อน)
                'media' => 'nullable|in:video',
                // hashtag=ทำอาหาร → เฉพาะโพสต์ที่มีแท็กนี้ (มี # หรือไม่ก็ได้)
                'hashtag' => 'nullable|string|max:51',
                'page' => 'nullable|integer|min:1',
            ]);

            $videosOnly = ($data['media'] ?? null) === 'video';

            $hashtag = filled($data['hashtag'] ?? null)
                ? Hashtag::normalize($data['hashtag'])
                : null;

            if (($data['sort'] ?? 'latest') === 'for_you' && !isset($data['user_id']) && !$videosOnly && !$hashtag) {
                return $this->forYouFeed(
                    $user,
                    $data['category'] ?? null,
                    (int) ($data['page'] ?? 1)
                );
            }

            return $this->communityFeed(
                $user,
                $data['category'] ?? null,
                isset($data['user_id']) ? (int) $data['user_id'] : null,
                $videosOnly,
                $hashtag
            );
        }

        if ($request->query('scope') === 'mine') {
            $data = $request->validate([
                // community = เฉพาะชุมชน / family = เฉพาะในกลุ่ม / ไม่ส่ง = ทั้งหมด
                'visibility' => 'nullable|in:community,family',
                'page' => 'nullable|integer|min:1',
            ]);

            return $this->myPosts($user, $membership, $data['visibility'] ?? null);
        }

        if ($request->query('scope') === 'user') {
            $data = $request->validate([
                'user_id' => 'required|integer',
            ]);

            return $this->userPosts($user, $membership, (int) $data['user_id']);
        }

        $posts = Post::where(
            'family_id',
            $membership->family_id
        )
            ->where('visibility', 'family')
            ->with($this->familyRelations())
            ->tap(fn ($query) => $this->withLikeInfo($query, $user))
            ->latest()
            ->get()
            ->map(fn ($post) => $this->withOwnership($post, $user));

        return response()->json([
            'status' => true,
            'scope' => 'family',
            'current_user' => $this->currentUserPayload($user),
            'posts' => $posts,
        ]);
    }

    // =====================================================
    // ฟีดชุมชน
    // - ไม่แสดงโพสต์ที่ถูกซ่อน
    // - ไม่แสดงโพสต์ที่เรารายงานไปแล้ว
    // - ไม่แสดงโพสต์/ความคิดเห็นของคนที่เราบล็อก
    // =====================================================

    private function communityFeed(
        User $user,
        ?string $category,
        ?int $authorId = null,
        bool $videosOnly = false,
        ?string $hashtag = null
    ) {
        $blockedIds = $user->blockedUsers()->pluck('users.id');

        $paginator = Post::query()
            ->tap(fn ($query) => $this->visibleInCommunity($query, $user, $blockedIds))
            ->when($category, fn ($query) => $query->where('category', $category))
            ->when($authorId, fn ($query) => $query->where('user_id', $authorId))
            // วิดีโอของโพสต์นั้นเอง (โพสต์ที่แชร์ต่อไม่นับ จะได้ไม่ซ้ำกับต้นฉบับ)
            ->when($videosOnly, fn ($query) => $query->whereHas('video'))
            ->when($hashtag, fn ($query) => $query->whereHas(
                'hashtags',
                fn ($tags) => $tags->where('name', $hashtag)
            ))
            ->with($this->communityRelations($user, $blockedIds))
            ->tap(fn ($query) => $this->withLikeInfo($query, $user))
            ->orderByDesc('created_at')
            ->orderByDesc('id')
            ->simplePaginate(self::COMMUNITY_PAGE_SIZE);

        $posts = collect($paginator->items())
            ->map(fn ($post) => $this->withOwnership($post, $user, $blockedIds))
            ->values();

        return response()->json([
            'status' => true,
            'scope' => 'community',
            'category' => $category,
            'media' => $videosOnly ? 'video' : null,
            'hashtag' => $hashtag,
            'current_user' => $this->currentUserPayload($user),
            'posts' => $posts,
            'page' => $paginator->currentPage(),
            'has_more' => $paginator->hasMorePages(),
        ]);
    }

    // =====================================================
    // ฟีดชุมชน "สำหรับคุณ" (จัดลำดับด้วย FeedRanker)
    // หน้าแรก (เปิด/ดึงรีเฟรช) จัดลำดับใหม่ หน้าถัดไปใช้ลำดับเดิม
    // → เลื่อนดูต่อแล้วไม่เจอโพสต์ซ้ำหรือข้ามไป
    // =====================================================

    private function forYouFeed(User $user, ?string $category, int $page)
    {
        $blockedIds = $user->blockedUsers()->pluck('users.id');

        $cacheKey = 'feed:for_you:' . $user->id . ':' . ($category ?? 'all');

        $ids = $page > 1 ? Cache::get($cacheKey) : null;

        if (!is_array($ids)) {
            $ids = app(FeedRanker::class)->rankedIds($user, $blockedIds, $category)->all();

            Cache::put($cacheKey, $ids, now()->addMinutes(30));
        }

        $pageIds = array_slice($ids, ($page - 1) * self::COMMUNITY_PAGE_SIZE, self::COMMUNITY_PAGE_SIZE);

        $order = array_flip($pageIds);

        $posts = Post::whereIn('id', $pageIds)
            // ระหว่างเลื่อนดู โพสต์อาจถูกซ่อน/ถูกลบไปแล้ว
            ->tap(fn ($query) => $this->visibleInCommunity($query, $user, $blockedIds))
            ->with($this->communityRelations($user, $blockedIds))
            ->tap(fn ($query) => $this->withLikeInfo($query, $user))
            ->get()
            ->sortBy(fn (Post $post) => $order[$post->id])
            ->map(fn ($post) => $this->withOwnership($post, $user, $blockedIds))
            ->values();

        return response()->json([
            'status' => true,
            'scope' => 'community',
            'sort' => 'for_you',
            'category' => $category,
            'current_user' => $this->currentUserPayload($user),
            'posts' => $posts,
            'page' => $page,
            'has_more' => count($ids) > $page * self::COMMUNITY_PAGE_SIZE,
        ]);
    }

    // =====================================================
    // โพสต์ของเราเอง (หน้า "โพสต์ของฉัน")
    // - โพสต์ครอบครัวในครอบครัวปัจจุบัน + โพสต์ชุมชนทั้งหมด
    // - โพสต์ชุมชนที่ถูกซ่อนก็แสดง (is_hidden) ให้เจ้าของรู้
    // =====================================================

    // =====================================================
    // โพสต์ของผู้ใช้คนหนึ่ง (หน้าโปรไฟล์)
    // - คนในครอบครัวเดียวกัน: โพสต์ครอบครัว + โพสต์ชุมชน
    // - คนอื่น: เฉพาะโพสต์ชุมชนที่เราเห็นได้
    // =====================================================

    private function userPosts(User $user, ?FamilyMember $membership, int $authorId)
    {
        $blockedIds = $user->blockedUsers()->pluck('users.id');

        // โปรไฟล์ของเราเอง = "ดูโปรไฟล์ที่คนอื่นเห็น" → เฉพาะที่คนในชุมชนเห็น (ไม่รวมโพสต์ในกลุ่ม)
        $isMe = $authorId === (int) $user->id;

        $paginator = Post::where('user_id', $authorId)
            ->when(
                $isMe,
                fn ($query) => $query->visibleInCommunityTo($user, $blockedIds),
                fn ($query) => $query->visibleOnProfileTo($user, $membership?->family_id, $blockedIds)
            )
            ->with($this->communityRelations($user, $blockedIds))
            ->tap(fn ($query) => $this->withLikeInfo($query, $user))
            ->orderByDesc('created_at')
            ->orderByDesc('id')
            ->simplePaginate(self::COMMUNITY_PAGE_SIZE);

        $posts = collect($paginator->items())
            ->map(fn ($post) => $this->withOwnership($post, $user))
            ->values();

        return response()->json([
            'status' => true,
            'scope' => 'user',
            'current_user' => $this->currentUserPayload($user),
            'posts' => $posts,
            'page' => $paginator->currentPage(),
            'has_more' => $paginator->hasMorePages(),
        ]);
    }

    // visibility: community / family / null = ทั้งหมด
    // ยังไม่มีกลุ่ม → เฉพาะโพสต์ชุมชน (ตัวกรอง "ในกลุ่ม" = ว่าง)
    private function myPosts(User $user, ?FamilyMember $membership, ?string $visibility = null)
    {
        $blockedIds = $user->blockedUsers()->pluck('users.id');

        $paginator = Post::where('user_id', $user->id)
            ->where(function ($query) use ($membership, $visibility) {
                if ($visibility !== 'family') {
                    $query->where('visibility', 'community');
                }

                if ($membership && $visibility !== 'community') {
                    $query->orWhere(function ($family) use ($membership) {
                        $family->where('visibility', 'family')
                            ->where('family_id', $membership->family_id);
                    });
                }

                // ตัวกรอง "ในกลุ่ม" แต่ยังไม่มีกลุ่ม → ไม่มีโพสต์
                if (!$membership && $visibility === 'family') {
                    $query->whereRaw('1 = 0');
                }
            })
            ->with($this->communityRelations($user, $blockedIds))
            ->tap(fn ($query) => $this->withLikeInfo($query, $user))
            ->orderByDesc('created_at')
            ->orderByDesc('id')
            ->simplePaginate(self::COMMUNITY_PAGE_SIZE);

        $posts = collect($paginator->items())
            ->map(function (Post $post) use ($user) {
                $post->setAttribute('is_hidden', $post->hidden_at !== null);

                return $this->withOwnership($post, $user);
            })
            ->values();

        return response()->json([
            'status' => true,
            'scope' => 'mine',
            'visibility' => $visibility,
            'current_user' => $this->currentUserPayload($user),
            'posts' => $posts,
            'page' => $paginator->currentPage(),
            'has_more' => $paginator->hasMorePages(),
        ]);
    }

    // =====================================================
    // ดูโพสต์เดียว (เปิดจากการแจ้งเตือน)
    // GET /api/posts/{post}
    // - โพสต์ครอบครัว: ต้องอยู่ครอบครัวเดียวกัน
    // - โพสต์ชุมชน: ใช้กฎเดียวกับฟีดชุมชน
    // เห็นไม่ได้ → 404 (ไม่บอกว่ามีโพสต์นี้อยู่)
    // =====================================================

    public function show(Request $request, Post $post)
    {
        $user = $request->user();

        $membership = FamilyMember::where(
            'user_id',
            $user->id
        )->first();

        // ยังไม่มีครอบครัว: เปิดดูได้เฉพาะโพสต์ชุมชน
        if (!$membership && !$post->isCommunity()) {
            return response()->json([
                'status' => false,
                'message' => 'คุณยังไม่ได้อยู่ในกลุ่ม',
            ], 403);
        }

        $query = Post::query()->whereKey($post->id);

        if ($post->isCommunity()) {
            $blockedIds = $user->blockedUsers()->pluck('users.id');

            $query->tap(fn ($posts) => $this->visibleInCommunity($posts, $user, $blockedIds))
                ->with($this->communityRelations($user, $blockedIds));
        } else {
            $query->where('visibility', 'family')
                ->where('family_id', $membership->family_id)
                ->with($this->familyRelations());
        }

        $found = $query
            ->tap(fn ($posts) => $this->withLikeInfo($posts, $user))
            ->first();

        if (!$found) {
            return response()->json([
                'status' => false,
                'message' => 'ไม่พบโพสต์นี้ หรือโพสต์ถูกลบไปแล้ว',
            ], 404);
        }

        return response()->json([
            'status' => true,
            'current_user' => $this->currentUserPayload($user),
            'post' => $this->withOwnership($found, $user),
        ]);
    }

    // =====================================================
    // สร้าง Post
    // visibility: family (ค่าเริ่มต้น) / community
    // category:   ใช้เฉพาะโพสต์ชุมชน (ค่าเริ่มต้น general)
    // images[]:   รูปแนบ (multipart) ไม่บังคับ
    //             มีรูปแล้วไม่ต้องมีข้อความก็ได้
    // =====================================================

    public function store(Request $request)
    {
        $data = $request->validate([
            'content' => 'required_without_all:images,video,video_path|nullable|string|max:5000',
            'visibility' => 'nullable|in:family,community',
            'category' => ['nullable', Rule::in(Post::CATEGORIES)],
            'images' => 'nullable|array|max:' . self::MAX_IMAGES,
            'images.*' => 'image|mimes:jpg,jpeg,png,webp|max:' . self::MAX_IMAGE_KB,
            // โพสต์ครอบครัว: แสดงข้อความนี้ข้างตำแหน่งของเราบนแผนที่ด้วย
            'show_on_map' => 'nullable|boolean',
            // วิดีโอ: ส่งไฟล์มาเลย (video) หรืออัปโหลดเข้า Bucket ไว้แล้ว (video_path)
            'video' => 'nullable|file|mimetypes:video/mp4,video/quicktime,video/3gpp|max:' . PostVideo::MAX_KB,
            'video_path' => 'nullable|string|max:255',
            'video_thumbnail' => 'nullable|image|mimes:jpg,jpeg,png,webp|max:2048',
            'video_duration' => 'nullable|integer|min:0|max:' . (PostVideo::MAX_SECONDS + 5),
            'video_width' => 'nullable|integer|min:0|max:10000',
            'video_height' => 'nullable|integer|min:0|max:10000',
        ], [
            'content.required_without_all' => 'กรุณาพิมพ์ข้อความ หรือแนบรูป/วิดีโอก่อนโพสต์',
            'video.mimetypes' => 'รองรับเฉพาะวิดีโอ MP4',
            'video.max' => 'วิดีโอต้องมีขนาดไม่เกิน 50 MB',
            'video_duration.max' => 'วิดีโอต้องยาวไม่เกิน ' . PostVideo::MAX_SECONDS . ' วินาที',
            'images.max' => 'แนบรูปได้สูงสุด ' . self::MAX_IMAGES . ' รูป',
            'images.*.image' => 'รองรับเฉพาะรูป JPG, PNG หรือ WEBP',
            'images.*.mimes' => 'รองรับเฉพาะรูป JPG, PNG หรือ WEBP',
            'images.*.max' => 'รูปแต่ละรูปต้องมีขนาดไม่เกิน 4 MB',
            'images.*.uploaded' => 'อัปโหลดรูปไม่สำเร็จ กรุณาลองอีกครั้ง',
        ]);

        $content = trim($data['content'] ?? '');

        $visibility = $data['visibility'] ?? 'family';

        // โพสต์ครอบครัวไม่เก็บหมวด
        $category = $visibility === 'community'
            ? ($data['category'] ?? 'general')
            : null;

        $user = $request->user();

        $membership = FamilyMember::where(
            'user_id',
            $user->id
        )->first();

        if (!$membership) {
            return response()->json([
                'status' => false,
                'code' => 'family_required',
                'message' => 'สร้างหรือเข้าร่วมกลุ่มก่อน จึงจะโพสต์ได้',
            ], 403);
        }

        // โพสต์ชุมชนต้องยอมรับกฎชุมชนก่อน
        if (
            $visibility === 'community'
            && $user->community_terms_accepted_at === null
        ) {
            return response()->json([
                'status' => false,
                'code' => 'terms_required',
                'message' => 'กรุณายอมรับกฎชุมชนก่อนโพสต์',
            ], 403);
        }

        $hasVideo = $request->hasFile('video') || filled($data['video_path'] ?? null);

        if ($hasVideo && $request->hasFile('images')) {
            return response()->json([
                'status' => false,
                'message' => 'แนบได้ทั้งรูปหรือวิดีโออย่างใดอย่างหนึ่ง',
            ], 422);
        }

        // วิดีโอที่อัปโหลดเข้า Bucket ไว้แล้ว: ต้องเป็นของเราและมีไฟล์จริง
        if (filled($data['video_path'] ?? null) && !$this->validUploadedVideo($user, $data['video_path'])) {
            return response()->json([
                'status' => false,
                'message' => 'ไม่พบวิดีโอที่อัปโหลด หรือวิดีโอใหญ่เกิน 50 MB กรุณาลองใหม่',
            ], 422);
        }

        // เก็บไฟล์รูปก่อน ถ้าล้มกลางทางให้ลบไฟล์ที่เก็บไปแล้วทิ้ง
        $imagePaths = [];

        try {
            foreach ($request->file('images', []) as $image) {
                $path = $image->store(
                    'post_images',
                    MediaStorage::disk()
                );

                if (!$path) {
                    throw new RuntimeException(
                        'Could not store the uploaded image.'
                    );
                }

                $imagePaths[] = $path;
            }
        } catch (Throwable $e) {
            MediaStorage::delete($imagePaths);

            Log::error('Post image upload failed', [
                'user_id' => $user->id,
                'error' => $e->getMessage(),
            ]);

            return response()->json([
                'status' => false,
                'message' => 'อัปโหลดรูปไม่สำเร็จ กรุณาลองอีกครั้ง',
            ], 500);
        }

        // ไฟล์วิดีโอ (ส่งมากับโพสต์) + รูปตัวอย่าง
        $videoFiles = [];

        try {
            if ($hasVideo) {
                $videoFiles = $this->storeVideoFiles($request, $user, $data);
            }
        } catch (Throwable $e) {
            MediaStorage::delete($imagePaths);

            Log::error('Post video upload failed', [
                'user_id' => $user->id,
                'error' => $e->getMessage(),
            ]);

            return response()->json([
                'status' => false,
                'message' => 'อัปโหลดวิดีโอไม่สำเร็จ กรุณาลองอีกครั้ง',
            ], 500);
        }

        try {
            $post = $this->createPostRecords(
                $user,
                $membership,
                $visibility,
                $category,
                $content,
                $imagePaths
            );

            if ($videoFiles !== []) {
                $post->video()->create([
                    ...$videoFiles,
                    'duration_seconds' => $data['video_duration'] ?? null,
                    'width' => $data['video_width'] ?? null,
                    'height' => $data['video_height'] ?? null,
                ]);
            }
        } catch (Throwable $e) {
            // บันทึกลงฐานข้อมูลไม่สำเร็จ → ไม่เก็บไฟล์ค้างไว้
            MediaStorage::delete([
                ...$imagePaths,
                $videoFiles['path'] ?? null,
                $videoFiles['thumbnail_path'] ?? null,
            ]);

            throw $e;
        }

        // โพสต์ชุมชน / โพสต์ที่มีแต่รูป → ไม่แสดงบนแผนที่
        if (($data['show_on_map'] ?? false) && $post->canShowOnMap()) {
            $post->showOnMap();
        }

        $post->load($this->familyRelations());

        $post->setAttribute('is_mine', true);
        $post->setAttribute('likes_count', 0);
        $post->setAttribute('liked_by_me', false);
        $post->setAttribute('shares_count', 0);

        return response()->json([
            'status' => true,
            'message' => 'สร้างโพสต์สำเร็จ',
            'post' => $post,
        ], 201);
    }

    // =====================================================
    // ขอลิงก์อัปโหลดวิดีโอตรงเข้า Bucket
    // POST /api/posts/video-upload
    // - upload: {url, headers, path} → แอป PUT ไฟล์ไปที่ url แล้วส่ง video_path ตอนโพสต์
    // - upload: null → ที่เก็บไม่รองรับ (ในเครื่อง) แอปส่งไฟล์ video มากับโพสต์แทน
    // =====================================================

    public function videoUploadUrl(Request $request)
    {
        $user = $request->user();

        if (!FamilyMember::where('user_id', $user->id)->exists()) {
            return response()->json([
                'status' => false,
                'message' => 'คุณยังไม่ได้อยู่ในกลุ่ม',
            ], 403);
        }

        $path = 'post_videos/' . $user->id . '/' . Str::uuid() . '.mp4';

        $upload = MediaStorage::uploadUrl($path);

        return response()->json([
            'status' => true,
            'max_kb' => PostVideo::MAX_KB,
            'max_seconds' => PostVideo::MAX_SECONDS,
            'upload' => $upload === null ? null : [
                'url' => $upload['url'],
                // PUT ต้องส่ง header ตามที่ลงลายเซ็นไว้
                'headers' => collect($upload['headers'])
                    ->except(['Host', 'host'])
                    ->map(fn ($value) => is_array($value) ? implode(', ', $value) : $value)
                    ->put('Content-Type', 'video/mp4')
                    ->all(),
                'path' => $path,
            ],
        ]);
    }

    // video_path ต้องอยู่ในโฟลเดอร์ของเรา มีไฟล์จริง และไม่ใหญ่เกิน
    private function validUploadedVideo(User $user, string $path): bool
    {
        $pattern = '#^post_videos/' . $user->id . '/[A-Za-z0-9-]+' . preg_quote('.mp4', '#') . '$#';

        if (!preg_match($pattern, $path)) {
            return false;
        }

        try {
            $storage = Storage::disk(MediaStorage::disk());

            return $storage->exists($path)
                && $storage->size($path) <= PostVideo::MAX_KB * 1024;
        } catch (Throwable) {
            return false;
        }
    }

    // เก็บวิดีโอ (ถ้าส่งไฟล์มา) และรูปตัวอย่าง → ['path' => ..., 'thumbnail_path' => ..., 'size_bytes' => ...]
    private function storeVideoFiles(Request $request, User $user, array $data): array
    {
        $disk = MediaStorage::disk();

        $stored = [];

        try {
            if ($request->hasFile('video')) {
                $file = $request->file('video');

                $stored['path'] = $file->storeAs(
                    'post_videos/' . $user->id,
                    Str::uuid() . '.mp4',
                    $disk
                ) ?: throw new RuntimeException('Could not store the video.');

                $stored['size_bytes'] = $file->getSize();
            } else {
                $stored['path'] = $data['video_path'];

                $stored['size_bytes'] = Storage::disk($disk)->size($data['video_path']);
            }

            if ($request->hasFile('video_thumbnail')) {
                $stored['thumbnail_path'] = $request->file('video_thumbnail')
                    ->store('post_video_thumbnails', $disk)
                    ?: throw new RuntimeException('Could not store the thumbnail.');
            }
        } catch (Throwable $e) {
            // ไม่ลบวิดีโอที่อัปโหลดเข้า Bucket ไว้ก่อน (ผู้ใช้ลองโพสต์ใหม่ได้)
            MediaStorage::delete([
                $request->hasFile('video') ? ($stored['path'] ?? null) : null,
                $stored['thumbnail_path'] ?? null,
            ]);

            throw $e;
        }

        return $stored;
    }

    // สร้างโพสต์ + แถวรูป + แจ้งเตือนสมาชิก ใน Transaction เดียว
    private function createPostRecords(
        User $user,
        FamilyMember $membership,
        string $visibility,
        ?string $category,
        string $content,
        array $imagePaths,
        ?int $sharedPostId = null
    ): Post {
        return DB::transaction(
            function () use (
                $visibility,
                $category,
                $content,
                $imagePaths,
                $user,
                $membership,
                $sharedPostId
            ) {
                $post = Post::create([
                    'family_id' =>
                        $membership->family_id,
                    'user_id' => $user->id,
                    'visibility' => $visibility,
                    'category' => $category,
                    'content' => $content,
                    'shared_post_id' => $sharedPostId,
                ]);

                foreach ($imagePaths as $index => $path) {
                    $post->images()->create([
                        'path' => $path,
                        'sort' => $index,
                    ]);
                }

                // โพสต์ชุมชนไม่แจ้งเตือนใคร (กันสแปม)
                if ($visibility !== 'family') {
                    return $post;
                }

                // แจ้งสมาชิกคนอื่นใน Family
                $memberIds =
                    FamilyMember::where(
                        'family_id',
                        $membership->family_id
                    )
                        ->where(
                            'user_id',
                            '!=',
                            $user->id
                        )
                        ->pluck('user_id');

                foreach ($memberIds as $memberId) {
                    AppNotification::create([
                        'user_id' => $memberId,
                        'family_id' =>
                            $membership->family_id,
                        'type' => 'new_post',
                        'title' => 'โพสต์ใหม่',
                        'message' =>
                            $user->name .
                            ($sharedPostId ? ' แชร์โพสต์ให้กลุ่ม' : ' สร้างโพสต์ใหม่'),
                        'data' => [
                            'post_id' => $post->id,
                        ],
                        'is_read' => false,
                    ]);
                }

                return $post;
            }
        );
    }

    // =====================================================
    // ถูกใจ / ยกเลิกถูกใจ
    // POST /api/posts/{post}/like (กดซ้ำ = ยกเลิก)
    // =====================================================

    // =====================================================
    // แชร์โพสต์ชุมชน
    // POST /api/posts/{post}/share
    // channel: external  ส่งต่อไปแอปอื่น (แอปเปิดหน้าแชร์ของมือถือเอง)
    //          community แชร์ซ้ำในชุมชน (สร้างโพสต์ใหม่ที่อ้างถึงต้นฉบับ)
    //          family    ส่งให้ครอบครัว (โพสต์ครอบครัวที่อ้างถึงต้นฉบับ)
    // content: ข้อความเพิ่มเติม (ไม่บังคับ)
    // =====================================================

    public function share(Request $request, Post $post)
    {
        $data = $request->validate([
            'channel' => ['required', Rule::in(Interaction::SHARE_CHANNELS)],
            'content' => 'nullable|string|max:5000',
        ]);

        $user = $request->user();

        $membership = FamilyMember::where('user_id', $user->id)->first();

        // ส่งต่อไปแอปอื่นได้เลย / แชร์ในแอป (ชุมชน, ครอบครัว) ต้องมีครอบครัว
        if (!$membership && $data['channel'] !== 'external') {
            return response()->json([
                'status' => false,
                'code' => 'family_required',
                'message' => 'สร้างหรือเข้าร่วมกลุ่มก่อน จึงจะแชร์ในแอปได้',
            ], 403);
        }

        $blockedIds = $user->blockedUsers()->pluck('users.id');

        // แชร์ต่อจากโพสต์ที่แชร์มาอีกที → อ้างถึงต้นฉบับจริง
        $original = $post->shared_post_id !== null
            ? Post::find($post->shared_post_id)
            : $post;

        // แชร์ได้เฉพาะโพสต์ชุมชนที่เราเห็นได้ (โพสต์ครอบครัวเป็นเรื่องส่วนตัว)
        $visible = $original !== null
            && $original->isCommunity()
            && Post::whereKey($original->id)
                ->visibleInCommunityTo($user, $blockedIds)
                ->exists();

        if (!$visible) {
            return response()->json([
                'status' => false,
                'message' => 'แชร์ได้เฉพาะโพสต์ในชุมชนที่ยังแสดงอยู่',
            ], 404);
        }

        $channel = $data['channel'];

        if ($channel === 'community' && $user->community_terms_accepted_at === null) {
            return response()->json([
                'status' => false,
                'code' => 'terms_required',
                'message' => 'กรุณายอมรับกฎชุมชนก่อนโพสต์',
            ], 403);
        }

        $shared = null;

        if ($channel !== 'external') {
            $shared = $this->createPostRecords(
                $user,
                $membership,
                $channel,
                $channel === 'community' ? ($original->category ?? 'general') : null,
                trim($data['content'] ?? ''),
                [],
                $original->id
            );

            $shared = Post::whereKey($shared->id)
                ->with($this->familyRelations())
                ->tap(fn ($query) => $this->withLikeInfo($query, $user))
                ->first();

            $shared = $this->withOwnership($shared, $user, $blockedIds);
        }

        Interaction::record($user, Interaction::SHARE, $original, meta: ['channel' => $channel]);

        $messages = [
            'external' => 'แชร์แล้ว',
            'community' => 'แชร์ในชุมชนแล้ว',
            'family' => 'ส่งให้กลุ่มแล้ว',
        ];

        return response()->json([
            'status' => true,
            'message' => $messages[$channel],
            'post_id' => $original->id,
            'shares_count' => $original->shares()->count(),
            'post' => $shared,
        ], $shared ? 201 : 200);
    }

    public function like(
        Request $request,
        Post $post
    ) {
        $user = $request->user();

        $membership = FamilyMember::where(
            'user_id',
            $user->id
        )->first();

        if (!$this->canInteract($post, $membership)) {
            return response()->json([
                'status' => false,
                'message' => 'คุณไม่มีสิทธิ์ถูกใจโพสต์นี้',
            ], 403);
        }

        $existing = PostLike::where('post_id', $post->id)
            ->where('user_id', $user->id)
            ->first();

        if ($existing) {
            $existing->delete();

            Interaction::forget($user, Interaction::LIKE, $post);
        } else {
            PostLike::firstOrCreate([
                'post_id' => $post->id,
                'user_id' => $user->id,
            ]);

            Interaction::record($user, Interaction::LIKE, $post);
        }

        return response()->json([
            'status' => true,
            'liked' => $existing === null,
            'likes_count' => $post->likes()->count(),
        ]);
    }

    // =====================================================
    // ลบ Post
    // =====================================================

    public function destroy(
        Request $request,
        Post $post
    ) {
        $user = $request->user();

        // ต้องเป็นเจ้าของ Post
        if ($post->user_id !== $user->id) {
            return response()->json([
                'status' => false,
                'message' =>
                    'คุณสามารถลบได้เฉพาะโพสต์ของตัวเอง',
            ], 403);
        }

        // โพสต์ครอบครัว: ต้องยังอยู่ใน Family ของ Post นี้
        // โพสต์ชุมชน: เจ้าของลบได้เสมอ
        if (!$post->isCommunity()) {
            $membership = FamilyMember::where(
                'user_id',
                $user->id
            )
                ->where(
                    'family_id',
                    $post->family_id
                )
                ->first();

            if (!$membership) {
                return response()->json([
                    'status' => false,
                    'message' =>
                        'คุณไม่ได้อยู่ในกลุ่มของโพสต์นี้แล้ว',
                ], 403);
            }
        }

        $post->delete();

        return response()->json([
            'status' => true,
            'message' => 'ลบโพสต์สำเร็จ',
        ]);
    }

    // =====================================================
    // รายงาน Post ชุมชน
    // =====================================================

    public function report(
        Request $request,
        Post $post
    ) {
        $data = $request->validate([
            'reason' =>
                'required|in:spam,inappropriate,harassment,scam,other',
            'details' => 'nullable|string|max:1000',
        ]);

        $user = $request->user();

        if (!$post->isCommunity()) {
            return response()->json([
                'status' => false,
                'message' => 'รายงานได้เฉพาะโพสต์ชุมชน',
            ], 422);
        }

        if ((int) $post->user_id === (int) $user->id) {
            return response()->json([
                'status' => false,
                'message' => 'ไม่สามารถรายงานโพสต์ของตัวเองได้',
            ], 422);
        }

        // รายงานซ้ำไม่นับเพิ่ม
        PostReport::firstOrCreate(
            [
                'post_id' => $post->id,
                'user_id' => $user->id,
            ],
            [
                'reason' => $data['reason'],
                'details' => $data['details'] ?? null,
            ]
        );

        // ซ่อนอัตโนมัติเมื่อถูกรายงานครบ
        if (
            $post->hidden_at === null
            && $post->reports()->count() >= config('community.auto_hide_reports')
        ) {
            $post->hidden_at = now();
            $post->save();
        }

        return response()->json([
            'status' => true,
            'message' =>
                'ขอบคุณที่รายงาน เราจะตรวจสอบโพสต์นี้',
        ]);
    }

    // =====================================================
    // HELPERS
    // =====================================================

    // โพสต์ชุมชนที่ผู้ใช้คนนี้เห็นได้:
    // ไม่ถูกซ่อน, ไม่ใช่โพสต์ที่เรารายงานแล้ว, ไม่ใช่ของคนที่เราบล็อก
    private function visibleInCommunity($query, User $user, $blockedIds)
    {
        return $query->visibleInCommunityTo($user, $blockedIds);
    }

    // ผู้ใช้ถูกใจ/โต้ตอบกับโพสต์นี้ได้หรือไม่
    // - โพสต์ชุมชน: ต้องมีครอบครัว และโพสต์ต้องไม่ถูกซ่อน
    // - โพสต์ครอบครัว: ต้องอยู่ครอบครัวเดียวกับโพสต์
    // โพสต์ชุมชน: ทุกคน (ยังไม่มีครอบครัวก็ได้) / โพสต์ครอบครัว: คนในครอบครัวนั้น
    private function canInteract(Post $post, ?FamilyMember $membership): bool
    {
        if ($post->isCommunity()) {
            return $post->hidden_at === null;
        }

        if (!$membership) {
            return false;
        }

        return (int) $post->family_id === (int) $membership->family_id;
    }
}
