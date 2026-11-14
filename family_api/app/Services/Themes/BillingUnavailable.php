<?php

namespace App\Services\Themes;

use RuntimeException;

// ติดต่อผู้ให้บริการชำระเงินไม่ได้ชั่วคราว (ไม่ใช่หลักฐานผิด) → แอปลองใหม่ภายหลังได้ ไม่ต้องซื้อซ้ำ
class BillingUnavailable extends RuntimeException
{
}
