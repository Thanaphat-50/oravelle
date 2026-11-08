<?php

namespace App\Http\Controllers;

use App\Models\Address;
use App\Models\CartItem;
use App\Models\Order;
use App\Models\OrderCheckout;
use App\Models\OrderItem;
use App\Models\OutOfStock;
use App\Models\PaymentTransaction;
use App\Models\Product;
use App\Models\ProductReview;
use App\Models\Shop;
use App\Models\User;
use App\Services\OrderLines;
use Closure;
use Illuminate\Database\UniqueConstraintViolationException;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Str;
use Illuminate\Validation\Rule;
use Throwable;

// =======================================================
// สั่งซื้อสินค้า (ผู้ซื้อ + ร้าน)
// - เงินโอนเข้าร้านโดยตรง แอปไม่ได้รับเงินแทน
// - ปุ่มที่กดได้มาจาก Order::actionsFor() (แอปแสดงตามนั้น)
// =======================================================

class OrderController extends Controller
{
    private const PAGE_SIZE = 20;

    // แท็บในหน้ารายการคำสั่งซื้อ → สถานะ
    private const FILTERS = [
        'todo' => Order::SELLER_TODO_STATUSES,
        'open' => Order::OPEN_STATUSES,
        'to_pay' => [Order::STATUS_AWAITING_PAYMENT, Order::STATUS_PAYMENT_REVIEW],
        'to_ship' => [Order::STATUS_PREPARING],
        'shipping' => [Order::STATUS_SHIPPED],
        'completed' => [Order::STATUS_COMPLETED],
        'cancelled' => [Order::STATUS_CANCELLED],
    ];

    // คำสั่งซื้อที่ยังไม่จ่ายค้างพร้อมกันได้ (กันจองสต็อกทิ้งไว้)
    private const MAX_UNPAID_PER_BUYER = 10;
    private const MAX_UNPAID_PER_SHOP = 3;

    // =====================================================
    // GET /api/orders/checkout?product_id=
    // ข้อมูลหน้าสั่งซื้อ: วิธีรับสินค้า วิธีจ่าย ค่าส่ง จำนวนที่สั่งได้
    // =====================================================

    public function checkout(Request $request)
    {
        $data = $request->validate(['product_id' => 'required|integer']);

        $user = $request->user();

        $product = $this->findOrderable($user, (int) $data['product_id']);

        if ($product instanceof JsonResponse) {
            return $product;
        }

        $shop = $product->shop;

        $fee = (float) ($product->shipping_fee ?? 0);

        $last = Order::where('buyer_id', $user->id)->latest('id')->first();

        return response()->json([
            'status' => true,
            'product' => [
                ...$product->only(['id', 'title', 'price', 'stock', 'shipping_fee']),
                'image_url' => $product->images->first()?->url,
            ],
            'shop' => [
                ...$shop->only(['id', 'name']),
                'logo_url' => $shop->logo_url,
            ],
            'max_quantity' => min((int) $product->stock, (int) config('market.max_order_quantity')),
            'delivery_methods' => collect($shop->orderDeliveryMethods())->map(fn (string $key) => [
                'key' => $key,
                'label' => config("market.delivery_methods.{$key}"),
                'shipping_fee' => in_array($key, config('market.shipping_fee_methods'), true) ? $fee : 0,
                'needs_address' => in_array($key, config('market.address_methods'), true),
                'payment_methods' => collect($shop->paymentMethodsFor($key))->map(fn (string $method) => [
                    'key' => $method,
                    'label' => config("market.payment_methods.{$method}.label"),
                    'transfer' => (bool) config("market.payment_methods.{$method}.transfer"),
                ])->values(),
            ])->values(),
            // กรอกให้ล่วงหน้าจากคำสั่งซื้อล่าสุด
            'recipient' => [
                'name' => $last?->recipient_name ?? $user->name,
                'phone' => $last?->recipient_phone ?? '',
                'address' => $last?->address ?? '',
            ],
        ]);
    }

    // =====================================================
    // POST /api/orders/preview {items: [{product_id, variant_id, quantity}]}
    // หน้าสรุปคำสั่งซื้อ: แยกตามร้าน ราคาปัจจุบัน วิธีรับสินค้า/วิธีจ่าย ค่าส่ง ที่อยู่ที่บันทึกไว้
    // =====================================================

    public function preview(Request $request)
    {
        $data = $request->validate($this->itemRules(), $this->itemMessages());

        $user = $request->user();

        return response()->json([
            'status' => true,
            ...$this->previewPayload($user, $data['items']),
        ]);
    }

    // =====================================================
    // POST /api/orders
    // แอปใหม่: {checkout_id, items[], groups[{shop_id, delivery_method, payment_method, note}],
    //          address_id | recipient_name + recipient_phone, expected_total}
    //          → 1 คำสั่งซื้อต่อ 1 ร้าน, checkout_id เดิม = ได้คำสั่งซื้อเดิม (กันกดซ้ำ)
    // แอปเวอร์ชันเก่า: สินค้าเดียว {product_id, quantity, delivery_method, ...}
    // =====================================================

    public function store(Request $request)
    {
        return $request->has('items')
            ? $this->storeCheckout($request)
            : $this->storeSingle($request);
    }

