<?php

namespace Tests\Feature;

use App\Models\AppNotification;
use App\Models\Order;
use App\Models\Product;
use App\Models\Shop;
use App\Models\User;
use App\Support\MediaStorage;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Storage;
use Laravel\Sanctum\Sanctum;
use Tests\Concerns\FakesImages;
use Tests\TestCase;

// ร้านจัดการคำสั่งซื้อ: เลือกขนส่ง + เลขพัสดุ / คืนเงินเมื่อยกเลิกหลังจ่าย / สรุปยอดขาย
class SellerOrderManagementTest extends TestCase
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
            'delivery_methods' => ['shipping', 'delivery', 'storefront'],
            'payment_methods' => ['promptpay', 'cod', 'cash'],
            'promptpay_id' => '0899999999',
        ]);

        $this->product = $this->shop->products()->create([
            'title' => 'มะม่วง',
            'price' => 100,
            'stock' => 20,
            'shipping_fee' => 40,
            'category' => 'produce',
            'status' => Product::STATUS_ACTIVE,
        ]);

        $this->buyer = User::factory()->create();
    }

    private function order(array $fields = []): Order
    {
        Sanctum::actingAs($this->buyer);

        $id = $this->postJson('/api/orders', [
            'product_id' => $this->product->id,
            'quantity' => 1,
            'delivery_method' => 'shipping',
            'payment_method' => 'cod',
            'recipient_name' => 'คุณแม่',
            'recipient_phone' => '0811112222',
            'address' => '99 ถ.นิมมาน เชียงใหม่ 50200',
            ...$fields,
        ])->assertCreated()->json('order.id');

        return Order::findOrFail($id);
    }

    public function test_parcel_shipping_needs_a_carrier_and_tracking_number(): void
    {
        $order = $this->order();

        Sanctum::actingAs($this->seller);

        // ร้านเห็นรายชื่อขนส่งให้เลือก
        $carriers = $this->getJson("/api/orders/{$order->id}")
            ->assertOk()
            ->json('order.carriers');

        $this->assertContains('flash', array_column($carriers, 'key'));
        $this->assertTrue(collect($carriers)->firstWhere('key', 'flash')['tracking']);

        $this->postJson("/api/orders/{$order->id}/ship", ['tracking_number' => 'TH1'])
            ->assertUnprocessable()
            ->assertJsonValidationErrors('carrier');

        $this->postJson("/api/orders/{$order->id}/ship", ['carrier' => 'ufo'])
            ->assertUnprocessable()
            ->assertJsonValidationErrors('carrier');

        $this->postJson("/api/orders/{$order->id}/ship", ['carrier' => 'kex'])
            ->assertUnprocessable()
            ->assertJsonPath('message', 'กรุณากรอกเลขพัสดุ ลูกค้าจะได้ติดตามพัสดุได้');

        $this->assertSame(Order::STATUS_PREPARING, $order->refresh()->status);

        $this->postJson("/api/orders/{$order->id}/ship", ['carrier' => 'kex', 'tracking_number' => ' KEX123 '])
            ->assertOk()
            ->assertJsonPath('order.status', Order::STATUS_SHIPPED)
            ->assertJsonPath('order.carrier', 'kex')
            ->assertJsonPath('order.carrier_label', 'KEX (Kerry Express)')
            ->assertJsonPath('order.tracking_number', 'KEX123')
            ->assertJsonPath('order.carriers', []);

        $this->assertTrue(
            AppNotification::where('user_id', $this->buyer->id)
                ->where('message', 'like', '%KEX (Kerry Express) · เลขพัสดุ KEX123%')
                ->exists()
        );

        // ผู้ซื้อเห็นขนส่งและเลขพัสดุ
        Sanctum::actingAs($this->buyer);

        $this->getJson("/api/orders/{$order->id}")
            ->assertJsonPath('order.carrier_label', 'KEX (Kerry Express)')
            ->assertJsonPath('order.history.0.note', 'KEX (Kerry Express) · เลขพัสดุ KEX123');
    }

    public function test_home_delivery_and_pickup_carrier_rules(): void
    {
        $delivery = $this->order(['delivery_method' => 'delivery']);
        $pickup = $this->order(['delivery_method' => 'storefront', 'payment_method' => 'cash', 'address' => null]);

        Sanctum::actingAs($this->seller);

        // ส่งถึงบ้าน: ใช้ได้เฉพาะขนส่งแบบเรียกรถ / ร้านไปส่งเอง ไม่บังคับเลือก
        $keys = array_column($this->getJson("/api/orders/{$delivery->id}")->json('order.carriers'), 'key');

        $this->assertContains('lalamove', $keys);
        $this->assertNotContains('flash', $keys);

        $this->postJson("/api/orders/{$delivery->id}/ship", ['carrier' => 'flash', 'tracking_number' => 'X'])
            ->assertUnprocessable();

        $this->postJson("/api/orders/{$delivery->id}/ship", ['carrier' => 'lalamove'])
            ->assertOk()
            ->assertJsonPath('order.carrier_label', 'Lalamove');

        // รับที่ร้าน: ไม่มีขนส่ง
        $this->getJson("/api/orders/{$pickup->id}")->assertJsonPath('order.carriers', []);

        $this->postJson("/api/orders/{$pickup->id}/ship")
            ->assertOk()
            ->assertJsonPath('order.carrier', null);
    }

    public function test_cancelling_a_paid_order_needs_a_refund(): void
    {
        $order = $this->order(['payment_method' => 'promptpay']);

        // ส่งสลิป (ไม่มีระบบตรวจ → รอร้านตรวจ) แล้วร้านยืนยันรับเงิน
        $order->attachSlip($this->fakePng('slip.png'));
        $order->refresh()->confirmPayment();

        Sanctum::actingAs($this->seller);

        $this->postJson("/api/orders/{$order->id}/cancel", ['reason' => 'สินค้าเสียหาย'])
            ->assertOk()
            ->assertJsonPath('order.status', Order::STATUS_CANCELLED)
            ->assertJsonPath('order.refund_status', Order::REFUND_PENDING)
            ->assertJsonPath('order.status_label', 'ยกเลิกแล้ว · รอร้านคืนเงิน')
            ->assertJsonPath('order.actions', ['refund']);

        // ยังต้องจัดการ (คืนเงิน)
        $this->getJson('/api/my-shop/orders?filter=todo')
            ->assertJsonPath('todo', 1)
            ->assertJsonPath('orders.0.id', $order->id);

        $this->assertTrue(
            AppNotification::where('user_id', $this->buyer->id)
                ->where('message', 'like', '%ร้านต้องคืนเงินที่คุณโอนให้%')
                ->exists()
        );

        // ผู้ซื้อกดคืนเงินแทนร้านไม่ได้
        Sanctum::actingAs($this->buyer);

        $this->getJson("/api/orders/{$order->id}")->assertJsonPath('order.actions', []);
        $this->postJson("/api/orders/{$order->id}/refund", ['note' => 'x'])->assertStatus(409);

        // ร้านต้องบอกช่องทางคืนเงิน
        Sanctum::actingAs($this->seller);

        $this->postJson("/api/orders/{$order->id}/refund")
            ->assertUnprocessable()
            ->assertJsonValidationErrors('note');

        $this->postJson("/api/orders/{$order->id}/refund", ['note' => 'โอนกลับบัญชีเดิม เลขอ้างอิง 123'])
            ->assertOk()
            ->assertJsonPath('order.refund_status', Order::REFUND_DONE)
            ->assertJsonPath('order.refund_note', 'โอนกลับบัญชีเดิม เลขอ้างอิง 123')
            ->assertJsonPath('order.status_label', 'ยกเลิกแล้ว · ร้านแจ้งว่าคืนเงินแล้ว')
            ->assertJsonPath('order.actions', []);

        $this->assertNotNull($order->refresh()->refunded_at);

        $this->getJson('/api/my-shop/orders?filter=todo')->assertJsonPath('todo', 0);

        // กดซ้ำไม่ได้
        $this->postJson("/api/orders/{$order->id}/refund", ['note' => 'อีกครั้ง'])->assertStatus(409);

        $this->assertTrue(
            AppNotification::where('user_id', $this->buyer->id)
                ->where('title', 'ร้านคืนเงินให้คุณแล้ว')
                ->where('message', 'like', '%฿140%')
                ->exists()
        );
    }

    public function test_slip_under_review_also_needs_a_refund_but_unpaid_orders_do_not(): void
    {
        $review = $this->order(['payment_method' => 'promptpay']);
        $review->attachSlip($this->fakePng('slip.png'));

        $unpaid = $this->order(['payment_method' => 'promptpay']);
        $cod = $this->order();

        $this->assertSame(Order::STATUS_PAYMENT_REVIEW, $review->refresh()->status);

        Sanctum::actingAs($this->seller);

        $this->postJson("/api/orders/{$review->id}/cancel", ['reason' => 'ของหมด'])
            ->assertJsonPath('order.refund_status', Order::REFUND_PENDING);

        Sanctum::actingAs($this->buyer);

        $this->postJson("/api/orders/{$unpaid->id}/cancel")
            ->assertOk()
            ->assertJsonPath('order.refund_status', null)
            ->assertJsonPath('order.status_label', 'ยกเลิกแล้ว');

        $this->postJson("/api/orders/{$cod->id}/cancel")
            ->assertOk()
            ->assertJsonPath('order.refund_status', null);
    }

    public function test_shop_and_buyer_can_chat_from_the_order(): void
    {
        $order = $this->order();

        // ร้านทักลูกค้าจากคำสั่งซื้อ (ไม่ได้อยู่กลุ่มเดียวกัน)
        Sanctum::actingAs($this->seller);

        $roomId = $this->postJson('/api/chats', ['order_id' => $order->id])
            ->assertOk()
            ->json('conversation.id');

        $this->postJson("/api/chats/{$roomId}/messages", ['body' => 'ขอเลขบัญชีเพื่อคืนเงินค่ะ'])
            ->assertCreated();

        // ผู้ซื้อเปิดจากคำสั่งซื้อเดียวกัน → ห้องเดิม ตอบได้
        Sanctum::actingAs($this->buyer);

        $this->postJson('/api/chats', ['order_id' => $order->id])
            ->assertOk()
            ->assertJsonPath('conversation.id', $roomId);

        $this->postJson("/api/chats/{$roomId}/messages", ['body' => 'กสิกร 123'])->assertCreated();

        // คนอื่นเปิดแชทจากคำสั่งซื้อนี้ไม่ได้
        Sanctum::actingAs(User::factory()->create());

        $this->postJson('/api/chats', ['order_id' => $order->id])->assertNotFound();
    }

    public function test_sales_summary(): void
    {
        $this->travelTo(now('Asia/Bangkok')->setTime(12, 0)->utc());

        // สั่งค้างไม่จ่ายพร้อมกันได้ไม่เกิน 3 → ทำให้สำเร็จก่อนสั่งรายการถัดไป
        $complete = fn (Order $order, $at) => $order
            ->forceFill(['status' => Order::STATUS_COMPLETED, 'completed_at' => $at, 'paid_at' => $at])
            ->save();

        $complete($this->order(['quantity' => 2]), now());
        $complete($this->order(), now()->subDay());
        $complete($this->order(), now()->subMonths(2));

        $this->order()->forceFill(['status' => Order::STATUS_SHIPPED, 'shipped_at' => now()])->save();

        $cancelled = $this->order();

        Sanctum::actingAs($this->buyer);
        $this->postJson("/api/orders/{$cancelled->id}/cancel")->assertOk();

        // คนอื่นดูยอดขายร้านนี้ไม่ได้ (ไม่มีร้าน)
        Sanctum::actingAs($this->buyer);
        $this->getJson('/api/my-shop/sales')->assertNotFound();

        Sanctum::actingAs($this->seller);

        $response = $this->getJson('/api/my-shop/sales')
            ->assertOk()
            ->assertJsonPath('today.orders', 1)
            ->assertJsonPath('all.orders', 3)
            ->assertJsonPath('in_progress.orders', 1)
            ->assertJsonPath('refund_pending.orders', 0)
            ->assertJsonCount(7, 'days')
            ->assertJsonPath('days.6.orders', 1)
            ->assertJsonPath('days.5.orders', 1)
            ->assertJsonPath('top_products.0.title', 'มะม่วง');

        $this->assertEquals(240, $response->json('today.total'));
        $this->assertEquals(240 + 140 + 140, $response->json('all.total'));
        $this->assertEquals(140, $response->json('in_progress.total'));
        $this->assertSame(1, $response->json('cancelled_month'));

        // เดือนนี้: วันนี้ (+ เมื่อวาน ถ้ายังอยู่เดือนเดียวกัน)
        $sameMonth = now('Asia/Bangkok')->day > 1;

        $this->assertSame($sameMonth ? 2 : 1, $response->json('month.orders'));
        $this->assertSame($sameMonth ? 3 : 2, $response->json('top_products.0.quantity'));
    }
}
