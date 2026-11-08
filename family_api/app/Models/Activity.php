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
        'is_completed',
    ];

    protected $casts = [
        'activity_date' => 'datetime',
        'is_completed' => 'boolean',
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

    public function isPrivate(): bool
    {
        return $this->visibility === 'private';
    }

    public function isFamilyVisible(): bool
    {
        return $this->visibility === 'family';
    }
}