<?php

namespace Tests\Feature;

use App\Models\AppNotification;
use App\Models\Order;
use App\Models\OrderStatusHistory;
use App\Models\Product;
use App\Models\Shop;
use App\Models\User;
use Illuminate\Http\Client\Response;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;
use Tests\Concerns\RunsParallelServers;
use Tests\TestCase;

// =======================================================
// คำขอที่เข้าพร้อมกันจริง (หลาย process ใช้ฐานข้อมูลเดียวกัน)
// - checkout เดียวกันส่งซ้ำพร้อมกัน → สร้างคำสั่งซื้อชุดเดียว ตัดสต็อก/แจ้งร้านครั้งเดียว
// - ยกเลิกพร้อมกัน → คืนสต็อกครั้งเดียว
// - ส่งสินค้าชนกับยกเลิก → ได้สถานะเดียว
// - หมดเวลาชำระถูกประมวลผลซ้อนกัน → ยกเลิก/คืนสต็อก/แจ้งเตือนครั้งเดียว
//
// ข้ามเมื่อไม่ได้ตั้ง CONCURRENCY_TESTS=1 (ดู Tests\Concerns\RunsParallelServers)
// =======================================================

class OrderConcurrencyTest extends TestCase
{
    use RunsParallelServers;

    private const SERVERS = 4;

    protected function setUp(): void
    {
        parent::setUp();

        $this->setUpParallelDatabase();

        $this->startServers(self::SERVERS);
    }

    private function seller(): array
    {
        $owner = User::factory()->create();

        $shop = Shop::create([
            'user_id' => $owner->id,
            'name' => 'ร้าน ' . $owner->id,
            'category' => 'produce',
            'phone' => '0812345678',
            'province' => 'เชียงใหม่',
            'status' => Shop::STATUS_ACTIVE,
            'terms_accepted_at' => now(),
            'delivery_methods' => ['shipping', 'storefront'],
            'payment_methods' => ['promptpay', 'cod', 'cash'],
            'promptpay_id' => '0899999999',
        ]);

        return [$owner, $shop];
    }

    private function product(Shop $shop, int $stock): Product
    {
        return $shop->products()->create([
            'title' => 'มะม่วง ' . Str::random(4),
            'price' => 100,
            'stock' => $stock,
            'shipping_fee' => 40,
            'category' => 'produce',
            'status' => Product::STATUS_ACTIVE,
        ]);
    }

    private function token(User $user): string
    {
        return $user->createToken('concurrency-test')->plainTextToken;
    }

    private function placeOrder(User $buyer, Shop $shop, Product $product, int $quantity, string $payment = 'cash'): Order
    {
        return DB::transaction(fn () => Order::placeGroup($buyer, $shop, [[
            'product' => $product,
            'variant' => null,
            'quantity' => $quantity,
            'unit_price' => (float) $product->price,
        ]], [
            'delivery_method' => 'storefront',
            'payment_method' => $payment,
            'recipient_name' => 'คุณแม่',
            'recipient_phone' => '0811112222',
        ]));
    }

    /** @param array<int, mixed> $responses */
    private function assertResponses(array $responses, array $allowed): void
    {
        foreach ($responses as $response) {
            $this->assertInstanceOf(Response::class, $response, 'คำขอไม่ได้รับคำตอบ');
            $this->assertContains($response->status(), $allowed, $response->body());
        }
    }

    private function cancelledHistories(Order $order): int
    {
        return OrderStatusHistory::where('order_id', $order->id)->where('status', Order::STATUS_CANCELLED)->count();
    }

    public function test_same_checkout_sent_at_once_creates_orders_once(): void
    {
        [$sellerA, $shopA] = $this->seller();
        [$sellerB, $shopB] = $this->seller();

        $a = $this->product($shopA, 20);
        $b = $this->product($shopB, 20);

        $buyer = User::factory()->create();
        $token = $this->token($buyer);

        // ร้านละ 1 คำสั่งซื้อ (checkout เดียวซื้อ 2 ร้าน)
        $body = [
            'checkout_id' => 'race-' . Str::random(10),
            'items' => [
                ['product_id' => $a->id, 'quantity' => 2],
                ['product_id' => $b->id, 'quantity' => 3],
            ],
            'groups' => [
                ['shop_id' => $shopA->id, 'delivery_method' => 'storefront', 'payment_method' => 'cash'],
                ['shop_id' => $shopB->id, 'delivery_method' => 'storefront', 'payment_method' => 'cash'],
            ],
            'recipient_name' => 'คุณแม่',
            'recipient_phone' => '0811112222',
        ];

        $responses = $this->sendAtOnce(array_fill(0, 8, [
            'method' => 'POST',
            'path' => '/api/orders',
            'token' => $token,
            'data' => $body,
        ]));

        $this->assertResponses($responses, [200, 201]);

        $this->assertSame(2, Order::count());
        $this->assertSame(18, $a->refresh()->stock);
        $this->assertSame(17, $b->refresh()->stock);
        $this->assertSame(2, OrderStatusHistory::count());

        foreach ([$sellerA, $sellerB] as $seller) {
            $this->assertSame(1, AppNotification::where('user_id', $seller->id)->where('title', 'มีคำสั่งซื้อใหม่')->count());
        }

        // ทุกคำขอได้คำสั่งซื้อชุดเดียวกัน
        $sets = collect($responses)
            ->map(fn (Response $response) => collect($response->json('orders'))->pluck('id')->sort()->values()->all())
            ->unique(fn (array $ids) => implode(',', $ids));

        $this->assertCount(1, $sets);
        $this->assertCount(2, $sets->first());
    }

