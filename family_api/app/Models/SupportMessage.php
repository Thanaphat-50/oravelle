<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

// ข้อความในคำร้อง: ผู้ใช้ / ทีมงาน (is_staff) / บันทึกภายใน (is_internal — ผู้ใช้ไม่เห็น ไม่แจ้งเตือน)
class SupportMessage extends Model
{
    protected $fillable = [
        'ticket_id',
        'user_id',
        'is_staff',
        'is_internal',
        'body',
        'client_id',
    ];

    protected $casts = [
        'is_staff' => 'boolean',
        'is_internal' => 'boolean',
    ];

    public function ticket()
    {
        return $this->belongsTo(SupportTicket::class, 'ticket_id');
    }

    public function author()
    {
        return $this->belongsTo(User::class, 'user_id');
    }

    public function attachments()
    {
        return $this->hasMany(SupportAttachment::class, 'message_id')->orderBy('id');
    }

    // สิ่งที่ผู้ใช้เห็น: ทีมงานแสดงเป็น "ทีมงาน ORAVELLE" (ไม่บอกชื่อเจ้าหน้าที่)
    public function userPayload(): array
    {
        return [
            'id' => $this->id,
            'from' => $this->is_staff ? 'staff' : 'me',
            'author' => $this->is_staff ? 'ทีมงาน ORAVELLE' : 'คุณ',
            'body' => $this->body,
            'client_id' => $this->is_staff ? null : $this->client_id,
            'attachments' => $this->attachments
                ->map(fn (SupportAttachment $attachment) => $attachment->payload())
                ->values(),
            'created_at' => $this->created_at?->toIso8601String(),
        ];
    }
}
