<?php

namespace App\Console\Commands;

use App\Models\ActivityReminder;
use Illuminate\Console\Command;

// =======================================================
// ส่งแจ้งเตือนกิจกรรมที่ถึงกำหนด (Scheduler ดู routes/console.php)
// รันซ้อน / หลายเครื่อง → ส่งครั้งเดียว (ActivityReminder ล็อกแถว + ตรวจ version)
//
// php artisan activities:send-reminders
// =======================================================

class SendActivityReminders extends Command
{
    protected $signature = 'activities:send-reminders {--limit=500 : จำนวนสูงสุดต่อรอบ}';

    protected $description = 'ส่งแจ้งเตือนกิจกรรมล่วงหน้าที่ถึงกำหนด';

    public function handle(): int
    {
        $result = ActivityReminder::sendDue(null, max(1, (int) $this->option('limit')));

        $this->info("ส่ง {$result['sent']} · หมดเวลา {$result['expired']} · ยกเลิก {$result['cancelled']}");

        return self::SUCCESS;
    }
}