    public function test_cancelling_at_once_restores_stock_once(): void
    {
        [$seller, $shop] = $this->seller();
        $product = $this->product($shop, 10);

        $buyer = User::factory()->create();

        $order = $this->placeOrder($buyer, $shop, $product, 3);

        $this->assertSame(7, $product->refresh()->stock);

        $buyerToken = $this->token($buyer);
        $sellerToken = $this->token($seller);

        $requests = [];

        for ($i = 0; $i < 8; $i++) {
            $requests[] = [
                'method' => 'POST',
                'path' => "/api/orders/{$order->id}/cancel",
                'token' => $i % 2 === 0 ? $buyerToken : $sellerToken,
                'data' => ['reason' => 'ยกเลิกพร้อมกัน'],
            ];
        }

        $responses = $this->sendAtOnce($requests);

        $this->assertResponses($responses, [200, 409]);
        $this->assertCount(1, array_filter($responses, fn (Response $response) => $response->status() === 200));

        $this->assertSame(Order::STATUS_CANCELLED, $order->refresh()->status);
        $this->assertSame(10, $product->refresh()->stock);
        $this->assertSame(1, $this->cancelledHistories($order));
        $this->assertSame(1, AppNotification::where('title', 'คำสั่งซื้อถูกยกเลิก')->count());
    }

    public function test_ship_racing_cancel_ends_in_one_state(): void
    {
        [$seller, $shop] = $this->seller();
        $product = $this->product($shop, 50);

        $sellerToken = $this->token($seller);

        $orders = [];
        $requests = [];

        for ($i = 0; $i < 5; $i++) {
            $buyer = User::factory()->create();
            $buyerToken = $this->token($buyer);

            $order = $orders[] = $this->placeOrder($buyer, $shop, $product, 2);

            foreach ([$sellerToken, $buyerToken, $sellerToken, $buyerToken] as $n => $token) {
                $requests[] = [
                    'method' => 'POST',
                    'path' => "/api/orders/{$order->id}/" . ($token === $sellerToken ? 'ship' : 'cancel'),
                    'token' => $token,
                    'data' => ['reason' => 'เปลี่ยนใจ'],
                ];
            }
        }

        $this->assertSame(40, $product->refresh()->stock);

        $this->assertResponses($this->sendAtOnce($requests), [200, 409]);

        $shipped = 0;

        foreach ($orders as $order) {
            $order->refresh();

            $this->assertContains($order->status, [Order::STATUS_SHIPPED, Order::STATUS_CANCELLED]);

            $statuses = OrderStatusHistory::where('order_id', $order->id)->pluck('status')->all();

            if ($order->status === Order::STATUS_SHIPPED) {
                $shipped++;
                $this->assertSame([Order::STATUS_PREPARING, Order::STATUS_SHIPPED], $statuses);
                $this->assertNull($order->cancelled_at);
            } else {
                $this->assertSame([Order::STATUS_PREPARING, Order::STATUS_CANCELLED], $statuses);
                $this->assertNull($order->shipped_at);
            }
        }

        // สต็อกคืนเฉพาะคำสั่งซื้อที่ยกเลิก
        $this->assertSame(50 - 2 * $shipped, $product->refresh()->stock);
    }

    public function test_overlapping_expiry_cancels_each_order_once(): void
    {
        [$seller, $shop] = $this->seller();
        $product = $this->product($shop, 30);

        $sellerToken = $this->token($seller);

        $orders = [];
        $buyerTokens = [];

        for ($i = 0; $i < 3; $i++) {
            $buyer = User::factory()->create();
            $buyerTokens[] = $this->token($buyer);

            for ($j = 0; $j < 2; $j++) {
                $orders[] = $this->placeOrder($buyer, $shop, $product, 1, 'promptpay');
            }
        }

        // เลยเวลาชำระ
        Order::query()->update(['payment_due_at' => now()->subMinute()]);

        $this->assertSame(24, $product->refresh()->stock);

        $requests = [];

        for ($i = 0; $i < 8; $i++) {
            $requests[] = $i % 2 === 0
                ? ['method' => 'GET', 'path' => '/api/my-shop/orders', 'token' => $sellerToken]
                : ['method' => 'GET', 'path' => '/api/orders', 'token' => $buyerTokens[$i % 3]];
        }

        // งานตามเวลา (หลายรอบซ้อนกัน) + ผู้ซื้อ/ร้านเปิดหน้ารายการพร้อมกัน
        $commands = $this->startCommands('orders:expire', 3);

        $this->assertResponses($this->sendAtOnce($requests), [200]);

        $this->assertSame([0, 0, 0], $this->waitForCommands($commands));

        foreach ($orders as $order) {
            $this->assertSame(Order::STATUS_CANCELLED, $order->refresh()->status);
            $this->assertSame(1, $this->cancelledHistories($order));
        }

        $this->assertSame(30, $product->refresh()->stock);

        // ยกเลิกโดยระบบ → แจ้งทั้งผู้ซื้อและร้าน คำสั่งซื้อละ 2 รายการ
        $this->assertSame(12, AppNotification::where('title', 'คำสั่งซื้อถูกยกเลิก')->count());
    }
}
