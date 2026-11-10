<?php

namespace App\Http\Controllers\Concerns;

use App\Models\Post;
use App\Models\User;

// =======================================================
// ข้อมูลโพสต์ที่ส่งให้แอป (ใช้ร่วมกัน: ฟีด / โพสต์เดียว / ค้นหา)
// ย้ายมาจาก PostController เพื่อให้ทุกหน้าแสดงและกรองเหมือนกัน
// =======================================================

trait PresentsPosts
{
    // ข้อมูลผู้ใช้ที่ส่งไปกับโพสต์/ความคิดเห็น (ไม่ส่ง email)
    private const USER_COLUMNS = 'id,name,profile_photo';

    // ข้อมูลที่โหลดมากับโพสต์ชุมชน
    // ไม่แสดงความคิดเห็นที่ถูกซ่อน, ที่เรารายงานแล้ว หรือของคนที่เราบล็อก
    private function familyRelations(): array
    {
        return [
            'user:' . self::USER_COLUMNS,
            'images',
            'video',
            'comments.user:' . self::USER_COLUMNS,
            'sharedPost.user:' . self::USER_COLUMNS,
            'sharedPost.images',
            'sharedPost.video',
        ];
    }

    private function communityRelations(User $user, $blockedIds): array
    {
        return [
            'user:' . self::USER_COLUMNS,
            'images',
            'video',
            'sharedPost.user:' . self::USER_COLUMNS,
            'sharedPost.images',
            'sharedPost.video',
            'comments' => function ($query) use ($blockedIds, $user) {
                $query->whereNull('hidden_at')
                    ->whereDoesntHave('reports', function ($reports) use ($user) {
                        $reports->where('user_id', $user->id);
                    })
                    ->whereNotIn('user_id', $blockedIds);
            },
            'comments.user:' . self::USER_COLUMNS,
        ];
    }

    // จำนวนถูกใจ (likes_count) และเราถูกใจแล้วหรือยัง (liked_by_me)
    private function withLikeInfo($query, User $user)
    {
        return $query->withCount(['likes', 'shares'])
            ->withExists([
                'likes as liked_by_me' => fn ($likes) => $likes->where('user_id', $user->id),
            ]);
    }

    // ให้แอปรู้ว่าโพสต์ไหนเป็นของเรา (แสดงปุ่มลบ)
    private function withOwnership(Post $post, User $user, $blockedIds = null): Post
    {
        $post->setAttribute(
            'is_mine',
            (int) $post->user_id === (int) $user->id
        );

        // โพสต์ที่แชร์ต่อมา: ต้นฉบับถูกลบ / ถูกซ่อน / เป็นของคนที่เราบล็อก → ไม่แสดงต้นฉบับ
        if ($post->shared_post_id !== null) {
            $original = $post->sharedPost;

            $blockedIds ??= $user->blockedUsers()->pluck('users.id');

            $available = $original !== null
                && $original->isCommunity()
                && $original->hidden_at === null
                && !$blockedIds->contains($original->user_id);

            if (!$available) {
                $post->setRelation('sharedPost', null);
            }

            $post->setAttribute('shared_post_unavailable', !$available);
        }

        return $post;
    }

    private function currentUserPayload(User $user): array
    {
        return [
            ...$user->only([
                'id',
                'name',
                'profile_image_url',
            ]),
            'community_terms_accepted' =>
                $user->community_terms_accepted_at !== null,
        ];
    }
}
