<?php

namespace App\Models;

use App\Support\MediaStorage;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Facades\DB;

class ChatMessage extends Model
{
    protected $fillable = [
        'conversation_id',
        'sender_id',
        // รหัสจากแอป (กันส่งซ้ำ) — ไม่ซ้ำต่อ ห้อง + ผู้ส่ง
        'client_id',
        'body',
        'image_path',
        // ตอบกลับข้อความ (ห้องเดียวกันเท่านั้น)
        'reply_to_id',
        'is_reply',
    ];

    protected $hidden = [
        'image_path',
    ];

    protected $appends = [
        'image_url',
    ];

    protected $casts = [
        'is_reply' => 'boolean',
    ];

    public function conversation()
    {
        return $this->belongsTo(Conversation::class);
    }

    public function sender()
    {
        return $this->belongsTo(User::class, 'sender_id');
    }

    public function getImageUrlAttribute(): ?string
    {
        return MediaStorage::url($this->image_path);
    }

    // ยกเลิกการส่ง → ลบไฟล์รูปหลังลบข้อมูลสำเร็จ
    protected static function booted(): void
    {
        static::deleted(function (ChatMessage $message) {
            $path = $message->image_path;

            if ($path) {
                DB::afterCommit(fn () => MediaStorage::delete([$path]));
            }
        });
    }
}
