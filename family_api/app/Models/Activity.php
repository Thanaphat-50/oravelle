<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;

class Activity extends Model
{
    use HasFactory;

    protected $fillable = [
        'user_id',
        'family_id',
        'visibility',
        'title',
        'description',
        'activity_date',
        // ช่วงเวลาจริง (UTC) + เขตเวลา IANA ของกิจกรรม — กิจกรรมเดิมเป็น NULL (ไม่ทราบเขตเวลา)
        'starts_at',
        'timezone',
        'is_completed',
    ];

    protected $casts = [
        // วันเวลาตามนาฬิกาในเครื่องผู้ใช้ (ไม่มีเขตเวลา) ส่งกลับแบบเดียวกับที่แอปส่งมา
        // เดิมส่งกลับเป็น UTC (มี Z) แอปเลยบวกเวลาเพิ่มตามเขตเวลาเครื่อง (ไทย +7 ชั่วโมง)
        'activity_date' => 'datetime:Y-m-d\TH:i:s',
        'is_completed' => 'boolean',
        'starts_at' => 'datetime',
    ];

    // =====================================================
    // เจ้าของกิจกรรม
    // =====================================================

    public function user()
    {
        return $this->belongsTo(User::class);
    }

    // =====================================================
    // ครอบครัวที่กิจกรรมถูกแชร์ให้
    // private จะเป็น NULL
    // =====================================================

    public function family()
    {
        return $this->belongsTo(Family::class);
    }

    // =====================================================
    // Helpers
    // =====================================================

    // ส่งให้แอป: ผู้สร้างมีแค่ id ชื่อ และรูป
    // (สมาชิกในกลุ่มเห็นกิจกรรมที่แชร์ ไม่ต้องเห็นอีเมลหรือข้อมูลบัญชีของผู้สร้าง)
    public function toArray()
    {
        if ($this->relationLoaded('user') && $this->user) {
            $this->user->setVisible(['id', 'name', 'profile_image_url', 'profile_photo_url']);
        }

        return parent::toArray();
    }

    public function reminders()
    {
        return $this->hasMany(ActivityReminder::class);
    }

    // เห็นกิจกรรมนี้ได้ไหม: เจ้าของ / สมาชิกปัจจุบันของกลุ่มที่แชร์ (ตรวจทั้งตอนตั้งเตือนและก่อนส่ง)
    public function isVisibleTo(int $userId): bool
    {
        if ((int) $this->user_id === $userId) {
            return true;
        }

        return $this->visibility === 'family'
            && $this->family_id !== null
            && FamilyMember::where('user_id', $userId)->where('family_id', $this->family_id)->exists();
    }

    // ตั้งเตือนได้เมื่อรู้ช่วงเวลาจริง (กิจกรรมเดิมต้องให้เจ้าของยืนยันวันเวลาก่อน)
    public function canRemind(): bool
    {
        return $this->starts_at !== null && !$this->is_completed;
    }

    public function isPrivate(): bool
    {
        return $this->visibility === 'private';
    }

    public function isFamilyVisible(): bool
    {
        return $this->visibility === 'family';
    }
}