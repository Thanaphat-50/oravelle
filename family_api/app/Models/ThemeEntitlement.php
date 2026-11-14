<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

// สิทธิ์ใช้ธีมของบัญชี (ซิงก์ตามบัญชี ไม่ใช่ตามเครื่อง) — เพิกถอนแล้วเก็บเหตุผลไว้แจ้งผู้ใช้
class ThemeEntitlement extends Model
{
    protected $fillable = ['user_id', 'theme_id', 'purchase_id', 'source', 'granted_at', 'revoked_at', 'revoke_reason'];

    protected function casts(): array
    {
        return [
            'granted_at' => 'datetime',
            'revoked_at' => 'datetime',
        ];
    }

    public function theme(): BelongsTo
    {
        return $this->belongsTo(Theme::class);
    }

    public function purchase(): BelongsTo
    {
        return $this->belongsTo(ThemePurchase::class, 'purchase_id');
    }

    public function isActive(): bool
    {
        return $this->revoked_at === null;
    }
}
