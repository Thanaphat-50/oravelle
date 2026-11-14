<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

// เหตุการณ์จากผู้ให้บริการชำระเงิน (unique provider + event_key → รับซ้ำไม่ประมวลผลซ้ำ)
class ThemeBillingEvent extends Model
{
    protected $fillable = ['provider', 'event_key', 'type', 'token_hash', 'payload', 'result', 'processed_at'];

    protected function casts(): array
    {
        return [
            'payload' => 'array',
            'processed_at' => 'datetime',
        ];
    }
}
