<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

// ชุดไฟล์ธีม 1 เวอร์ชัน: manifest = pack.json (ข้อมูลล้วน) ไฟล์อยู่ใน resources/themes/packs
class ThemeVersion extends Model
{
    protected $fillable = ['theme_id', 'version', 'format', 'min_app_build', 'manifest', 'total_bytes'];

    protected function casts(): array
    {
        return ['manifest' => 'array'];
    }

    public function theme(): BelongsTo
    {
        return $this->belongsTo(Theme::class);
    }
}