    private function storeCheckout(Request $request)
    {
        $data = $request->validate([
            ...$this->itemRules(),
            'checkout_id' => 'required|string|max:40',
            'groups' => 'required|array|min:1',
            'groups.*.shop_id' => 'required|integer',
            'groups.*.delivery_method' => ['required', Rule::in(array_keys(config('market.delivery_methods')))],
            'groups.*.payment_method' => ['required', Rule::in(array_keys(config('market.payment_methods')))],
            'groups.*.note' => 'nullable|string|max:500',
            'address_id' => 'nullable|integer',
            'recipient_name' => 'required_without:address_id|nullable|string|max:100',
            'recipient_phone' => ['required_without:address_id', 'nullable', 'string', 'regex:/^\+?[0-9][0-9\s\-]{7,18}$/'],
            'expected_total' => 'nullable|numeric',
        ], [
            ...$this->itemMessages(),
            'groups.*.delivery_method.*' => 'กรุณาเลือกวิธีรับสินค้าของทุกร้าน',
            'groups.*.payment_method.*' => 'กรุณาเลือกวิธีชำระเงินของทุกร้าน',
            'groups.*.note.max' => 'ฝากถึงร้านยาวได้ไม่เกิน 500 ตัวอักษร',
            'recipient_name.*' => 'กรุณาใส่ชื่อผู้รับ',
            'recipient_phone.required_without' => 'กรุณาใส่เบอร์โทรผู้รับ',
            'recipient_phone.regex' => 'เบอร์โทรไม่ถูกต้อง',
        ]);

        $user = $request->user();

        $placed = fn () => Order::where('buyer_id', $user->id)
            ->where('checkout_id', $data['checkout_id'])
            ->orderBy('id')
            ->get();

        // กดสั่งซ้ำ (เน็ตช้า / กดสองครั้ง / แอปส่งใหม่หลังหมดเวลารอ) → คืนคำสั่งซื้อเดิม ไม่สร้างใหม่
        if (($orders = $placed())->isNotEmpty()) {
            return $this->ordersResponse($user, $orders, 200);
        }

        $response = $this->placeCheckout($user, $data);

        // ไม่สำเร็จ เพราะคำขอเดียวกันอีกคำขอ (เข้าพร้อมกัน) สร้างเสร็จไปก่อน
        // เช่น ชน unique ของ order_checkouts / เห็นสต็อกที่คำขอนั้นตัดไปแล้ว → คืนผลของคำขอนั้น
        if ($response->getStatusCode() >= 400 && ($orders = $placed())->isNotEmpty()) {
            return $this->ordersResponse($user, $orders, 200);
        }

        return $response;
    }

