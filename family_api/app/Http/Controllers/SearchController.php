<?php

namespace App\Http\Controllers;

use App\Http\Controllers\Concerns\PresentsPosts;
use App\Models\FamilyMember;
use App\Models\Post;
use App\Models\User;
use App\Models\UserBlock;
use Illuminate\Http\Request;

// =======================================================
// ค้นหาโพสต์และผู้ใช้
//
// GET /api/search/posts?q=&scope=community|family&cursor=
// GET /api/search/users?q=&cursor=
//
// - ค้นจากข้อมูลทั้งหมดบนเซิร์ฟเวอร์ที่ผู้ใช้มีสิทธิ์เห็น (กติกาเดียวกับฟีด/โปรไฟล์เดิม)
//   ชุมชน: Post::visibleInCommunityTo (ไม่ถูกซ่อน / ไม่ใช่ที่เรารายงาน / ไม่ใช่ของคนที่เราบล็อก)
//   ในกลุ่ม: โพสต์กลุ่มของกลุ่มที่อยู่ตอนนี้ (ดูจากผู้ใช้ที่เข้าสู่ระบบ ไม่รับ family_id จากแอป)
//   ผู้ใช้: ชื่อที่แสดงเท่านั้น / คนที่มีตัวตนในชุมชน + คนในกลุ่มเดียวกัน / ไม่รวมคนที่บล็อกกัน (ทั้งสองทาง)
// - คำค้น: ตัดช่องว่างหัวท้าย ยาวไม่เกิน MAX_LENGTH / แยกคำด้วยช่องว่าง → ต้องมีทุกคำ
//   % _ ! เป็นตัวอักษรธรรมดา (ไม่ใช่ wildcard) และส่งผ่าน parameter binding
// - LIKE '%คำ%' (ไม่ใช้ full-text: MySQL ตัดคำไทยไม่ได้ ข้อความไทยไม่มีช่องว่างระหว่างคำ)
// - แบ่งหน้าแบบ cursor ครั้งละ PAGE_SIZE: มีโพสต์ใหม่ระหว่างเลื่อนก็ไม่ซ้ำ/ไม่ข้าม
// - ไม่ส่งจำนวนทั้งหมด (ไม่เปิดเผยรายการที่ถูกกรองออก) บอกแค่ has_more
// =======================================================

class SearchController extends Controller
{
    use PresentsPosts;

    public const MAX_LENGTH = 100;

    // คำค้นแยกด้วยช่องว่างได้ไม่เกินเท่านี้คำ (คำที่เกินไม่นำมาค้น)
    public const MAX_WORDS = 8;

    private const PAGE_SIZE = 20;

    // อักขระ escape ของ LIKE (ใช้ได้ทั้ง MySQL และ SQLite)
    private const ESCAPE = '!';

    public function posts(Request $request)
    {
        $data = $request->validate($this->rules([
            'scope' => 'nullable|in:community,family',
        ]), $this->messages());

        $user = $request->user();
        $words = $this->words($data['q']);
        $scope = $data['scope'] ?? 'community';

        if ($scope === 'family') {
            $membership = FamilyMember::where('user_id', $user->id)->first();

            if (!$membership) {
                return response()->json([
                    'status' => false,
                    'code' => 'no_family',
                    'message' => 'คุณยังไม่ได้อยู่ในกลุ่ม จึงค้นหาโพสต์ในกลุ่มไม่ได้',
                ], 403);
            }

            $query = Post::where('visibility', 'family')
                ->where('family_id', $membership->family_id)
                ->with($this->familyRelations());

            $blockedIds = null;
        } else {
            $blockedIds = $user->blockedUsers()->pluck('users.id');

            $query = Post::query()
                ->visibleInCommunityTo($user, $blockedIds)
                ->with($this->communityRelations($user, $blockedIds));
        }

        $paginator = $query
            ->where(fn ($posts) => $this->matchAll($posts, 'posts.content', $words))
            ->tap(fn ($posts) => $this->withLikeInfo($posts, $user))
            ->orderByDesc('created_at')
            ->orderByDesc('id')
            ->cursorPaginate(self::PAGE_SIZE);

        return response()->json([
            'status' => true,
            'scope' => $scope,
            'q' => $data['q'],
            'current_user' => $this->currentUserPayload($user),
            'posts' => collect($paginator->items())
                ->map(fn (Post $post) => $this->withOwnership($post, $user, $blockedIds))
                ->values(),
            'next_cursor' => $paginator->nextCursor()?->encode(),
            'has_more' => $paginator->hasMorePages(),
        ]);
    }

