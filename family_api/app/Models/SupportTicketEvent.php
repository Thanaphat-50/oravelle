<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

// ประวัติคำร้อง: ใครทำอะไร เปลี่ยนสถานะจากอะไรเป็นอะไร (ทีมงานเห็นใน /admin เท่านั้น)
class SupportTicketEvent extends Model
{
    public const UPDATED_AT = null;

    public const TYPE_LABELS = [
        'created' => 'สร้างคำร้อง',
        'message' => 'ผู้ใช้ส่งข้อมูลเพิ่ม',
        'staff_reply' => 'ทีมงานตอบ',
        'internal_note' => 'บันทึกภายใน',
        'status' => 'เปลี่ยนสถานะ',
        'closed' => 'ปิดเรื่อง',
    ];

    protected $fillable = [
        'ticket_id',
        'actor_id',
        'actor_role',
        'type',
        'from_status',
        'to_status',
        'note',
    ];

    public function ticket()
    {
        return $this->belongsTo(SupportTicket::class, 'ticket_id');
    }

    public function actor()
    {
        return $this->belongsTo(User::class, 'actor_id');
    }
}