    private function placeCheckout(User $user, array $data): JsonResponse
    {
        $lines = app(OrderLines::class)->resolve($user, $data['items']);

        if ($lines->contains(fn (array $line) => $line['problem'] !== null)) {
            return $this->changed($user, $data['items'], 'บางรายการสั่งซื้อไม่ได้แล้ว กรุณาตรวจสอบอีกครั้ง');
        }

        $groups = collect($data['groups'])->keyBy(fn (array $group) => (int) $group['shop_id']);

        $byShop = $lines->groupBy(fn (array $line) => (int) $line['product']->shop_id);

        $address = isset($data['address_id'])
            ? Address::where('user_id', $user->id)->find($data['address_id'])
            : null;

        if (isset($data['address_id']) && !$address) {
            return $this->fail('ไม่พบที่อยู่นี้ กรุณาเลือกใหม่');
        }

        $grandTotal = 0.0;

        foreach ($byShop as $shopId => $shopLines) {
            $group = $groups->get($shopId);

            /** @var Shop $shop */
            $shop = $shopLines->first()['product']->shop;

            if (!$group) {
                return $this->fail('กรุณาเลือกวิธีรับสินค้าและวิธีชำระเงินของร้าน ' . $shop->name);
            }

            if (!in_array($group['delivery_method'], $shop->orderDeliveryMethods(), true)) {
                return $this->fail("ร้าน {$shop->name} ไม่ได้เปิดวิธีรับสินค้านี้ กรุณาเลือกใหม่");
            }

            if (!in_array($group['payment_method'], $shop->paymentMethodsFor($group['delivery_method']), true)) {
                return $this->fail("วิธีชำระเงินที่เลือกใช้กับวิธีรับสินค้าของร้าน {$shop->name} ไม่ได้");
            }

            if (in_array($group['delivery_method'], config('market.address_methods'), true) && !$address) {
                return $this->fail('กรุณาเลือกที่อยู่จัดส่ง');
            }

            [$itemsTotal, $shippingFee] = Order::totalsFor($shopLines->all(), $group['delivery_method']);

            $grandTotal += $itemsTotal + $shippingFee;
        }

        // ราคา/ค่าส่งเปลี่ยนระหว่างลูกค้าดูหน้าสรุป → ให้ตรวจยอดใหม่ก่อนสั่ง
        if (isset($data['expected_total']) && abs(round($grandTotal, 2) - (float) $data['expected_total']) > 0.009) {
            return $this->changed($user, $data['items'], 'ราคาหรือค่าส่งเปลี่ยนแล้ว กรุณาตรวจสอบยอดใหม่');
        }

        $unpaid = Order::where('buyer_id', $user->id)->unpaidReservation();

        if ((clone $unpaid)->count() + $byShop->count() > self::MAX_UNPAID_PER_BUYER
            || $byShop->keys()->contains(fn ($shopId) => (clone $unpaid)->where('shop_id', $shopId)->count() >= self::MAX_UNPAID_PER_SHOP)) {
            return $this->fail('คุณมีคำสั่งซื้อที่ยังไม่ได้ชำระหลายรายการแล้ว ชำระหรือยกเลิกก่อนสั่งเพิ่ม', 429);
        }

        $recipient = [
            'recipient_name' => $address?->recipient_name ?? $data['recipient_name'],
            'recipient_phone' => $address?->phone ?? $data['recipient_phone'],
        ];

        try {
            $orders = DB::transaction(function () use ($byShop, $user, $groups, $address, $recipient, $data) {
                // จอง checkout นี้ก่อนตัดสต็อก (unique buyer_id + checkout_id)
                // คำขอเดียวกันที่เข้าพร้อมกันจะรอตรงนี้จนคำขอแรกเสร็จ แล้วชน unique → คืนผลเดิม (ด้านล่าง)
                // คำขอแรกล้ม (สต็อกไม่พอ ฯลฯ) → แถวนี้ถูกยกเลิกด้วย ส่งใหม่ได้
                OrderCheckout::create([
                    'buyer_id' => $user->id,
                    'checkout_id' => $data['checkout_id'],
                ]);

                return $byShop->map(function (Collection $shopLines, int $shopId) use ($user, $groups, $address, $recipient, $data) {
                    $group = $groups->get($shopId);

                    $needsAddress = in_array($group['delivery_method'], config('market.address_methods'), true);

                    return Order::placeGroup($user, $shopLines->first()['product']->shop, $shopLines->all(), [
                        ...$recipient,
                        'delivery_method' => $group['delivery_method'],
                        'payment_method' => $group['payment_method'],
                        'address' => $needsAddress ? $address?->fullAddress() : null,
                        'note' => $group['note'] ?? null,
                    ], $data['checkout_id']);
                })->values();
            }, 3);
        } catch (UniqueConstraintViolationException $e) {
            // ปกติ = อีกคำขอของ checkout เดียวกันสร้างไปแล้ว → storeCheckout() คืนคำสั่งซื้อนั้น
            Log::info('Checkout unique conflict', ['buyer_id' => $user->id, 'error' => $e->getMessage()]);

            return $this->fail('สั่งซื้อไม่สำเร็จ กรุณากดสั่งซื้ออีกครั้ง', 409);
        } catch (OutOfStock $e) {
            return $this->changed(
                $user,
                $data['items'],
                $e->remaining > 0 ? "{$e->title} เหลือ {$e->remaining} ชิ้น กรุณาลดจำนวน" : "{$e->title} หมดแล้ว"
            );
        }

        $orders->each(fn (Order $order) => $order->announceToSeller());

        // สั่งแล้วเอาออกจากตะกร้า
        foreach ($lines as $line) {
            CartItem::where('user_id', $user->id)
                ->where('product_id', $line['product']->id)
                ->where('variant_id', $line['variant']?->id)
                ->delete();
        }

        return $this->ordersResponse($user, $orders, 201);
    }

    private function storeSingle(Request $request)
    {
        $needsAddress = in_array($request->input('delivery_method'), config('market.address_methods'), true);

        $data = $request->validate([
            'product_id' => 'required|integer',
            'quantity' => 'required|integer|min:1|max:' . config('market.max_order_quantity'),
            'delivery_method' => ['required', Rule::in(array_keys(config('market.delivery_methods')))],
            'payment_method' => ['required', Rule::in(array_keys(config('market.payment_methods')))],
            'recipient_name' => 'required|string|max:100',
            'recipient_phone' => ['required', 'string', 'regex:/^\+?[0-9][0-9\s\-]{7,18}$/'],
            'address' => [Rule::requiredIf($needsAddress), 'nullable', 'string', 'max:500'],
            'note' => 'nullable|string|max:500',
        ], [
            'quantity.*' => 'จำนวนต้องเป็น 1 – ' . config('market.max_order_quantity') . ' ชิ้น',
            'delivery_method.*' => 'กรุณาเลือกวิธีรับสินค้า',
            'payment_method.*' => 'กรุณาเลือกวิธีชำระเงิน',
            'recipient_name.required' => 'กรุณาใส่ชื่อผู้รับ',
            'recipient_name.max' => 'ชื่อผู้รับยาวได้ไม่เกิน 100 ตัวอักษร',
            'recipient_phone.required' => 'กรุณาใส่เบอร์โทรผู้รับ',
            'recipient_phone.regex' => 'เบอร์โทรไม่ถูกต้อง',
            'address.required' => 'กรุณาใส่ที่อยู่จัดส่ง',
            'address.max' => 'ที่อยู่ยาวได้ไม่เกิน 500 ตัวอักษร',
            'note.max' => 'หมายเหตุยาวได้ไม่เกิน 500 ตัวอักษร',
        ]);

        $user = $request->user();

        $product = $this->findOrderable($user, (int) $data['product_id']);

        if ($product instanceof JsonResponse) {
            return $product;
        }

        $shop = $product->shop;

        if (!in_array($data['delivery_method'], $shop->orderDeliveryMethods(), true)) {
            return $this->fail('ร้านไม่ได้เปิดวิธีรับสินค้านี้ กรุณาเลือกใหม่');
        }

        if (!in_array($data['payment_method'], $shop->paymentMethodsFor($data['delivery_method']), true)) {
            return $this->fail('วิธีชำระเงินนี้ใช้กับวิธีรับสินค้าที่เลือกไม่ได้');
        }

        $unpaid = Order::where('buyer_id', $user->id)->unpaidReservation();

        if ((clone $unpaid)->count() >= self::MAX_UNPAID_PER_BUYER
            || (clone $unpaid)->where('shop_id', $shop->id)->count() >= self::MAX_UNPAID_PER_SHOP) {
            return $this->fail('คุณมีคำสั่งซื้อที่ยังไม่ได้ชำระหลายรายการแล้ว ชำระหรือยกเลิกก่อนสั่งเพิ่ม', 429);
        }

        if ($product->hasVariants()) {
            return $this->fail('สินค้านี้มีตัวเลือก กรุณาอัปเดตแอปเป็นเวอร์ชันล่าสุดเพื่อสั่งซื้อ');
        }

        try {
            $order = DB::transaction(fn () => Order::placeGroup($user, $shop, [[
                'product' => $product,
                'variant' => null,
                'quantity' => (int) $data['quantity'],
                'unit_price' => (float) $product->price,
            ]], $data));
        } catch (OutOfStock $e) {
            return $this->fail(
                $e->remaining > 0 ? "สินค้าเหลือ {$e->remaining} ชิ้น กรุณาลดจำนวน" : 'สินค้าหมดแล้ว',
                409
            );
        }

        $order->announceToSeller();

        return response()->json([
            'status' => true,
            'message' => $order->isTransfer()
                ? 'สั่งซื้อแล้ว โอนเงินแล้วแนบสลิปได้เลย'
                : 'สั่งซื้อแล้ว รอร้านจัดส่ง',
            'order' => $order->toPayload($user),
        ], 201);
    }

