<?php

use App\Models\AppNotification;
use Illuminate\Foundation\Inspiring;
use Illuminate\Support\Facades\Artisan;
use Illuminate\Support\Facades\Schedule;

Artisan::command('inspire', function () {
    $this->comment(Inspiring::quote());
})->purpose('Display an inspiring quote');

// ลบ Token ที่หมดอายุแล้วเกิน 24 ชั่วโมงออกจากฐานข้อมูลทุกวัน
// (ทำงานเมื่อเปิด Scheduler บน Laravel Cloud)
Schedule::command('sanctum:prune-expired --hours=24')->daily();

// ลบการแจ้งเตือนที่อ่านแล้วและเก่ากว่า 90 วัน (AppNotification::prunable)
Schedule::command('model:prune', ['--model' => [AppNotification::class]])->daily();

// คำสั่งซื้อเลยเวลาชำระ → ยกเลิก + คืนสต็อก / ส่งแล้วครบกำหนด → ยืนยันรับสินค้า (App\Console\Commands\ExpireOrders)
// ทุกชั่วโมง (ไม่ใช่ทุกนาที): Laravel Cloud เปิด Scale to zero ไว้ ถ้ารันถี่ Scheduler จะปลุกแอปจนไม่ได้หลับ
// เวลาชำระมี 24 ชั่วโมง → คืนสต็อกช้าไปไม่เกิน 1 ชั่วโมง และหน้าคำสั่งซื้อยังยกเลิกให้ทันทีตอนมีคนเปิดดู
// รอบก่อนยังไม่เสร็จ → ข้ามรอบนี้ (withoutOverlapping) และรันเครื่องเดียว (onOneServer)
// ใช้ lock จาก Cache (CACHE_STORE=database) ถึงรันซ้อนก็ไม่ยกเลิกซ้ำ เพราะล็อกแถวคำสั่งซื้ออีกชั้น
// ต้องเปิด Scheduler บน Laravel Cloud ถึงจะทำงาน
Schedule::command('orders:expire')
    ->hourly()
    ->withoutOverlapping(10)
    ->onOneServer();

// แจ้งเตือนกิจกรรมล่วงหน้า (App\Console\Commands\SendActivityReminders)
// ทุก ACTIVITY_REMINDER_EVERY_MINUTES นาที (ค่าเริ่มต้น 5) แยกจากงานคำสั่งซื้อรายชั่วโมง
// ⚠️ Scale to zero: Scheduler ปลุกแอปทุกรอบ → รอบ 5 นาทีทำให้แอปแทบไม่ได้หลับ (ค่าเครื่องใกล้เต็มเดือน)
//    รอบยาวขึ้น = ประหยัดขึ้นแต่เตือนช้าได้ถึงเท่ารอบ (ดู docs/activity-reminders.md)
Schedule::command('activities:send-reminders')
    ->cron('*/' . config('reminders.every_minutes') . ' * * * *')
    ->withoutOverlapping(10)
    ->onOneServer();
