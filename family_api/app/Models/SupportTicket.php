<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Str;

// =======================================================
// คำร้องในศูนย์ช่วยเหลือ (ผู้ใช้แจ้ง → ทีมงานตอบใน /admin)
// สถานะ: submitted (ส่งแล้ว) → in_review (กำลังตรวจสอบ) ⇄ waiting_user (รอข้อมูลเพิ่มเติม) → closed (ปิดเรื่อง)
// ผู้ใช้เห็นได้เฉพาะคำร้องของตัวเอง ร้านค้าไม่เห็นคำร้องที่ผู้ซื้อแจ้ง
// การแจ้งปัญหาไม่เปลี่ยนสถานะคำสั่งซื้อหรือการคืนเงิน (ทีมงานตรวจแล้วดำเนินการเอง)
// เปลี่ยนสถานะ / ตอบ / ปิดเรื่อง → App\Services\SupportDesk
// =======================================================

class SupportTicket extends Model
{
    public const STATUS_SUBMITTED = 'submitted';
    public const STATUS_IN_REVIEW = 'in_review';
    public const STATUS_WAITING_USER = 'waiting_user';
    public const STATUS_CLOSED = 'closed';

    public const STATUS_LABELS = [
        self::STATUS_SUBMITTED => 'ส่งแล้ว',
        self::STATUS_IN_REVIEW => 'กำลังตรวจสอบ',
        self::STATUS_WAITING_USER => 'รอข้อมูลเพิ่มเติม',
        self::STATUS_CLOSED => 'ปิดเรื่อง',
    ];

    public const CATEGORY_LABELS = [
        'account' => 'บัญชี',
        'app' => 'การใช้งานแอป',
        'order' => 'คำสั่งซื้อ',
        'refund' => 'คืนเงิน',
        'other' => 'อื่น ๆ',
    ];

    // รูปแนบต่อข้อความ / ขนาด / ชนิด (แอปแสดงข้อจำกัดเดียวกันนี้)
    public const MAX_IMAGES = 4;
    public const MAX_IMAGE_KB = 5120;
    public const IMAGE_MIMES = ['jpg', 'jpeg', 'png', 'webp'];

    protected $fillable = [
        'code',
        'user_id',
        'category',
        'subject',
        'order_id',
        'order_code',
        'previous_ticket_id',
        'status',
        'client_id',
        'resolution',
        'closed_at',
        'last_activity_at',
    ];

    protected $casts = [
        'closed_at' => 'datetime',
        'last_activity_at' => 'datetime',
    ];

    public function user()
    {
        return $this->belongsTo(User::class);
    }

    public function order()
    {
        return $this->belongsTo(Order::class);
    }

    public function previousTicket()
    {
        return $this->belongsTo(self::class, 'previous_ticket_id');
    }

    public function messages()
    {
        return $this->hasMany(SupportMessage::class, 'ticket_id')->orderBy('id');
    }

    // ข้อความที่ผู้ใช้เห็น (ไม่รวมบันทึกภายในทีมงาน)
    public function publicMessages()
    {
        return $this->messages()->where('is_internal', false);
    }

    public function attachments()
    {
        return $this->hasMany(SupportAttachment::class, 'ticket_id');
    }

    public function events()
    {
        return $this->hasMany(SupportTicketEvent::class, 'ticket_id')->orderBy('id');
    }

    public function scopeOpen(Builder $query): Builder
    {
        return $query->where('status', '!=', self::STATUS_CLOSED);
    }

    public function isClosed(): bool
    {
        return $this->status === self::STATUS_CLOSED;
    }

    public function statusLabel(): string
    {
        return self::STATUS_LABELS[$this->status] ?? $this->status;
    }

    public function categoryLabel(): string
    {
        return self::CATEGORY_LABELS[$this->category] ?? $this->category;
    }

    // HT + ปีเดือนวัน + 5 ตัว (ไม่มี 0/O/1/I ที่สับสน) เช่น HT261109K7Q2M
    public static function newCode(): string
    {
        $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

        do {
            $suffix = collect(range(1, 5))
                ->map(fn () => $alphabet[random_int(0, strlen($alphabet) - 1)])
                ->join('');

            $code = 'HT' . now('Asia/Bangkok')->format('ymd') . $suffix;
        } while (self::where('code', $code)->exists());

        return $code;
    }

    // ข้อมูลสรุปที่ผู้ใช้เห็น (รายการ / หัวหน้ารายละเอียด)
    public function summaryPayload(): array
    {
        return [
            'id' => $this->id,
            'code' => $this->code,
            'category' => $this->category,
            'category_label' => $this->categoryLabel(),
            'subject' => $this->subject,
            'status' => $this->status,
            'status_label' => $this->statusLabel(),
            'order' => $this->order_code ? [
                'id' => $this->order_id,
                'code' => $this->order_code,
            ] : null,
            'previous_ticket' => $this->previousTicket ? [
                'id' => $this->previousTicket->id,
                'code' => $this->previousTicket->code,
            ] : null,
            'can_reply' => !$this->isClosed(),
            'resolution' => $this->isClosed() ? $this->resolution : null,
            'closed_at' => $this->closed_at?->toIso8601String(),
            'created_at' => $this->created_at?->toIso8601String(),
            'updated_at' => ($this->last_activity_at ?? $this->updated_at)?->toIso8601String(),
        ];
    }

    public static function normalizeSubject(string $subject): string
    {
        return Str::limit(trim(preg_replace('/\s+/u', ' ', $subject)), 120, '');
    }
}