    // =====================================================
    // GET /api/orders?filter=open|completed|cancelled  (ที่ฉันซื้อ)
    // GET /api/my-shop/orders?filter=todo|open|completed|cancelled  (ลูกค้าของร้าน)
    // =====================================================

    public function index(Request $request)
    {
        $user = $request->user();

        $mine = fn () => Order::where('buyer_id', $user->id);

        Order::expireStale(fn ($query) => $query->where('buyer_id', $user->id));

        return $this->list($request, $mine(), $user, [
            'counts' => [
                'to_pay' => $mine()->whereIn('status', self::FILTERS['to_pay'])->count(),
                'to_ship' => $mine()->whereIn('status', self::FILTERS['to_ship'])->count(),
                'shipping' => $mine()->whereIn('status', self::FILTERS['shipping'])->count(),
            ],
        ]);
    }

    public function shopIndex(Request $request)
    {
        $user = $request->user();

        $shop = Shop::where('user_id', $user->id)->first();

        if (!$shop) {
            return $this->fail('คุณยังไม่มีร้าน', 404);
        }

        Order::expireStale(fn ($query) => $query->where('shop_id', $shop->id));

        return $this->list($request, Order::where('shop_id', $shop->id), $user, [
            'todo' => Order::where('shop_id', $shop->id)->sellerTodo()->count(),
        ]);
    }

    // =====================================================
    // GET /api/orders/{order}
    // =====================================================

    public function show(Request $request, Order $order)
    {
        $user = $request->user();

        if (!$order->isBuyer($user) && !$order->isSeller($user)) {
            return $this->notFound();
        }

        Order::expireStale(fn ($query) => $query->whereKey($order->id));

        $order->refresh();

        return response()->json([
            'status' => true,
            'order' => $order->toPayload($user),
        ]);
    }

    // =====================================================
    // ร้าน: สลิปไม่ถูกต้อง (เงินไม่เข้า) / ส่งสินค้า
    // =====================================================

    public function rejectSlip(Request $request, Order $order)
    {
        $data = $request->validate(
            ['reason' => 'required|string|max:300'],
            ['reason.*' => 'กรุณาบอกเหตุผล (ไม่เกิน 300 ตัวอักษร)']
        );

        return $this->act(
            $request,
            $order,
            'reject_slip',
            'แจ้งผู้ซื้อให้แนบสลิปใหม่แล้ว',
            fn (Closure $allowed) => $order->rejectSlip(trim($data['reason']), $allowed)
        );
    }

