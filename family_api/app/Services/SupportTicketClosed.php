<?php

namespace App\Services;

use RuntimeException;

// คำร้องปิดเรื่องแล้ว: ส่งข้อความเพิ่ม / ตอบ / เปลี่ยนสถานะไม่ได้ (สร้างเรื่องใหม่โดยอ้างอิงเรื่องเดิมแทน)
class SupportTicketClosed extends RuntimeException
{
    public function __construct()
    {
        parent::__construct('เรื่องนี้ปิดแล้ว สร้างเรื่องใหม่โดยอ้างอิงเรื่องนี้ได้');
    }
}
