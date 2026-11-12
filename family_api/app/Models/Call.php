<?php

namespace App\Models;

use App\Support\CallSignals;
use Illuminate\Database\Eloquent\Model;

// =======================================================
// สายโทร 1 ต่อ 1 ในแชทส่วนตัว / ร้านค้า (เสียงและวิดีโอผ่าน LiveKit ไม่ผ่าน Laravel)
// ringing → accepted → ended
// ringing → declined (ผู้รับปฏิเสธ) / cancelled (ผู้โทรยกเลิก) / missed (ไม่รับใน RING_SECONDS)
// busy   = ผู้รับมีสายอื่นอยู่ (ไม่เรียกเข้า)
// failed = หมดสิทธิ์ / ถูกบล็อก / เซสชันถูกเพิกถอน / สัญญาณหายนานเกิน STALE_SECONDS
// สถานะที่จบแล้วไม่ย้อนกลับ: อัปเดตแบบมีเงื่อนไข → กดพร้อมกัน/เหตุการณ์ซ้ำ/แจ้งเตือนช้าไม่ทำให้สายเก่ากลับมา
// =======================================================

class Call extends Model
{
    public const RING_SECONDS = 45;

    public const STALE_SECONDS = 60;

    public const ACTIVE = ['ringing', 'accepted'];

    protected $fillable = [
        'conversation_id',
        'caller_id',
        'callee_id',
        'type',
        'status',
        'room',
        'caller_token_id',
        'callee_token_id',
        'ring_expires_at',
        'accepted_at',
        'ended_at',
        'last_seen_at',
        'end_reason',
    ];

    protected $hidden = [
        'room',
    ];

    protected $casts = [
        'ring_expires_at' => 'datetime',
        'accepted_at' => 'datetime',
        'ended_at' => 'datetime',
        'last_seen_at' => 'datetime',
    ];

    public function conversation()
    {
        return $this->belongsTo(Conversation::class);
    }

    public function caller()
    {
        return $this->belongsTo(User::class, 'caller_id');
    }

    public function callee()
    {
        return $this->belongsTo(User::class, 'callee_id');
    }

    public function isParticipant(int $userId): bool
    {
        return $userId === (int) $this->caller_id || $userId === (int) $this->callee_id;
    }

    public function otherId(int $userId): int
    {
        return $userId === (int) $this->caller_id ? (int) $this->callee_id : (int) $this->caller_id;
    }

    public function isActive(): bool
    {
        return in_array($this->status, self::ACTIVE, true);
    }

    // ถึงเวลาแล้ว: เรียกเข้านานเกิน → ไม่รับสาย / คุยอยู่แต่ไม่มีสัญญาณจากทั้งสองฝ่าย → สายหลุด
    public function settle(): self
    {
        if ($this->status === 'ringing' && $this->ring_expires_at?->isPast()) {
            $this->finish('missed', 'no_answer');
        } elseif ($this->status === 'accepted'
            && ($this->last_seen_at ?? $this->accepted_at)?->lt(now()->subSeconds(self::STALE_SECONDS))) {
            $this->finish('failed', 'connection_lost');
        }

        return $this;
    }

    // จบสาย (เฉพาะสายที่ยังไม่จบ) → ปิดห้อง LiveKit + แจ้งเตือนที่เกี่ยวข้อง / คืน true ถ้าเปลี่ยนจริง
    public function finish(string $status, string $reason): bool
    {
        $changed = static::whereKey($this->id)
            ->whereIn('status', self::ACTIVE)
            ->update([
                'status' => $status,
                'end_reason' => $reason,
                'ended_at' => now(),
                'updated_at' => now(),
            ]) > 0;

        $this->refresh();

        if ($changed) {
            CallSignals::finished($this);
        }

        return $changed;
    }

    // บล็อกกัน → ยุติสายที่ค้างอยู่ระหว่างสองคนนี้ทันที
    public static function endBetween(int $a, int $b, string $reason): void
    {
        static::whereIn('status', self::ACTIVE)
            ->where(fn ($calls) => $calls
                ->where(fn ($pair) => $pair->where('caller_id', $a)->where('callee_id', $b))
                ->orWhere(fn ($pair) => $pair->where('caller_id', $b)->where('callee_id', $a)))
            ->get()
            ->each(fn (Call $call) => $call->finish('failed', $reason));
    }

    // เซสชันถูกเพิกถอน → สายที่เริ่ม/รับด้วยเซสชันนั้นจบทันที
    public static function endForSessions(array $tokenIds): void
    {
        if ($tokenIds === []) {
            return;
        }

        static::whereIn('status', self::ACTIVE)
            ->where(fn ($calls) => $calls->whereIn('caller_token_id', $tokenIds)->orWhereIn('callee_token_id', $tokenIds))
            ->get()
            ->each(fn (Call $call) => $call->finish('failed', 'session_revoked'));
    }
}