    // ส่งพัสดุ: ต้องเลือกบริษัทขนส่ง (+ เลขพัสดุ ถ้าเป็นขนส่งที่มีเลขพัสดุ)
    // ส่งถึงบ้าน: เลือกขนส่งได้ (ไม่บังคับ) / รับที่ร้าน นัดรับ: ไม่มีขนส่ง
    public function ship(Request $request, Order $order)
    {
        if ($denied = $this->denied($request, $order, 'ship')) {
            return $denied;
        }

        $carriers = collect($order->carrierOptions());

        $data = $request->validate([
            'carrier' => [
                $order->delivery_method === 'shipping' ? 'required' : 'nullable',
                'string',
                Rule::in($carriers->pluck('key')->all()),
            ],
            'tracking_number' => 'nullable|string|max:60',
            'seller_note' => 'nullable|string|max:500',
        ], [
            'carrier.*' => 'กรุณาเลือกบริษัทขนส่ง',
            'tracking_number.*' => 'เลขพัสดุยาวได้ไม่เกิน 60 ตัวอักษร',
            'seller_note.*' => 'ข้อความยาวได้ไม่เกิน 500 ตัวอักษร',
        ]);

        $carrier = $data['carrier'] ?? null;
        $tracking = filled($data['tracking_number'] ?? null) ? trim($data['tracking_number']) : null;

        if ($carrier && $tracking === null && ($carriers->firstWhere('key', $carrier)['tracking'] ?? false)) {
            return $this->fail('กรุณากรอกเลขพัสดุ ลูกค้าจะได้ติดตามพัสดุได้', 422);
        }

        return $this->act(
            $request,
            $order,
            'ship',
            'บันทึกการส่งสินค้าแล้ว',
            fn (Closure $allowed) => $order->ship(
                $tracking,
                filled($data['seller_note'] ?? null) ? trim($data['seller_note']) : null,
                $carrier,
                $allowed
            )
        );
    }

    // =====================================================
    // POST /api/orders/{order}/refund {note}
    // ร้าน: คืนเงินให้ลูกค้าแล้ว (คำสั่งซื้อที่ยกเลิกหลังลูกค้าจ่ายเงิน)
    // =====================================================

    public function refund(Request $request, Order $order)
    {
        if ($denied = $this->denied($request, $order, 'refund')) {
            return $denied;
        }

        $data = $request->validate(
            ['note' => 'required|string|max:300'],
            ['note.*' => 'กรุณาบอกว่าคืนเงินช่องทางไหน เช่น โอนกลับบัญชีเดิม เลขอ้างอิง (ไม่เกิน 300 ตัวอักษร)']
        );

        return $this->act(
            $request,
            $order,
            'refund',
            'บันทึกการคืนเงินแล้ว แจ้งลูกค้าแล้ว',
            fn (Closure $allowed) => $order->markRefunded(trim($data['note']), $allowed)
        );
    }

    // =====================================================
    // GET /api/my-shop/sales  สรุปยอดขายของร้าน
    // ยอดขาย = คำสั่งซื้อที่สำเร็จ (ลูกค้าได้รับสินค้าแล้ว) นับตามวันที่สำเร็จ (เวลาไทย)
    // =====================================================

    public function shopSales(Request $request)
    {
        $shop = Shop::where('user_id', $request->user()->id)->first();

        if (!$shop) {
            return $this->fail('คุณยังไม่มีร้าน', 404);
        }

        Order::expireStale(fn ($query) => $query->where('shop_id', $shop->id));

        $timezone = config('market.timezone');
        $today = now($timezone)->startOfDay();
        $monthStart = now($timezone)->startOfMonth();

        $orders = fn () => Order::where('shop_id', $shop->id);
        $completed = fn () => $orders()->where('status', Order::STATUS_COMPLETED);

        $sum = fn ($query) => [
            'total' => round((float) (clone $query)->sum('total'), 2),
            'orders' => (clone $query)->count(),
        ];

        // 7 วันล่าสุด (วันนี้อยู่ท้าย)
        $recent = $completed()
            ->where('completed_at', '>=', $today->copy()->subDays(6)->utc())
            ->get(['total', 'completed_at'])
            ->groupBy(fn (Order $order) => $order->completed_at->setTimezone($timezone)->toDateString());

        $days = collect(range(6, 0))->map(function (int $ago) use ($today, $recent) {
            $date = $today->copy()->subDays($ago)->toDateString();
            $group = $recent->get($date, collect());

            return [
                'date' => $date,
                'total' => round((float) $group->sum('total'), 2),
                'orders' => $group->count(),
            ];
        });

        // สินค้าขายดีเดือนนี้
        $top = OrderItem::query()
            ->join('orders', 'orders.id', '=', 'order_items.order_id')
            ->where('orders.shop_id', $shop->id)
            ->where('orders.status', Order::STATUS_COMPLETED)
            ->where('orders.completed_at', '>=', $monthStart->copy()->utc())
            ->groupBy('order_items.product_id')
            ->selectRaw('order_items.product_id, max(order_items.title) as title, sum(order_items.quantity) as quantity, sum(order_items.subtotal) as total')
            ->orderByDesc('quantity')
            ->limit(5)
            ->get()
            ->map(fn ($row) => [
                'product_id' => $row->product_id,
                'title' => $row->title,
                'quantity' => (int) $row->quantity,
                'total' => round((float) $row->total, 2),
            ]);

        return response()->json([
            'status' => true,
            'today' => $sum($completed()->where('completed_at', '>=', $today->copy()->utc())),
            'month' => $sum($completed()->where('completed_at', '>=', $monthStart->copy()->utc())),
            'all' => $sum($completed()),
            // รอร้านจัดส่ง / กำลังจัดส่ง (ยังไม่นับเป็นยอดขาย)
            'in_progress' => $sum($orders()->whereIn('status', [
                Order::STATUS_PAYMENT_REVIEW,
                Order::STATUS_PREPARING,
                Order::STATUS_SHIPPED,
            ])),
            'cancelled_month' => $orders()
                ->where('status', Order::STATUS_CANCELLED)
                ->where('cancelled_at', '>=', $monthStart->copy()->utc())
                ->count(),
            'refund_pending' => $sum($orders()
                ->where('status', Order::STATUS_CANCELLED)
                ->where('refund_status', Order::REFUND_PENDING)),
            'days' => $days,
            'top_products' => $top,
        ]);
    }