    public function users(Request $request)
    {
        $data = $request->validate($this->rules(), $this->messages());

        $me = $request->user();
        $words = $this->words($data['q']);

        $familyId = FamilyMember::where('user_id', $me->id)->value('family_id');

        $familyIds = $familyId
            ? FamilyMember::where('family_id', $familyId)->pluck('user_id')
            : collect();

        $paginator = User::query()
            ->where(fn ($users) => $this->matchAll($users, 'users.name', $words))
            ->whereNotIn('users.id', UserBlock::idsBlockedEitherWay($me))
            // เปิดโปรไฟล์ได้ (กติกาเดียวกับ GET /users/{user}/profile)
            ->where(fn ($users) => $users
                ->whereKey($me->id)
                ->orWhereIn('users.id', $familyIds)
                ->orWhere(fn ($community) => $community->withCommunityPresence()))
            ->orderBy('name')
            ->orderBy('id')
            ->cursorPaginate(self::PAGE_SIZE, ['users.id', 'users.name', 'users.profile_photo']);

        return response()->json([
            'status' => true,
            'q' => $data['q'],
            // ชื่อและรูปเท่านั้น (ไม่มีอีเมล เบอร์โทร หรือข้อมูลบัญชี)
            'users' => collect($paginator->items())->map(fn (User $user) => [
                'id' => $user->id,
                'name' => $user->name,
                'profile_image_url' => $user->profile_image_url,
                'is_me' => (int) $user->id === (int) $me->id,
                'is_family' => (int) $user->id !== (int) $me->id && $familyIds->contains($user->id),
            ])->values(),
            'next_cursor' => $paginator->nextCursor()?->encode(),
            'has_more' => $paginator->hasMorePages(),
        ]);
    }

    private function rules(array $extra = []): array
    {
        return [
            'q' => 'required|string|max:' . self::MAX_LENGTH,
            'cursor' => 'nullable|string|max:500',
            ...$extra,
        ];
    }

    private function messages(): array
    {
        return [
            'q.required' => 'กรุณาพิมพ์คำค้นหา',
            'q.max' => 'คำค้นหายาวได้ไม่เกิน ' . self::MAX_LENGTH . ' ตัวอักษร',
        ];
    }

    // แยกคำด้วยช่องว่าง (รวมช่องว่างหลายตัว) ไม่ซ้ำ ไม่เกิน MAX_WORDS คำ
    private function words(string $q): array
    {
        $parts = preg_split('/\s+/u', trim($q), -1, PREG_SPLIT_NO_EMPTY) ?: [];

        return array_slice(array_values(array_unique($parts)), 0, self::MAX_WORDS);
    }

    // ทุกคำต้องอยู่ในคอลัมน์ (ตำแหน่งไหนก็ได้) — คำค้นเป็นตัวอักษรตามที่พิมพ์ ไม่ใช่ wildcard
    private function matchAll($query, string $column, array $words)
    {
        foreach ($words as $word) {
            $escaped = str_replace(
                [self::ESCAPE, '%', '_'],
                [self::ESCAPE . self::ESCAPE, self::ESCAPE . '%', self::ESCAPE . '_'],
                $word
            );

            $query->whereRaw("{$column} LIKE ? ESCAPE '" . self::ESCAPE . "'", ['%' . $escaped . '%']);
        }

        return $query;
    }
}
