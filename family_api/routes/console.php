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
// ทุกนาที: รอบก่อนยังไม่เสร็จ → ข้ามรอบนี้ (withoutOverlapping) และรันเครื่องเดียว (onOneServer)
// ใช้ lock จาก Cache (CACHE_STORE=database) ถึงรันซ้อนก็ไม่ยกเลิกซ้ำ เพราะล็อกแถวคำสั่งซื้ออีกชั้น
// ต้องเปิด Scheduler บน Laravel Cloud ถึงจะทำงาน (ยังไม่เปิด → หน้าคำสั่งซื้อยังตรวจให้ตอนเปิดดู)
Schedule::command('orders:expire')
    ->everyMinute()
    ->withoutOverlapping(10)
    ->onOneServer();