    // =====================================================
    // ผู้ซื้อ: แนบสลิป / ได้รับสินค้าแล้ว
    // =====================================================

    public function uploadSlip(Request $request, Order $order)
    {
        $request->validate(
            ['slip' => 'required|image|mimes:jpg,jpeg,png,webp|max:6144'],
            ['slip.*' => 'สลิปต้องเป็นรูป JPG, PNG หรือ WEBP ไม่เกิน 6 MB']
        );

        // ข้อความขึ้นกับผลตรวจสลิป (ตั้งหลังตรวจเสร็จ)
        $message = 'ส่งสลิปแล้ว';

        return $this->act($request, $order, 'pay', function () use (&$message) {
            return $message;
        }, function (Closure $allowed) use ($request, $order, &$message) {
            try {
                $payment = $order->attachSlip($request->file('slip'), $allowed);
            } catch (Throwable $e) {
                Log::error('Order slip upload failed', ['order_id' => $order->id, 'error' => $e->getMessage()]);

                return $this->fail('อัปโหลดสลิปไม่สำเร็จ กรุณาลองอีกครั้ง', 500);
            }

            // สถานะเปลี่ยนระหว่างตรวจสลิป (เช่น แนบซ้อนกัน 2 ครั้ง) → 409
            if ($payment === null) {
                return false;
            }

            // คำสั่งซื้อถูกยกเลิก (หมดเวลาชำระ) ระหว่างตรวจสลิป → แจ้งร้านให้คืนเงินแล้ว
            if ($order->status === Order::STATUS_CANCELLED) {
                return response()->json([
                    'status' => false,
                    'code' => 'order_cancelled',
                    'message' => 'คำสั่งซื้อนี้ถูกยกเลิกไปก่อนตรวจสลิปเสร็จ ระบบแจ้งร้านให้ตรวจยอดและคืนเงินให้คุณแล้ว',
                    'order' => $order->refresh()->toPayload($request->user()),
                ], 409);
            }

            if ($payment->status === PaymentTransaction::STATUS_REJECTED) {
                return response()->json([
                    'status' => false,
                    'code' => 'slip_rejected',
                    'message' => 'สลิปไม่ผ่าน: ' . $payment->reason,
                    'order' => $order->refresh()->toPayload($request->user()),
                ], 422);
            }

            $message = $payment->status === PaymentTransaction::STATUS_VERIFIED
                ? 'ชำระเงินสำเร็จ ระบบตรวจสลิปแล้ว รอร้านจัดส่ง'
                : 'ส่งสลิปแล้ว ' . $payment->reason;

            return null;
        });
    }

    // ร้านยืนยันว่าได้รับเงินแล้ว (ตอนตรวจสลิปอัตโนมัติไม่ได้)
    public function confirmPayment(Request $request, Order $order)
    {
        return $this->act(
            $request,
            $order,
            'confirm_payment',
            'ยืนยันรับเงินแล้ว จัดส่งสินค้าได้เลย',
            fn (Closure $allowed) => $order->confirmPayment($allowed)
        );
    }

    public function received(Request $request, Order $order)
    {
        return $this->act($request, $order, 'received', 'ขอบคุณที่ยืนยัน คำสั่งซื้อสำเร็จแล้ว', fn (Closure $allowed) => $order->complete(Order::BY_BUYER, $allowed));
    }

    // =====================================================
    // POST /api/orders/{order}/reviews {product_id, rating, comment}
    // รีวิวสินค้าได้เมื่อคำสั่งซื้อสำเร็จ (แก้รีวิวเดิมได้)
    // =====================================================

    public function review(Request $request, Order $order)
    {
        $user = $request->user();

        if (!$order->isBuyer($user)) {
            return $this->notFound();
        }

        $data = $request->validate([
            'product_id' => 'required|integer',
            'rating' => 'required|integer|min:1|max:5',
            'comment' => 'nullable|string|max:500',
        ], [
            'rating.*' => 'กรุณาให้คะแนน 1 – 5 ดาว',
            'comment.max' => 'รีวิวยาวได้ไม่เกิน 500 ตัวอักษร',
        ]);

        if ($order->status !== Order::STATUS_COMPLETED) {
            return $this->fail('รีวิวได้เมื่อได้รับสินค้าแล้ว');
        }

        $item = $order->items()->where('product_id', $data['product_id'])->first();

        if (!$item || !Product::whereKey($data['product_id'])->exists()) {
            return $this->fail('ไม่พบสินค้านี้ในคำสั่งซื้อ', 404);
        }

        $review = ProductReview::updateOrCreate(
            ['order_id' => $order->id, 'product_id' => $item->product_id],
            [
                'user_id' => $user->id,
                'shop_id' => $order->shop_id,
                'rating' => $data['rating'],
                'comment' => filled($data['comment'] ?? null) ? trim($data['comment']) : null,
                'variant_name' => $item->variant_name,
            ]
        );

        if ($review->wasRecentlyCreated) {
            $order->notifySellerAbout(
                'shop_review',
                'มีรีวิวสินค้าใหม่',
                str_repeat('★', $review->rating) . ' "' . $item->title . '"'
                    . ($review->comment ? ' · ' . Str::limit($review->comment, 80) : '')
            );
        }

        return response()->json([
            'status' => true,
            'message' => 'ขอบคุณสำหรับรีวิว',
            'order' => $order->refresh()->toPayload($user),
        ]);
    }

