<?php

namespace App\Http\Controllers;

use App\Http\Controllers\Concerns\PresentsPosts;
use App\Models\FamilyMember;
use App\Models\Post;
use App\Models\SavedPost;
use Illuminate\Database\UniqueConstraintViolationException;
use Illuminate\Http\Request;

// =======================================================
// บันทึกโพสต์ไว้อ่าน (ส่วนตัว)
//
// PUT    /api/posts/{post}/save   บันทึก (ส่งซ้ำได้ ผลเหมือนเดิม — ไม่ใช่สลับสถานะ)
// DELETE /api/posts/{post}/save   ยกเลิกบันทึก (ส่งซ้ำได้)
// GET    /api/saved-posts?cursor= รายการที่บันทึก ล่าสุดก่อน ครั้งละ 20
//
// - บันทึกได้เฉพาะโพสต์ที่เห็นได้ตอนนี้: ชุมชน (กติกาเดียวกับฟีด/ค้นหา) หรือโพสต์ในกลุ่มที่อยู่ตอนนี้
// - รายการ: กรองโพสต์ที่หมดสิทธิ์ (ลบ / ซ่อน / บล็อก / ออกจากกลุ่ม) ก่อนแบ่งหน้า
//   รายการบันทึกเดิมยังเก็บไว้ (กลับมามีสิทธิ์ก็เห็นอีก) แต่ไม่ส่งเนื้อหาที่หมดสิทธิ์
// - ไม่มี API ไหนบอกว่าใครบันทึกโพสต์อะไร (saved_by_me เป็นของผู้ใช้คนนั้นเท่านั้น)
// =======================================================

class SavedPostController extends Controller
{
    use PresentsPosts;

    private const PAGE_SIZE = 20;

    public function index(Request $request)
    {
        $data = $request->validate(['cursor' => 'nullable|integer|min:1']);

        $user = $request->user();
        $familyId = FamilyMember::where('user_id', $user->id)->value('family_id');
        $blockedIds = $user->blockedUsers()->pluck('users.id');

        // กรองสิทธิ์ใน query ก่อนแบ่งหน้า (ไม่มีหน้าว่าง/หน้าขาดเพราะกรองทีหลัง)
        $saved = SavedPost::where('user_id', $user->id)
            ->when($data['cursor'] ?? null, fn ($query, $cursor) => $query->where('id', '<', $cursor))
            ->whereHas('post', fn ($posts) => $posts->visibleTo($user, $familyId, $blockedIds))
            ->orderByDesc('id')
            ->limit(self::PAGE_SIZE + 1)
            ->get(['id', 'post_id', 'created_at']);

        $hasMore = $saved->count() > self::PAGE_SIZE;
        $saved = $saved->take(self::PAGE_SIZE);

        $posts = Post::whereIn('id', $saved->pluck('post_id'))
            ->visibleTo($user, $familyId, $blockedIds)
            ->with($this->communityRelations($user, $blockedIds))
            ->tap(fn ($query) => $this->withLikeInfo($query, $user))
            ->get()
            ->keyBy('id');

        return response()->json([
            'status' => true,
            'current_user' => $this->currentUserPayload($user),
            'posts' => $saved
                ->filter(fn (SavedPost $row) => $posts->has($row->post_id))
                ->map(function (SavedPost $row) use ($posts, $user, $blockedIds) {
                    $post = $this->withOwnership($posts[$row->post_id], $user, $blockedIds);
                    $post->setAttribute('saved_at', $row->created_at?->toIso8601String());

                    return $post;
                })
                ->values(),
            'next_cursor' => $hasMore ? (string) $saved->last()->id : null,
            'has_more' => $hasMore,
        ]);
    }

    public function store(Request $request, Post $post)
    {
        $user = $request->user();
        $familyId = FamilyMember::where('user_id', $user->id)->value('family_id');

        $visible = Post::whereKey($post->id)
            ->visibleTo($user, $familyId)
            ->exists();

        if (!$visible) {
            return response()->json([
                'status' => false,
                'message' => 'ไม่พบโพสต์นี้ หรือคุณไม่มีสิทธิ์ดูแล้ว',
            ], 404);
        }

        try {
            SavedPost::firstOrCreate(['user_id' => $user->id, 'post_id' => $post->id]);
        } catch (UniqueConstraintViolationException) {
            // ส่งพร้อมกันสองครั้ง → อีกคำขอบันทึกไปแล้ว
        }

        return response()->json([
            'status' => true,
            'saved' => true,
            'message' => 'บันทึกโพสต์แล้ว',
        ]);
    }

    public function destroy(Request $request, Post $post)
    {
        SavedPost::where('user_id', $request->user()->id)
            ->where('post_id', $post->id)
            ->delete();

        return response()->json([
            'status' => true,
            'saved' => false,
            'message' => 'ยกเลิกบันทึกแล้ว',
        ]);
    }
}
