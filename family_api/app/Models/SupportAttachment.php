<?php

namespace App\Models;

use App\Support\MediaStorage;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\URL;

// =======================================================
// รูปแนบในคำร้อง (ข้อมูลส่วนตัว)
// - เก็บใน disk ส่วนตัว: Cloud = Private Bucket / ในเครื่อง = local (ไม่ใช่ public)
// - เปิดผ่านลิงก์ชั่วคราวที่ลงลายเซ็น (30 นาที) สร้างให้เฉพาะเจ้าของคำร้องและทีมงาน
//   GET /api/support/files/{attachment}?signature=… (SupportTicketController::file)
// =======================================================

class SupportAttachment extends Model
{
    public const LINK_MINUTES = 30;

    protected $fillable = [
        'ticket_id',
        'message_id',
        'path',
        'mime',
        'size',
    ];

    public function ticket()
    {
        return $this->belongsTo(SupportTicket::class, 'ticket_id');
    }

    public static function disk(): string
    {
        $disk = MediaStorage::disk();

        return $disk === 'public' ? 'local' : $disk;
    }

    // เรียกเฉพาะเมื่อผู้ดูมีสิทธิ์แล้ว (เจ้าของคำร้อง / ทีมงาน)
    public function signedUrl(): string
    {
        return URL::temporarySignedRoute(
            'support.file',
            now()->addMinutes(self::LINK_MINUTES),
            ['attachment' => $this->id]
        );
    }

    public function payload(): array
    {
        return [
            'id' => $this->id,
            'url' => $this->signedUrl(),
            'mime' => $this->mime,
            'size' => $this->size,
        ];
    }

    public static function deleteFiles(array $paths): void
    {
        $paths = array_values(array_filter($paths));

        if ($paths === []) {
            return;
        }

        $disk = self::disk();

        DB::afterCommit(function () use ($disk, $paths) {
            try {
                \Illuminate\Support\Facades\Storage::disk($disk)->delete($paths);
            } catch (\Throwable $e) {
                \Illuminate\Support\Facades\Log::warning('Could not delete support files', ['error' => $e->getMessage()]);
            }
        });
    }
}
