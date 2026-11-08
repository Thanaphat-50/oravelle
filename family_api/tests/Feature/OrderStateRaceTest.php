<?php

namespace Tests\Feature;

use App\Models\AppNotification;
use App\Models\Order;
use App\Models\OrderCheckout;
use App\Models\OrderStatusHistory;
use App\Models\PaymentTransaction;
use App\Models\Product;
use App\Models\Shop;
use App\Models\User;
use App\Services\SlipVerifier;
use App\Support\MediaStorage;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Storage;
use Laravel\Sanctum\Sanctum;
use Tests\Concerns\FakesImages;
use Tests\TestCase;

// =======================================================
// การเปลี่ยนสถานะที่ชนกัน (จำลองลำดับเหตุการณ์ใน process เดียว)
// คำขอพร้อมกันจริงหลาย process อยู่ใน OrderConcurrencyTest
// =======================================================

class OrderStateRaceTest extends TestCase
{
    use FakesImages, RefreshDatabase;

    private User $seller;
    private Shop $shop;
    private Product $product;
    private User $buyer;

    protected function setUp(): void
    {
        parent::setUp();

        Storage::fake(MediaStorage::disk());

        $this->seller = User::factory()->create();

        $this->shop = Shop::create([
            'user_id' => $this->seller->id,
            'name' => 'ร้านทดสอบ',
            'category' => 'produce',
            'phone' => '0812345678',
            'province' => 'เชียงใหม่',
            'status' => Shop::STATUS_ACTIVE,
            'terms_accepted_at' => now(),
            'delivery_methods' => ['shipping', 'storefront'],
            'payment_methods' => ['promptpay', 'cod', 'cash'],
            'promptpay_id' => '0899999999',
        ]);

        $this->product = $this->shop->products()->create([
            'title' => 'มะม่วง',
            'price' => 100,
            'stock' => 10,
            'shipping_fee' => 40,
            'category' => 'produce',
            'status' => Product::STATUS_ACTIVE,
        ]);

        $this->buyer = User::factory()->create();
    }

    private function placeOrder(string $payment = 'cash', int $quantity = 3): Order
    {
        return DB::transaction(fn () => Order::placeGroup($this->buyer, $this->shop, [[
            'product' => $this->product,
            'variant' => null,
            'quantity' => $quantity,
            'unit_price' => 100.0,
        ]], [
            'delivery_method' => 'storefront',
            'payment_method' => $payment,
            'recipient_name' => 'คุณแม่',
            'recipient_phone' => '0811112222',
        ]));
    }

    private function histories(Order $order, string $status): int
    {
        return OrderStatusHistory::where('order_id', $order->id)->where('status', $status)->count();
    }

    public function test_second_cancel_from_a_stale_copy_does_nothing(): void
    {
        $order = $this->placeOrder();

        // 2 คำขอโหลดคำสั่งซื้อไว้ก่อนอีกคำขอยกเลิก
        $first = Order::findOrFail($order->id);
        $second = Order::findOrFail($order->id);

        $this->assertTrue($first->cancel(Order::BY_BUYER, 'เปลี่ยนใจ'));
        $this->assertFalse($second->cancel(Order::BY_SELLER, 'ของหมด'));

        $this->assertSame(10, $this->product->refresh()->stock);
        $this->assertSame(1, $this->histories($order, Order::STATUS_CANCELLED));
        $this->assertSame(Order::BY_BUYER, $order->refresh()->cancelled_by);
        $this->assertSame(1, AppNotification::where('title', 'คำสั่งซื้อถูกยกเลิก')->count());
    }

    public function test_ship_after_cancel_is_refused_and_keeps_stock_restored(): void
    {
        $order = $this->placeOrder();

        $stale = Order::findOrFail($order->id);

        $this->assertTrue($order->cancel(Order::BY_BUYER, null));
        $this->assertFalse($stale->ship(null, null));

        $this->assertSame(Order::STATUS_CANCELLED, $order->refresh()->status);
        $this->assertNull($order->shipped_at);
        $this->assertSame(10, $this->product->refresh()->stock);
        $this->assertSame(0, $this->histories($order, Order::STATUS_SHIPPED));
    }

