<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

// รหัสสินค้าของธีมในแต่ละช่องทาง (google_play / test)
class ThemeProduct extends Model
{
    protected $fillable = ['theme_id', 'provider', 'product_id'];

    public function theme(): BelongsTo
    {
        return $this->belongsTo(Theme::class);
    }
}
