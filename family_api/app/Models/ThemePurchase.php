<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

// หลักฐานการซื้อธีม 1 ใบ (unique provider + token_hash → ใช้ซ้ำกับบัญชีอื่นไม่ได้)
class ThemePurchase extends Model
{
    public const PENDING = 'pending';
    public const PURCHASED = 'purchased';
    public const CANCELLED = 'cancelled';
    public const REFUNDED = 'refunded';
    public const REVOKED = 'revoked';

    protected $fillable = [
        'user_id',
        'theme_id',
        'provider',
        'product_id',
        'token_hash',
        'purchase_token',
        'order_id',
        'environment',
        'status',
        'purchased_at',
        'acknowledged_at',
        'verified_at',
        'revoked_at',
        'revoke_reason',
        'raw',
    ];

    protected $hidden = ['purchase_token', 'token_hash', 'raw'];

    protected function casts(): array
    {
        return [
            'purchased_at' => 'datetime',
            'acknowledged_at' => 'datetime',
            'verified_at' => 'datetime',
            'revoked_at' => 'datetime',
            'raw' => 'array',
        ];
    }

    public static function hashToken(string $token): string
    {
        return hash('sha256', $token);
    }

    public function user(): BelongsTo
    {
        return $this->belongsTo(User::class);
    }

    public function theme(): BelongsTo
    {
        return $this->belongsTo(Theme::class);
    }
}