    public function test_api_returns_409_when_the_status_changed_after_the_check(): void
    {
        $order = $this->placeOrder();

        // ผู้ซื้อยกเลิกไปก่อน (อีกคำขอ) → ร้านกดส่งสินค้าจากหน้าที่เปิดค้างไว้
        Order::findOrFail($order->id)->cancel(Order::BY_BUYER, null);

        Sanctum::actingAs($this->seller);

        $this->postJson("/api/orders/{$order->id}/ship")
            ->assertConflict()
            ->assertJsonPath('order.status', Order::STATUS_CANCELLED);
    }

    public function test_slip_checked_while_the_order_expires_goes_to_refund(): void
    {
        $order = $this->placeOrder('promptpay', 2);

        $this->assertSame(8, $this->product->refresh()->stock);

        // ระหว่างรอผลตรวจสลิป งานตามเวลายกเลิกคำสั่งซื้อที่เลยเวลาชำระ แล้วสลิปผ่าน
        $this->app->instance(SlipVerifier::class, new class extends SlipVerifier
        {
            public function check(string $contents, string $filename, Order $order): array
            {
                Order::whereKey($order->id)->update(['payment_due_at' => now()->subMinute()]);
                Order::expireStale();

                return [
                    'status' => PaymentTransaction::STATUS_VERIFIED,
                    'provider' => 'easyslip',
                    'reason' => null,
                    'trans_ref' => 'TX-LATE',
                    'slip_amount' => (float) $order->total,
                    'slip_date' => now(),
                    'receiver_account' => null,
                ];
            }
        });

        Sanctum::actingAs($this->buyer);

        $this->post("/api/orders/{$order->id}/slip", ['slip' => $this->fakePng('slip.png')], ['Accept' => 'application/json'])
            ->assertConflict()
            ->assertJsonPath('code', 'order_cancelled')
            ->assertJsonPath('order.status', Order::STATUS_CANCELLED)
            ->assertJsonPath('order.refund_status', Order::REFUND_PENDING);

        $order->refresh();

        // ยกเลิกครั้งเดียว คืนสต็อกครั้งเดียว เก็บหลักฐานการโอน ร้านต้องคืนเงิน
        $this->assertSame(Order::STATUS_CANCELLED, $order->status);
        $this->assertSame(Order::BY_SYSTEM, $order->cancelled_by);
        $this->assertSame(Order::REFUND_PENDING, $order->refund_status);
        $this->assertNotNull($order->slip_path);
        $this->assertSame(10, $this->product->refresh()->stock);
        $this->assertSame(1, PaymentTransaction::where('order_id', $order->id)->count());
        $this->assertSame(1, AppNotification::where('user_id', $this->seller->id)->where('title', 'ลูกค้าโอนเงินหลังคำสั่งซื้อถูกยกเลิก')->count());

        // ร้านเห็นปุ่มคืนเงิน
        Sanctum::actingAs($this->seller);

        $this->getJson("/api/orders/{$order->id}")->assertJsonPath('order.actions', ['refund']);
    }

    public function test_expire_command_handles_orders_nobody_opens(): void
    {
        $unpaid = $this->placeOrder('promptpay', 2);
        $unpaid->forceFill(['payment_due_at' => now()->subMinute()])->save();

        $delivered = $this->placeOrder('cash', 1);
        $delivered->forceFill(['status' => Order::STATUS_SHIPPED, 'shipped_at' => now()->subDays(8)])->save();

        $waiting = $this->placeOrder('promptpay', 1);

        $this->assertSame(6, $this->product->refresh()->stock);

        $this->artisan('orders:expire')->assertSuccessful();

        $this->assertSame(Order::STATUS_CANCELLED, $unpaid->refresh()->status);
        $this->assertSame(Order::STATUS_COMPLETED, $delivered->refresh()->status);
        $this->assertSame(Order::STATUS_AWAITING_PAYMENT, $waiting->refresh()->status);
        $this->assertSame(8, $this->product->refresh()->stock);

        $notifications = AppNotification::count();

        // รอบถัดไป (หรือรันซ้อน) ไม่ทำซ้ำ
        $this->artisan('orders:expire')->assertSuccessful();

        $this->assertSame(8, $this->product->refresh()->stock);
        $this->assertSame(1, $this->histories($unpaid, Order::STATUS_CANCELLED));
        $this->assertSame(1, $this->histories($delivered, Order::STATUS_COMPLETED));
        $this->assertSame($notifications, AppNotification::count());
    }

