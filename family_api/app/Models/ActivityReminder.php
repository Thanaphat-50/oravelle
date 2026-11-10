<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;
use Throwable;

// =======================================================
// แจ้งเตือนกิจกรรมล่วงหน้า (ของแต่ละคน: 1 คน 1 ค่าต่อกิจกรรม)
//
// offset_minutes: 0 = ตรงเวลา / 15 / 30 / 1440 (ก่อน 1 วัน)
// remind_at (UTC) = activities.starts_at - offset
// version: เพิ่มทุกครั้งที่กำหนดเปลี่ยน → การส่งตรวจ version ล่าสุด กำหนดเก่าไม่ส่ง
//
// ส่ง: php artisan activities:send-reminders (Scheduler)
// - ล็อกแถว + ตรวจสถานะ/version/สิทธิ์/กิจกรรมยังไม่เสร็จ ก่อนส่ง → รายการแจ้งเตือนในแอป 1 รายการ
//   (Push เดิมส่งทุกเครื่องที่ผูกกับบัญชี ไม่สร้างรายการซ้ำตามจำนวนเครื่อง)
// - ช้ากว่ากำหนดเกิน GRACE_MINUTES → expired ไม่ส่ง (ไม่ส่งการเตือนเก่าค้างจำนวนมาก)
// - ข้อความไม่มีชื่อ/รายละเอียดกิจกรรม (หน้าจอล็อก)
// =======================================================

class ActivityReminder extends Model
{
    public const STATUS_PENDING = 'pending';
    public const STATUS_SENT = 'sent';
    public const STATUS_CANCELLED = 'cancelled';
    public const STATUS_EXPIRED = 'expired';
    public const STATUS_PAUSED = 'paused';

    public const OFFSETS = [
        0 => 'ตรงเวลา',
        15 => 'ก่อน 15 นาที',
        30 => 'ก่อน 30 นาที',
        1440 => 'ก่อน 1 วัน',
    ];

    // ส่งช้ากว่ากำหนดได้ไม่เกินเท่านี้ (Scheduler ปิด/ล่ม แล้วกลับมา → ไม่ส่งของเก่า)
    public const GRACE_MINUTES = 15;

    protected $fillable = [
        'activity_id',
        'user_id',
        'offset_minutes',
        'remind_at',
        'version',
        'status',
        'sent_at',
    ];

    protected $casts = [
        'offset_minutes' => 'integer',
        'version' => 'integer',
        'remind_at' => 'datetime',
        'sent_at' => 'datetime',
    ];

    public function activity()
    {
        return $this->belongsTo(Activity::class);
    }

    public function user()
    {
        return $this->belongsTo(User::class);
    }

    public static function remindAtFor(Activity $activity, int $offset): ?Carbon
    {
        return $activity->starts_at?->copy()->subMinutes($offset);
    }

    // ข้อมูลที่ผู้ใช้เห็น (ค่าของตัวเอง)
    public function payload(): array
    {
        return [
            'offset_minutes' => $this->offset_minutes,
            'label' => self::OFFSETS[$this->offset_minutes] ?? null,
            'remind_at' => $this->remind_at?->toIso8601String(),
            'status' => $this->status,
        ];
    }

    // =====================================================
    // ตั้ง / คำนวณใหม่ / ยกเลิก
    // =====================================================

    // ตั้งเตือนของผู้ใช้คนนี้ (null = ไม่เตือน) — ผู้เรียกตรวจสิทธิ์และเวลาในอนาคตแล้ว
    public static function setFor(Activity $activity, User $user, ?int $offset): ?self
    {
        $existing = self::where('activity_id', $activity->id)->where('user_id', $user->id)->first();

        if ($offset === null) {
            $existing?->forceFill(['status' => self::STATUS_CANCELLED, 'version' => $existing->version + 1])->save();

            return null;
        }

        $values = [
            'offset_minutes' => $offset,
            'remind_at' => self::remindAtFor($activity, $offset),
            'status' => self::STATUS_PENDING,
            'sent_at' => null,
        ];

        if ($existing) {
            $existing->forceFill([...$values, 'version' => $existing->version + 1])->save();

            return $existing;
        }

        return self::create([...$values, 'activity_id' => $activity->id, 'user_id' => $user->id, 'version' => 1]);
    }

    // เวลา/สถานะกิจกรรมเปลี่ยน → คำนวณกำหนดของทุกคนใหม่
    // - เสร็จแล้ว / ไม่มีเวลาแน่นอน → ยกเลิกที่ยังไม่ส่ง
    // - กลับเป็นยังไม่เสร็จ → ตั้งใหม่เฉพาะที่ยังอยู่ในอนาคต (ที่ส่งแล้วของกำหนดเดิมไม่ส่งซ้ำ)
    // paused = พักไว้เพราะกิจกรรมเสร็จแล้ว / ล้างวันเวลา (ผู้ใช้ยังเลือกเตือนไว้)
    public static function reschedule(Activity $activity, bool $timeChanged): void
    {
        $statuses = $timeChanged
            ? [self::STATUS_PENDING, self::STATUS_SENT, self::STATUS_EXPIRED, self::STATUS_PAUSED]
            : [self::STATUS_PENDING, self::STATUS_PAUSED];

        foreach (self::where('activity_id', $activity->id)->whereIn('status', $statuses)->get() as $reminder) {
            // เสร็จแล้ว / ไม่มีเวลาแน่นอน → พัก (ยกเลิกที่ยังไม่ส่ง)
            if ($activity->is_completed || $activity->starts_at === null) {
                if ($timeChanged || $reminder->status === self::STATUS_PENDING) {
                    $reminder->forceFill(['status' => self::STATUS_PAUSED, 'version' => $reminder->version + 1])->save();
                }

                continue;
            }

            // ยังไม่เสร็จ: เวลาเปลี่ยน หรือเพิ่งกลับมาจากพัก → คำนวณใหม่
            // อยู่ในอนาคต → pending / ผ่านไปแล้ว → expired (ไม่ส่งย้อนหลัง ไม่ส่งรอบเดิมซ้ำ)
            if (!$timeChanged && $reminder->status !== self::STATUS_PAUSED) {
                continue;
            }

            $remindAt = self::remindAtFor($activity, $reminder->offset_minutes);

            $reminder->forceFill([
                'remind_at' => $remindAt,
                'status' => $remindAt->isFuture() ? self::STATUS_PENDING : self::STATUS_EXPIRED,
                'sent_at' => $timeChanged ? null : $reminder->sent_at,
                'version' => $reminder->version + 1,
            ])->save();
        }
    }