    // =====================================================
    // POST /api/orders/{order}/cancel  (ผู้ซื้อ หรือ ร้าน)
    // ร้านต้องบอกเหตุผล
    // =====================================================

    public function cancel(Request $request, Order $order)
    {
        $user = $request->user();

        if (!$order->isBuyer($user) && !$order->isSeller($user)) {
            return $this->notFound();
        }

        $bySeller = !$order->isBuyer($user);

        $data = $request->validate(
            ['reason' => [$bySeller ? 'required' : 'nullable', 'string', 'max:300']],
            ['reason.*' => 'กรุณาบอกเหตุผลที่ยกเลิก (ไม่เกิน 300 ตัวอักษร)']
        );

        $reason = filled($data['reason'] ?? null) ? trim($data['reason']) : null;

        return $this->act(
            $request,
            $order,
            'cancel',
            'ยกเลิกคำสั่งซื้อแล้ว',
            fn (Closure $allowed) => $order->cancel($bySeller ? Order::BY_SELLER : Order::BY_BUYER, $reason, $allowed)
        );
    }

    // =====================================================
    // HELPERS
    // =====================================================

    private function itemRules(): array
    {
        $max = (int) config('market.max_order_quantity');

        return [
            'items' => 'required|array|min:1|max:50',
            'items.*.product_id' => 'required|integer',
            'items.*.variant_id' => 'nullable|integer',
            'items.*.quantity' => "required|integer|min:1|max:{$max}",
        ];
    }

    private function itemMessages(): array
    {
        $max = (int) config('market.max_order_quantity');

        return [
            'items.required' => 'ยังไม่ได้เลือกสินค้า',
            'items.max' => 'สั่งได้ครั้งละไม่เกิน 50 รายการ',
            'items.*.quantity.*' => "จำนวนต้องเป็น 1 – {$max} ชิ้น",
        ];
    }

    // ข้อมูลหน้าสรุปคำสั่งซื้อ (แยกตามร้าน)
    private function previewPayload(User $user, array $items): array
    {
        $lines = app(OrderLines::class)->resolve($user, $items);

        $groups = $lines
            ->filter(fn (array $line) => $line['product'] !== null)
            ->groupBy(fn (array $line) => (int) $line['product']->shop_id)
            ->map(function (Collection $shopLines) {
                /** @var Shop $shop */
                $shop = $shopLines->first()['product']->shop;

                $orderable = $shopLines->filter(fn (array $line) => $line['problem'] === null)->all();

                return [
                    'shop' => [
                        ...$shop->only(['id', 'name']),
                        'logo_url' => $shop->logo_url,
                    ],
                    'items' => $shopLines->map(fn (array $line) => OrderLines::payload($line))->values(),
                    'delivery_methods' => collect($shop->orderDeliveryMethods())->map(function (string $key) use ($shop, $orderable) {
                        [$itemsTotal, $shippingFee] = Order::totalsFor($orderable, $key);

                        return [
                            'key' => $key,
                            'label' => config("market.delivery_methods.{$key}"),
                            'shipping_fee' => $shippingFee,
                            'items_total' => $itemsTotal,
                            'needs_address' => in_array($key, config('market.address_methods'), true),
                            'payment_methods' => collect($shop->paymentMethodsFor($key))->map(fn (string $method) => [
                                'key' => $method,
                                'label' => config("market.payment_methods.{$method}.label"),
                                'transfer' => (bool) config("market.payment_methods.{$method}.transfer"),
                            ])->values(),
                        ];
                    })->values(),
                ];
            })
            ->values();

        $addresses = Address::where('user_id', $user->id)
            ->orderByDesc('is_default')
            ->latest('id')
            ->get();

        $last = Order::where('buyer_id', $user->id)->latest('id')->first();

        return [
            'groups' => $groups,
            // สินค้าที่ไม่มีขายแล้ว (ไม่รู้ว่าร้านไหน)
            'unavailable' => $lines
                ->filter(fn (array $line) => $line['product'] === null)
                ->map(fn (array $line) => OrderLines::payload($line))
                ->values(),
            'addresses' => $addresses->map(fn (Address $address) => $address->toPayload())->values(),
            // รับเองที่ร้าน/นัดรับ: ชื่อและเบอร์ผู้รับ (ใช้จากที่อยู่หลัก หรือคำสั่งซื้อล่าสุด)
            'recipient' => [
                'name' => $addresses->first()?->recipient_name ?? $last?->recipient_name ?? $user->name,
                'phone' => $addresses->first()?->phone ?? $last?->recipient_phone ?? '',
            ],
        ];
    }

    // ราคา/สต็อกเปลี่ยน → ส่งหน้าสรุปใหม่ให้แอปแสดง
    private function changed(User $user, array $items, string $message)
    {
        return response()->json([
            'status' => false,
            'code' => 'checkout_changed',
            'message' => $message,
            ...$this->previewPayload($user, $items),
        ], 409);
    }