    public function test_expire_command_works_in_batches(): void
    {
        for ($i = 0; $i < 5; $i++) {
            $this->placeOrder('promptpay', 1);
        }

        Order::query()->update(['payment_due_at' => now()->subMinute()]);

        $this->artisan('orders:expire', ['--batch' => 2])->assertSuccessful();

        $this->assertSame(0, Order::where('status', Order::STATUS_AWAITING_PAYMENT)->count());
        $this->assertSame(10, $this->product->refresh()->stock);
    }

    public function test_expiry_is_scheduled_without_overlap(): void
    {
        $this->artisan('schedule:list')
            ->expectsOutputToContain('orders:expire')
            ->assertSuccessful();

        $event = collect(app(\Illuminate\Console\Scheduling\Schedule::class)->events())
            ->first(fn ($event) => str_contains((string) $event->command, 'orders:expire'));

        $this->assertNotNull($event);
        $this->assertSame('0 * * * *', $event->expression);
        $this->assertTrue($event->withoutOverlapping);
        $this->assertTrue($event->onOneServer);
    }

    public function test_resent_checkout_returns_the_same_orders(): void
    {
        Sanctum::actingAs($this->buyer);

        $body = [
            'checkout_id' => 'retry-after-timeout',
            'items' => [['product_id' => $this->product->id, 'quantity' => 2]],
            'groups' => [['shop_id' => $this->shop->id, 'delivery_method' => 'storefront', 'payment_method' => 'cash']],
            'recipient_name' => 'คุณแม่',
            'recipient_phone' => '0811112222',
        ];

        // แอปหมดเวลารอ แต่เซิร์ฟเวอร์บันทึกแล้ว → ส่งใหม่ด้วย checkout_id เดิม
        $first = $this->postJson('/api/orders', $body)->assertCreated()->json('orders.0.id');
        $again = $this->postJson('/api/orders', $body)->assertOk()->json('orders.0.id');

        $this->assertSame($first, $again);
        $this->assertSame(1, Order::count());
        $this->assertSame(1, OrderCheckout::count());
        $this->assertSame(8, $this->product->refresh()->stock);
        $this->assertSame(1, AppNotification::where('title', 'มีคำสั่งซื้อใหม่')->count());

        // สต็อกไม่พอ → ยกเลิกทั้งหมด ไม่ค้างรหัส checkout (ส่งใหม่ได้เมื่อแก้จำนวน)
        $failed = [...$body, 'checkout_id' => 'too-many', 'items' => [['product_id' => $this->product->id, 'quantity' => 9]]];

        $this->postJson('/api/orders', $failed)->assertStatus(409)->assertJsonPath('code', 'checkout_changed');
        $this->assertSame(1, OrderCheckout::count());

        $this->postJson('/api/orders', [...$failed, 'items' => [['product_id' => $this->product->id, 'quantity' => 1]]])
            ->assertCreated();
    }

    public function test_find_duplicates_reports_old_double_orders_without_changing_them(): void
    {
        $this->artisan('orders:find-duplicates')
            ->expectsOutput('ไม่พบคำสั่งซื้อที่อาจซ้ำ')
            ->assertSuccessful();

        // คำสั่งซื้อซ้ำที่เกิดก่อนมี order_checkouts
        $a = $this->placeOrder();
        $b = $this->placeOrder();
        Order::whereKey([$a->id, $b->id])->update(['checkout_id' => 'old-double']);

        // แอปเวอร์ชันเก่ากดสองครั้งติดกัน
        $this->placeOrder('cod', 1);
        $this->placeOrder('cod', 1);

        $this->artisan('orders:find-duplicates')
            ->expectsOutputToContain('พบ 2 กลุ่มที่อาจซ้ำ')
            ->assertSuccessful();

        $this->assertSame(4, Order::count());
        $this->assertSame(0, Order::where('status', Order::STATUS_CANCELLED)->count());
    }
}