    // ผู้ใช้หมดสิทธิ์เห็นกิจกรรม (ออกจากกลุ่ม / ถูกนำออก / เปลี่ยนเป็นส่วนตัว) → ยกเลิก
    public static function revokeLostAccess(): int
    {
        $count = 0;

        self::where('status', self::STATUS_PENDING)
            ->with('activity')
            ->chunkById(200, function ($reminders) use (&$count) {
                foreach ($reminders as $reminder) {
                    if (!$reminder->activity || !$reminder->activity->isVisibleTo($reminder->user_id)) {
                        $reminder->forceFill(['status' => self::STATUS_CANCELLED, 'version' => $reminder->version + 1])->save();
                        $count++;
                    }
                }
            });

        return $count;
    }

    // =====================================================
    // ส่ง (activities:send-reminders)
    // คืน ['sent' => n, 'expired' => n, 'cancelled' => n]
    // =====================================================

    public static function sendDue(?Carbon $now = null, int $limit = 500): array
    {
        $now ??= now();
        $result = ['sent' => 0, 'expired' => 0, 'cancelled' => 0];

        $due = self::where('status', self::STATUS_PENDING)
            ->where('remind_at', '<=', $now)
            ->orderBy('remind_at')
            ->limit($limit)
            ->get(['id', 'version']);

        foreach ($due as $row) {
            try {
                $outcome = self::sendOne($row->id, $row->version, $now);
            } catch (Throwable $e) {
                // ล้มกลางทาง → ยังเป็น pending รอบหน้าลองใหม่ (รายการแจ้งเตือนสร้างใน transaction เดียวกัน ไม่ซ้ำ)
                Log::error('Activity reminder failed', ['reminder_id' => $row->id, 'error' => $e->getMessage()]);

                continue;
            }

            if ($outcome !== null) {
                $result[$outcome]++;
            }
        }

        return $result;
    }

    // ล็อกแถว ตรวจทุกอย่างอีกครั้ง แล้วส่ง (หลาย worker / รันซ้อน → ส่งครั้งเดียว)
    private static function sendOne(int $id, int $version, Carbon $now): ?string
    {
        return DB::transaction(function () use ($id, $version, $now) {
            $reminder = self::whereKey($id)->lockForUpdate()->first();

            // คนอื่นส่ง/เปลี่ยนไปแล้ว หรือกำหนดเปลี่ยน (version ใหม่)
            if (!$reminder || $reminder->status !== self::STATUS_PENDING || $reminder->version !== $version) {
                return null;
            }

            $activity = Activity::find($reminder->activity_id);

            $stillValid = $activity
                && !$activity->is_completed
                && $activity->starts_at !== null
                && $reminder->remind_at?->equalTo(self::remindAtFor($activity, $reminder->offset_minutes))
                && $activity->isVisibleTo($reminder->user_id);

            if (!$stillValid) {
                $reminder->forceFill(['status' => self::STATUS_CANCELLED])->save();

                return 'cancelled';
            }

            if ($reminder->remind_at->lt($now->copy()->subMinutes((int) config('reminders.grace_minutes', self::GRACE_MINUTES)))) {
                $reminder->forceFill(['status' => self::STATUS_EXPIRED])->save();

                return 'expired';
            }

            $reminder->forceFill(['status' => self::STATUS_SENT, 'sent_at' => $now])->save();

            AppNotification::create([
                'user_id' => $reminder->user_id,
                'family_id' => null,
                'type' => 'activity_reminder',
                'title' => 'เตือนกิจกรรม',
                'message' => self::message($reminder->offset_minutes),
                'data' => ['activity_id' => $activity->id],
                'is_read' => false,
            ]);

            return 'sent';
        });
    }

    // ไม่มีชื่อ/รายละเอียดกิจกรรม (แสดงบนหน้าจอล็อก)
    public static function message(int $offset): string
    {
        return match ($offset) {
            0 => 'กิจกรรมของคุณถึงเวลาแล้ว · แตะเพื่อดูรายละเอียด',
            1440 => 'กิจกรรมของคุณจะเริ่มในอีก 1 วัน · แตะเพื่อดูรายละเอียด',
            default => "กิจกรรมของคุณจะเริ่มในอีก {$offset} นาที · แตะเพื่อดูรายละเอียด",
        };
    }
}
