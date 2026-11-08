<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

// การกดสั่งซื้อ 1 ครั้ง (buyer_id + checkout_id ไม่ซ้ำ) — กันสร้างคำสั่งซื้อซ้ำเมื่อคำขอเดียวกันเข้าพร้อมกัน
// คำสั่งซื้อของ checkout นี้ = orders ที่มี buyer_id + checkout_id เดียวกัน (หลายร้านได้)
class OrderCheckout extends Model
{
    protected $fillable = [
        'buyer_id',
        'checkout_id',
    ];
}
