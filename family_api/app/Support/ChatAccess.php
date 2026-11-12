<?php

namespace App\Support;

use App\Models\Conversation;
use App\Models\FamilyMember;
use App\Models\User;
use App\Models\UserBlock;
use Illuminate\Support\Collection;

// =======================================================
// สิทธิ์ของห้องแชทส่วนตัว/ร้านค้า (ใช้ร่วมกัน: ส่งข้อความ / Reaction / โทร)
// ส่งหรือโทรได้เมื่อ ไม่มีใครบล็อกใคร และ (อยู่กลุ่มเดียวกัน หรือเป็นห้องลูกค้า-ร้านค้า)
// =======================================================

class ChatAccess
{
    public static function canSend(User $me, int $otherId, ?Conversation $conversation = null): bool
    {
        if (self::blockedEitherWay($me)->contains($otherId)) {
            return false;
        }

        return self::familyMemberIds($me)->contains($otherId)
            || ($conversation?->isShopChatWith($me->id, $otherId) ?? false);
    }

    // คนในกลุ่มเดียวกัน (ไม่รวมตัวเอง)
    public static function familyMemberIds(User $me): Collection
    {
        $familyId = FamilyMember::where('user_id', $me->id)->value('family_id');

        if (!$familyId) {
            return collect();
        }

        return FamilyMember::where('family_id', $familyId)
            ->where('user_id', '!=', $me->id)
            ->pluck('user_id')
            ->map(fn ($id) => (int) $id);
    }

    // คนที่เราบล็อก หรือบล็อกเรา
    public static function blockedEitherWay(User $me): Collection
    {
        return UserBlock::where('user_id', $me->id)->pluck('blocked_user_id')
            ->merge(UserBlock::where('blocked_user_id', $me->id)->pluck('user_id'))
            ->map(fn ($id) => (int) $id)
            ->unique();
    }
}
