<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\HasMany;

// ธีมในร้านธีม (ข้อมูลตั้งต้นจาก resources/themes/catalog.json ผ่าน themes:sync)
class Theme extends Model
{
    public const CATEGORIES = ['simple', 'nature', 'dark'];

    protected $fillable = [
        'slug',
        'name',
        'description',
        'category',
        'is_free',
        'target_price_thb',
        'supports_light',
        'supports_dark',
        'changes',
        'previews',
        'current_version',
        'sort_order',
        'status',
    ];

    protected function casts(): array
    {
        return [
            'is_free' => 'boolean',
            'supports_light' => 'boolean',
            'supports_dark' => 'boolean',
            'changes' => 'array',
            'previews' => 'array',
        ];
    }

    public function versions(): HasMany
    {
        return $this->hasMany(ThemeVersion::class);
    }

    public function products(): HasMany
    {
        return $this->hasMany(ThemeProduct::class);
    }

    public function currentVersion(): ?ThemeVersion
    {
        if ($this->current_version < 1) {
            return null;
        }

        return $this->versions()->where('version', $this->current_version)->first();
    }

    public function productId(string $provider): ?string
    {
        return $this->products->firstWhere('provider', $provider)?->product_id;
    }
}
