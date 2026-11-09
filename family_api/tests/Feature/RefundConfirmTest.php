<?php

namespace Tests\Feature;

use App\Models\AppNotification;
use App\Models\Order;
use App\Models\Product;
use App\Models\Shop;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\DB;
use Laravel\Sanctum\Sanctum;
use Tests\TestCase;

// คืนเงิน 2 ขั้น: ร้านแจ้งว่าคืนเงินแล้ว → ผู้ซื้อยืนยันว่าได้รับเงินคืน
class RefundConfirmTest extends TestCase
{
    use RefreshDatabase;

    public function test_seller_reports_refund_then_buyer_confirms_it(): void
    {
        $seller = User::factory()->create();

        $shop = Shop::create([
            'user_id' => $seller->id,
            'name' => 'ร้านทดสอบ',
            'category' => 'produce',
            'phone' => '0812345678',
            'province' => 'เชียงใหม่',
            'status' => Shop::STATUS_ACTIVE,
            'terms_accepted_at' => now(),
            'delivery_methods' => ['storefront'],
            'payment_methods' => ['promptpay'],
            'promptpay_id' => '0899999999',
        ]);

        $product = $shop->products()->create([
            'title' => 'มะม่วง',
            'price' => 100,
            'stock' => 5,
            'category' => 'produce',
            'status' => Product::STATUS_ACTIVE,
        ]);

        $buyer = User::factory()->create();

        $order = DB::transaction(fn () => Order::placeGroup($buyer, $shop, [[
            'product' => $product,
            'variant' => null,
            'quantity' => 1,
            'unit_price' => 100.0,
        ]], [
            'delivery_method' => 'storefront',
            'payment_method' => 'promptpay',
            'recipient_name' => 'คุณแม่',
            'recipient_phone' => '0811112222',
        ]));

        // โอนแล้ว (รอร้านตรวจ) แล้วร้านยกเลิก → ต้องคืนเงิน
        $order->forceFill(['status' => Order::STATUS_PAYMENT_REVIEW])->save();
        $this->assertTrue($order->cancel(Order::BY_SELLER, 'ของหมด'));

        Sanctum::actingAs($buyer);

        $this->getJson("/api/orders/{$order->id}")
            ->assertJsonPath('order.status_label', 'ยกเลิกแล้ว · รอร้านคืนเงิน')
            ->assertJsonPath('order.actions', []);

        // ยังไม่ได้แจ้งคืนเงิน → ผู้ซื้อยืนยันไม่ได้
        $this->postJson("/api/orders/{$order->id}/refund-received")->assertStatus(409);

        Sanctum::actingAs($seller);

        $this->postJson("/api/orders/{$order->id}/refund", ['note' => 'โอนคืนบัญชีเดิม'])
            ->assertOk()
            ->assertJsonPath('order.status_label', 'ยกเลิกแล้ว · ร้านแจ้งว่าคืนเงินแล้ว');

        // ร้านกดยืนยันแทนผู้ซื้อไม่ได้
        $this->postJson("/api/orders/{$order->id}/refund-received")->assertStatus(409);

        Sanctum::actingAs($buyer);

        $this->getJson("/api/orders/{$order->id}")
            ->assertJsonPath('order.actions', ['confirm_refund'])
            ->assertJsonPath('order.refund_confirmed_at', null);

        $this->postJson("/api/orders/{$order->id}/refund-received")
            ->assertOk()
            ->assertJsonPath('order.status_label', 'ยกเลิกแล้ว · ผู้ซื้อได้รับเงินคืนแล้ว')
            ->assertJsonPath('order.actions', [])
            ->assertJsonPath('order.history.0.note', 'ผู้ซื้อยืนยันว่าได้รับเงินคืนแล้ว');

        $this->assertNotNull($order->refresh()->refund_confirmed_at);

        // กดซ้ำ → 409 ไม่แจ้งเตือนซ้ำ
        $this->postJson("/api/orders/{$order->id}/refund-received")->assertStatus(409);

        $this->assertSame(1, AppNotification::where('user_id', $seller->id)->where('title', 'ลูกค้าได้รับเงินคืนแล้ว')->count());
    }
}
