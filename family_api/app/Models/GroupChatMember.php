<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

// สิทธิ์ในห้องแชทกลุ่มของสมาชิก "หนึ่งรอบ" (ผูกกับแถว family_members แถวเดียว)
class GroupChatMember extends Model
{
    protected $fillable = [
        'group_chat_id',
        'family_member_id',
        'user_id',
        'visible_after_id',
        'last_read_id',
        'muted',
    ];

    protected $casts = [
        'visible_after_id' => 'integer',
        'last_read_id' => 'integer',
        'muted' => 'boolean',
    ];

    public function chat()
    {
        return $this->belongsTo(GroupChat::class, 'group_chat_id');
    }

    public function familyMember()
    {
        return $this->belongsTo(FamilyMember::class);
    }

    public function user()
    {
        return $this->belongsTo(User::class);
    }

    // ข้อความที่คนนี้เห็นได้ (ตั้งแต่เข้ากลุ่มรอบนี้)
    public function visibleMessages()
    {
        return GroupChatMessage::where('group_chat_id', $this->group_chat_id)
            ->where('id', '>', $this->visible_after_id);
    }

    // ยังไม่อ่าน = ข้อความของคนอื่นที่เห็นได้ และอยู่หลังตำแหน่งอ่านของคนนี้
    public function unreadCount(): int
    {
        return $this->visibleMessages()
            ->where('id', '>', $this->last_read_id)
            ->where('sender_id', '!=', $this->user_id)
            ->count();
    }

    // อ่านถึงข้อความนี้ (ไม่ถอยหลัง: อีกเครื่องอ่านไปไกลกว่าแล้วไม่ถูกดึงกลับ)
    public function markReadUpTo(int $messageId): void
    {
        self::whereKey($this->id)
            ->where('last_read_id', '<', $messageId)
            ->update(['last_read_id' => $messageId]);

        $this->last_read_id = max($this->last_read_id, $messageId);
    }
}
