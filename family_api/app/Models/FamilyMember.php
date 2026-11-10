<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class FamilyMember extends Model
{
    protected $fillable = [
        'family_id',
        'user_id',
        'role',
    ];

    public function family()
    {
        return $this->belongsTo(Family::class);
    }

    public function user()
    {
        return $this->belongsTo(User::class);
    }

    // แชทกลุ่ม: สิทธิ์ผูกกับ "รอบสมาชิก" (แถวนี้) — ใช้ระบบสมาชิกกลุ่มเป็นแหล่งสิทธิ์หลัก
    protected static function booted(): void
    {
        // เข้ากลุ่ม (สร้างกลุ่ม / รหัสเชิญ / คำเชิญ / อนุมัติคำขอ) → ถ้ามีห้องแล้ว เห็นเฉพาะข้อความหลังจากนี้
        static::created(function (FamilyMember $member) {
            $chat = GroupChat::where('family_id', $member->family_id)->first();

            $chat?->grant($member, $chat->latestMessageId());
        });

        // ออก / ถูกนำออก → สิทธิ์ของรอบนี้หมด (foreign key ลบตามอีกชั้น)
        static::deleted(function (FamilyMember $member) {
            GroupChatMember::where('family_member_id', $member->id)->delete();
        });
    }
}