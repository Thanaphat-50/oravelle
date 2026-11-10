<?php

namespace App\Models;

use App\Support\MediaStorage;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Facades\URL;
use Throwable;

// =======================================================
// ข้อความในห้องแชทกลุ่ม
// - รูปเก็บใน disk ส่วนตัว (Cloud = Private Bucket / ในเครื่อง = local) ไม่มี URL สาธารณะ
// - เปิดรูปผ่านลิงก์ลงลายเซ็นอายุ LINK_MINUTES นาที ที่ผูกกับผู้ดู และตรวจสิทธิ์ซ้ำทุกครั้งที่เปิด
//   (ลิงก์ยังไม่หมดอายุแต่หมดสิทธิ์แล้ว → เปิดไม่ได้)
// =======================================================

class GroupChatMessage extends Model
{
    public const LINK_MINUTES = 10;

    protected $fillable = [
        'group_chat_id',
        'sender_id',
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

    protected $casts = [
        'is_reply' => 'boolean',
    ];

    public function chat()
    {
        return $this->belongsTo(GroupChat::class, 'group_chat_id');
    }

    public function sender()
    {
        return $this->belongsTo(User::class, 'sender_id');
    }

    public static function disk(): string
    {
        $disk = MediaStorage::disk();

        return $disk === 'public' ? 'local' : $disk;
    }

    // เรียกเฉพาะเมื่อผู้ดูมีสิทธิ์เห็นข้อความนี้แล้ว
    public function imageUrlFor(User $viewer): ?string
    {
        if (!$this->image_path) {
            return null;
        }

        return URL::temporarySignedRoute(
            'group-chat.image',
            now()->addMinutes(self::LINK_MINUTES),
            ['message' => $this->id, 'viewer' => $viewer->id]
        );
    }

    // ลบไฟล์รูปหลังลบข้อมูลสำเร็จ (ลบกลุ่ม / ลบบัญชี)
    public static function deleteFiles(array $paths): void
    {
        $paths = array_values(array_filter($paths));

        if ($paths === []) {
            return;
        }

        $disk = self::disk();

        DB::afterCommit(function () use ($disk, $paths) {
            try {
                Storage::disk($disk)->delete($paths);
            } catch (Throwable $e) {
                Log::warning('Could not delete group chat images', ['error' => $e->getMessage()]);
            }
        });
    }
}
