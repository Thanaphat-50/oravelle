<?php

namespace App\Models;

use App\Services\PushNotifications;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\UniqueConstraintViolationException;

// =======================================================
// ห้องแชทกลุ่มครอบครัว (1 กลุ่ม = 1 ห้อง)
//
// สิทธิ์มาจากระบบสมาชิกกลุ่มเดิมเท่านั้น (ไม่มีรายชื่อสมาชิกแชทแยกอีกชุด):
// - สมาชิก "รอบนี้" = แถว family_members ปัจจุบัน + แถว group_chat_members ที่ผูกกับแถวนั้น
// - เข้ากลุ่ม → เห็นเฉพาะข้อความหลังเข้า (visible_after_id = id ข้อความล่าสุดตอนเข้า)
// - ออก / ถูกนำออก / ลบกลุ่ม → แถวสมาชิกหาย → อ่าน ส่ง โหลดเพิ่ม ดูรูป ไม่ได้ทันที
// - กลับเข้าใหม่ → แถวใหม่ → ไม่คืนประวัติรอบเก่า
// - เปิดใช้ห้องครั้งแรก: สมาชิกปัจจุบันเริ่มเห็นตั้งแต่ข้อความแรกของห้อง (ห้องใหม่ยังว่าง
//   ไม่ดึงแชทส่วนตัวเก่ามารวม)
// =======================================================

class GroupChat extends Model
{
    protected $fillable = [
        'family_id',
        'last_message_at',
    ];

    protected $casts = [
        'last_message_at' => 'datetime',
    ];

    public function family()
    {
        return $this->belongsTo(Family::class);
    }

    public function messages()
    {
        return $this->hasMany(GroupChatMessage::class);
    }

    public function members()
    {
        return $this->hasMany(GroupChatMember::class);
    }

    // ห้องของกลุ่มนี้ (ยังไม่มี → สร้าง) — หลายคนเปิดพร้อมกันได้ห้องเดียว (family_id ไม่ซ้ำ)
    public static function forFamily(int $familyId): self
    {
        $existing = self::where('family_id', $familyId)->first();

        if ($existing) {
            return $existing;
        }

        try {
            $chat = self::create(['family_id' => $familyId]);
        } catch (UniqueConstraintViolationException) {
            return self::where('family_id', $familyId)->firstOrFail();
        }

        // ห้องใหม่ (ยังไม่มีข้อความ): สมาชิกปัจจุบันทุกคนเห็นตั้งแต่ข้อความแรก
        foreach (FamilyMember::where('family_id', $familyId)->get() as $member) {
            $chat->grant($member, 0);
        }

        return $chat;
    }

    // ให้สิทธิ์สมาชิกรอบนี้ (มีอยู่แล้ว → ใช้ของเดิม ไม่ขยายประวัติให้)
    public function grant(FamilyMember $member, int $visibleAfterId): GroupChatMember
    {
        try {
            return GroupChatMember::firstOrCreate(
                ['family_member_id' => $member->id],
                [
                    'group_chat_id' => $this->id,
                    'user_id' => $member->user_id,
                    'visible_after_id' => $visibleAfterId,
                ]
            );
        } catch (UniqueConstraintViolationException) {
            return GroupChatMember::where('family_member_id', $member->id)->firstOrFail();
        }
    }

    public function latestMessageId(): int
    {
        return (int) $this->messages()->max('id');
    }

    // สิทธิ์ของผู้ใช้ในห้องนี้ตอนนี้ (null = ไม่ใช่สมาชิกปัจจุบันของกลุ่มนี้)
    public function accessFor(User $user): ?GroupChatMember
    {
        $membership = FamilyMember::where('user_id', $user->id)
            ->where('family_id', $this->family_id)
            ->first();

        if (!$membership) {
            return null;
        }

        $access = GroupChatMember::where('family_member_id', $membership->id)->first();

        if ($access) {
            return $access;
        }

        // ไม่มีบันทึกสิทธิ์ (เช่น เข้ากลุ่มพร้อมกับตอนห้องถูกสร้าง):
        // เป็นสมาชิกก่อนเปิดห้อง → ตั้งแต่ข้อความแรก / เข้าทีหลัง → เริ่มจากตอนนี้ (ไม่หลุดข้อความก่อนเข้า)
        $from = $membership->created_at !== null
            && $this->created_at !== null
            && $membership->created_at->lte($this->created_at)
                ? 0
                : $this->latestMessageId();

        return $this->grant($membership, $from);
    }

    // =====================================================
    // แจ้งเตือนเด้ง (หลังตอบแอปแล้ว) — ตรวจสิทธิ์ใหม่ตอนส่งจริง
    // - สมาชิกปัจจุบันที่เห็นข้อความนี้ / ไม่ใช่ผู้ส่ง / ไม่ได้ปิดเสียงห้อง
    // - ไม่ได้บล็อกผู้ส่ง (ข้อความยังอยู่ในห้องและนับยังไม่อ่านตามปกติ)
    // - ปิดแจ้งเตือน "ข้อความแชท" ในหน้าตั้งค่า → ไม่ส่ง
    // - ข้อความทั่วไป ไม่มีเนื้อหา/ชื่อกลุ่ม (หน้าจอล็อก) / Push ไปทุกเครื่องที่ยังเข้าสู่ระบบอยู่
    //   ไม่สร้างรายการในหน้าแจ้งเตือน (เหมือนแชทส่วนตัว)
    // =====================================================

    public const PUSH_TYPE = 'group_message';

    public static function notifyNewMessage(int $messageId): void
    {
        $message = GroupChatMessage::find($messageId);
        $chat = $message?->chat;

        if (!$message || !$chat) {
            return;
        }

        $recipientIds = GroupChatMember::where('group_chat_id', $chat->id)
            ->where('user_id', '!=', $message->sender_id)
            ->where('muted', false)
            ->where('visible_after_id', '<', $message->id)
            ->whereHas('familyMember', fn ($members) => $members->where('family_id', $chat->family_id))
            ->pluck('user_id')
            ->unique();

        if ($recipientIds->isEmpty()) {
            return;
        }

        $blockedSender = UserBlock::where('blocked_user_id', $message->sender_id)
            ->whereIn('user_id', $recipientIds)
            ->pluck('user_id');

        $recipients = User::whereIn('id', $recipientIds->diff($blockedSender))
            ->get(['id', 'notification_settings']);

        $push = app(PushNotifications::class);

        foreach ($recipients as $recipient) {
            if (!$recipient->wantsNotification(AppNotification::TYPE_NEW_MESSAGE)) {
                continue;
            }

            $push->sendToUser(
                $recipient->id,
                'แชทกลุ่ม',
                'มีข้อความใหม่ในกลุ่ม',
                ['type' => self::PUSH_TYPE, 'group_chat_id' => $chat->id],
                'group-chat-' . $chat->id
            );
        }
    }
}