    private function ordersResponse(User $user, $orders, int $status)
    {
        $transfer = $orders->contains(fn (Order $order) => $order->isTransfer());

        return response()->json([
            'status' => true,
            'message' => $transfer
                ? 'สั่งซื้อแล้ว โอนเงินแล้วแนบสลิปในคำสั่งซื้อได้เลย'
                : 'สั่งซื้อแล้ว รอร้านจัดส่ง',
            'orders' => $orders->map(fn (Order $order) => $order->toPayload($user))->values(),
        ], $status);
    }

    // ตรวจว่าทำรายการนี้ได้ แล้วทำ → ส่งคำสั่งซื้อล่าสุดกลับ
    // work(allowed) คืน JsonResponse เมื่อไม่สำเร็จ / false เมื่อสถานะเปลี่ยนไปก่อน (409)
    // allowed = ตรวจสิทธิ์ซ้ำกับข้อมูลล่าสุดตอนล็อกแถว (กดพร้อมกัน / อีกฝ่ายเปลี่ยนสถานะ / หมดเวลา)
    // message เป็น Closure ได้ (ข้อความที่รู้หลังทำเสร็จ เช่น ผลตรวจสลิป)
    private function act(Request $request, Order $order, string $action, string|Closure $message, Closure $work)
    {
        $user = $request->user();

        if ($denied = $this->denied($request, $order, $action)) {
            return $denied;
        }

        $result = $work(fn (Order $fresh) => in_array($action, $fresh->actionsFor($user), true));

        if ($result instanceof JsonResponse) {
            return $result;
        }

        if ($result === false) {
            return $this->changedStatus($order->refresh(), $user);
        }

        return response()->json([
            'status' => true,
            'message' => $message instanceof Closure ? $message() : $message,
            'order' => $order->refresh()->toPayload($user),
        ]);
    }

    // ทำรายการนี้ไม่ได้ → 404 (ไม่ใช่คำสั่งซื้อของเรา) / 409 (สถานะเปลี่ยนไปแล้ว)
    // เรียกก่อนตรวจข้อมูลที่ส่งมาได้ (ผู้ซื้อกดส่งสินค้า → 409 ไม่ใช่ "กรุณาเลือกขนส่ง")
    private function denied(Request $request, Order $order, string $action): ?JsonResponse
    {
        $user = $request->user();

        if (!$order->isBuyer($user) && !$order->isSeller($user)) {
            return $this->notFound();
        }

        Order::expireStale(fn ($query) => $query->whereKey($order->id));

        $order->refresh();

        if (!in_array($action, $order->actionsFor($user), true)) {
            return $this->changedStatus($order, $user);
        }

        return null;
    }

    private function changedStatus(Order $order, User $user): JsonResponse
    {
        return response()->json([
            'status' => false,
            'message' => 'คำสั่งซื้อนี้เปลี่ยนสถานะไปแล้ว ทำรายการนี้ไม่ได้',
            'order' => $order->toPayload($user),
        ], 409);
    }

    private function list(Request $request, $query, User $user, array $extra = [])
    {
        $data = $request->validate([
            'filter' => ['nullable', Rule::in(array_keys(self::FILTERS))],
        ]);

        $paginator = $query
            ->when($data['filter'] ?? null, fn ($orders, string $filter) => $filter === 'todo'
                // ร้าน: รวมคำสั่งซื้อที่ยกเลิกแล้วแต่ยังไม่คืนเงิน
                ? $orders->sellerTodo()
                : $orders->whereIn('status', self::FILTERS[$filter]))
            ->with(['shop', 'buyer', 'product.images'])
            ->latest('id')
            ->simplePaginate(self::PAGE_SIZE);

        return response()->json([
            'status' => true,
            'orders' => collect($paginator->items())
                ->map(fn (Order $order) => $order->toPayload($user))
                ->values(),
            'page' => $paginator->currentPage(),
            'has_more' => $paginator->hasMorePages(),
            ...$extra,
        ]);
    }

    // สินค้าที่ผู้ใช้คนนี้สั่งได้ (ไม่ได้ → คืนข้อความที่แอปแสดงได้เลย)
    private function findOrderable(User $user, int $productId): Product|JsonResponse
    {
        $product = Product::visibleInMarket()->with(['shop', 'images'])->find($productId);

        if (!$product || $this->blockedBetween($user, (int) $product->shop->user_id)) {
            return $this->fail('ไม่พบสินค้านี้ หรือสินค้าถูกซ่อนแล้ว', 404);
        }

        $reason = $product->orderBlockReason($user);

        return $reason === null ? $product : $this->fail($reason);
    }

    // บล็อกกันฝั่งใดฝั่งหนึ่ง → สั่งซื้อกันไม่ได้
    private function blockedBetween(User $user, int $otherId): bool
    {
        return $user->blockedUsers()->where('users.id', $otherId)->exists()
            || User::find($otherId)?->blockedUsers()->where('users.id', $user->id)->exists();
    }

    private function fail(string $message, int $status = 422)
    {
        return response()->json([
            'status' => false,
            'message' => $message,
        ], $status);
    }

    private function notFound()
    {
        return $this->fail('ไม่พบคำสั่งซื้อนี้', 404);
    }
}
