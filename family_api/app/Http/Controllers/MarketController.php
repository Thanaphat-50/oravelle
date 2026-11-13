<?php

namespace App\Http\Controllers;

use App\Models\AppNotification;
use App\Models\Product;
use App\Models\ProductPromotion;
use App\Models\ProductReport;
use App\Models\ProductReview;
use App\Models\SavedProduct;
use App\Models\Shop;
use App\Models\ShopReview;
use App\Models\ShopReport;
use App\Models\User;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Http\Request;
use Illuminate\Support\Str;
use Illuminate\Validation\Rule;

// =======================================================
// ตลาด (ฝั่งผู้ซื้อ)
// - เห็นเฉพาะสินค้าที่แสดงอยู่ของร้านที่เปิดขาย
// - ไม่แสดงสินค้าที่เรารายงานแล้ว และร้านของคนที่เราบล็อก
// =======================================================

class MarketController extends Controller
{
    private const PAGE_SIZE = 20;

    // =====================================================
    // GET /api/market/products?q=&category=&province=&page=
    // =====================================================

    public function products(Request $request)
    {
        $filters = $request->validate([
            'q' => 'nullable|string|max:100',
            'category' => ['nullable', Rule::in(array_keys(config('market.categories')))],
            'province' => ['nullable', Rule::in(config('market.provinces'))],
        ]);

        $user = $request->user();

        $term = trim($filters['q'] ?? '');

        $paginator = $this->visibleProductsFor($user)
            ->when($term !== '', function (Builder $query) use ($term) {
                $like = '%' . addcslashes($term, '%_\\') . '%';

                $query->where(function (Builder $match) use ($like) {
                    $match->where('title', 'like', $like)
                        ->orWhere('description', 'like', $like)
                        ->orWhereHas('shop', fn ($shops) => $shops->where('name', 'like', $like));
                });
            })
            ->when($filters['category'] ?? null, fn ($query, $category) => $query->where('category', $category))
            ->when(
                $filters['province'] ?? null,
                fn ($query, $province) => $query->whereHas('shop', fn ($shops) => $shops->where('province', $province))
            )
            ->with(['images', 'shop'])
            ->orderByDesc('created_at')
            ->orderByDesc('id')
            ->simplePaginate(self::PAGE_SIZE);

        return response()->json([
            'status' => true,
            'products' => collect($paginator->items())
                ->map(fn (Product $product) => $this->productCard($product))
                ->values(),
            'page' => $paginator->currentPage(),
            'has_more' => $paginator->hasMorePages(),
        ]);
    }

    // =====================================================
    // GET /api/market/products/{product}
    // เจ้าของร้านดูสินค้าตัวเองได้เสมอ (ดูตัวอย่างก่อนร้านเปิด)
    // =====================================================

    public function showProduct(Request $request, Product $product)
    {
        $user = $request->user();

        $product->load(['images', 'shop', 'variants']);

        $isMine = (int) $product->shop->user_id === (int) $user->id;

        if (!$isMine && !$this->visibleProductsFor($user)->whereKey($product->id)->exists()) {
            return $this->productNotFound();
        }

        // นับยอดเข้าชม (ไม่นับเจ้าของร้าน และไม่แตะ updated_at)
        if (!$isMine) {
            Product::whereKey($product->id)->toBase()->increment('views');
        }

        $shop = $product->shop;

        $fee = (float) ($product->shipping_fee ?? 0);

        return response()->json([
            'status' => true,
            'product' => [
                ...$product->only([
                    'id', 'title', 'description', 'price', 'stock', 'shipping_fee',
                    'category', 'status', 'created_at',
                ]),
                'sold_count' => $product->soldCount(),
                // ตัวเลือกสินค้า (สี ขนาด รุ่น) แต่ละตัวมีราคา/สต็อกของตัวเอง
                'option_name' => $product->option_name,
                'variants' => $product->variants->map(fn ($variant) => $variant->toPayload())->values(),
                'price_range' => $product->priceRange(),
                'is_saved' => SavedProduct::where('user_id', $user->id)->where('product_id', $product->id)->exists(),
                // วิธีรับสินค้าของร้าน + ค่าส่งของสินค้านี้
                'delivery_options' => collect($shop->delivery_methods ?? [])
                    ->filter(fn ($key) => is_string($key) && array_key_exists($key, config('market.delivery_methods')))
                    ->map(fn (string $key) => [
                        'key' => $key,
                        'label' => config("market.delivery_methods.{$key}"),
                        'shipping_fee' => in_array($key, config('market.shipping_fee_methods'), true) ? $fee : 0,
                    ])
                    ->values(),
                'images' => $product->images,
                'video_url' => $product->video_url,
                'video_thumbnail_url' => $product->video_thumbnail_url,
                'is_featured' => $product->isFeatured(),
                'is_mine' => $isMine,
                'sold_out' => $product->isSoldOut(),
                // ปุ่มสั่งซื้อ: reason = เหตุผลที่สั่งในแอปไม่ได้ (แสดงแทนปุ่ม)
                'order' => [
                    'available' => ($reason = $product->orderBlockReason($user)) === null,
                    'reason' => $reason,
                ],
            ],
            'shop' => [
                ...$this->shopPayload($shop),
                'rating' => ShopReview::summaryFor($shop->id),
                'stats' => $shop->salesStats(),
                'products_count' => $this->onlyShown($shop->products())->count(),
                'member_since' => $shop->approved_at ?? $shop->created_at,
            ],
            // รีวิวจากผู้ซื้อจริง (ล่าสุด 3 รายการ)
            'reviews' => ProductReview::where('product_id', $product->id)
                ->visible()
                ->whereNotIn('user_id', $user->blockedUsers()->pluck('users.id'))
                ->with('user')
                ->latest()
                ->limit(3)
                ->get()
                ->map(fn (ProductReview $review) => $review->toPayload($user->id))
                ->values(),
            'review_summary' => ProductReview::summaryFor($product->id),
            // สินค้าอื่นของร้านเดียวกัน
            'other_products' => $this->visibleProductsFor($user)
                ->where('shop_id', $shop->id)
                ->whereKeyNot($product->id)
                ->with(['images', 'shop'])
                ->latest()
                ->limit(10)
                ->get()
                ->map(fn (Product $other) => $this->productCard($other, false))
                ->values(),
        ]);
    }

    // =====================================================
    // GET /api/market/products/{product}/reviews?page=  รีวิวสินค้าทั้งหมด
    // =====================================================

    public function productReviews(Request $request, Product $product)
    {
        $user = $request->user();

        $paginator = ProductReview::where('product_id', $product->id)
            ->visible()
            ->whereNotIn('user_id', $user->blockedUsers()->pluck('users.id'))
            ->with('user')
            ->latest()
            ->latest('id')
            ->simplePaginate(self::PAGE_SIZE);

        return response()->json([
            'status' => true,
            'summary' => ProductReview::summaryFor($product->id),
            'reviews' => collect($paginator->items())
                ->map(fn (ProductReview $review) => $review->toPayload($user->id))
                ->values(),
            'page' => $paginator->currentPage(),
            'has_more' => $paginator->hasMorePages(),
        ]);
    }

    // =====================================================
    // POST / DELETE /api/market/products/{product}/save  บันทึกสินค้า
    // GET /api/market/saved-products                     สินค้าที่บันทึกไว้
    // =====================================================

    public function save(Request $request, Product $product)
    {
        $user = $request->user();

        if (!$this->visibleProductsFor($user)->whereKey($product->id)->exists()
            && (int) $product->shop?->user_id !== (int) $user->id) {
            return $this->productNotFound();
        }

        SavedProduct::firstOrCreate(['user_id' => $user->id, 'product_id' => $product->id]);

        return response()->json([
            'status' => true,
            'message' => 'บันทึกสินค้าแล้ว',
            'is_saved' => true,
        ]);
    }

    public function unsave(Request $request, Product $product)
    {
        SavedProduct::where('user_id', $request->user()->id)->where('product_id', $product->id)->delete();

        return response()->json([
            'status' => true,
            'message' => 'เอาออกจากที่บันทึกแล้ว',
            'is_saved' => false,
        ]);
    }

    public function savedProducts(Request $request)
    {
        $user = $request->user();

        $paginator = $this->visibleProductsFor($user)
            ->join('saved_products', 'saved_products.product_id', '=', 'products.id')
            ->where('saved_products.user_id', $user->id)
            ->select('products.*')
            ->with(['images', 'shop'])
            ->orderByDesc('saved_products.created_at')
            ->orderByDesc('saved_products.id')
            ->simplePaginate(self::PAGE_SIZE);

        return response()->json([
            'status' => true,
            'products' => collect($paginator->items())
                ->map(fn (Product $product) => $this->productCard($product))
                ->values(),
            'page' => $paginator->currentPage(),
            'has_more' => $paginator->hasMorePages(),
        ]);
    }

    // =====================================================
    // GET /api/market/featured
    // ร้านแนะนำ (ร้านที่เช่าพื้นที่) สำหรับแบนเนอร์ด้านบนตลาด
    // - สลับลำดับทุกครั้ง ให้ทุกร้านที่เช่ามีโอกาสขึ้นก่อนเท่ากัน
    // - ส่งรูปสินค้าล่าสุดไม่เกิน 3 รูปไปแสดงในแบนเนอร์
    // =====================================================

    public function featured(Request $request)
    {
        $blockedIds = $request->user()->blockedUsers()->pluck('users.id');

        $shops = Shop::featured()
            ->whereNotIn('user_id', $blockedIds)
            ->withCount(['products as products_count' => fn ($products) => $this->onlyShown($products)])
            ->with([
                'products' => fn ($products) => $this->onlyShown($products)->latest(),
                'products.images',
            ])
            ->inRandomOrder()
            ->limit((int) config('market.featured_slots'))
            ->get();

        return response()->json([
            'status' => true,
            'shops' => $shops->map(fn (Shop $shop) => [
                ...$this->shopPayload($shop),
                'products_count' => $shop->products_count,
                'preview_images' => $shop->products
                    ->map(fn (Product $product) => $product->images->first()?->url)
                    ->filter()
                    ->take(3)
                    ->values(),
            ])->values(),
        ]);
    }

    // =====================================================
    // GET /api/market/shops/{shop}
    // ข้อมูลร้าน + สินค้าทั้งหมดที่แสดงอยู่
    // =====================================================

    public function showShop(Request $request, Shop $shop)
    {
        $user = $request->user();

        $isMine = (int) $shop->user_id === (int) $user->id;

        $blocked = $user->blockedUsers()->where('users.id', $shop->user_id)->exists();

        if (!$isMine && (!$shop->isActive() || $blocked)) {
            return response()->json([
                'status' => false,
                'message' => 'ไม่พบร้านนี้ หรือร้านปิดอยู่',
            ], 404);
        }

        $products = $this->onlyShown($shop->products())
            ->whereDoesntHave('reports', fn ($reports) => $reports->where('user_id', $user->id))
            ->with('images')
            ->latest()
            ->get();

        $blockedIds = $user->blockedUsers()->pluck('users.id');

        $reviews = ShopReview::where('shop_id', $shop->id)
            ->visible()
            ->whereNotIn('user_id', $blockedIds)
            ->with('user')
            ->latest()
            ->limit(3)
            ->get();

        $myReview = ShopReview::where('shop_id', $shop->id)
            ->where('user_id', $user->id)
            ->with('user')
            ->first();

        return response()->json([
            'status' => true,
            'shop' => [
                ...$this->shopPayload($shop),
                'is_mine' => $isMine,
                'images' => $shop->images()->get(),
                'trust' => $this->trustInfo($shop, $products->count()),
                'rating' => ShopReview::summaryFor($shop->id),
            ],
            'reviews' => $reviews->map(fn (ShopReview $review) => $review->toPayload($user->id))->values(),
            'my_review' => $myReview?->toPayload($user->id),
            'products' => $products->map(fn (Product $product) => $this->productCard($product, false))->values(),
        ]);
    }

    // =====================================================
    // GET /api/market/featured-products?category=
    // สินค้าช่องแนะนำ (ชำระเงินแล้วเท่านั้น) สลับลำดับทุกครั้ง
    // ไม่ระบุหมวด → รวมทุกหมวด
    // =====================================================

    public function featuredProducts(Request $request)
    {
        $data = $request->validate([
            'category' => ['nullable', Rule::in(array_keys(config('market.categories')))],
        ]);

        $category = $data['category'] ?? null;

        $products = $this->visibleProductsFor($request->user())
            ->featuredNow()
            ->when($category, fn (Builder $query, string $value) => $query->where('category', $value))
            ->with(['images', 'shop'])
            ->inRandomOrder()
            ->limit($category ? ProductPromotion::slotsPerCategory() : 100)
            ->get();

        return response()->json([
            'status' => true,
            'products' => $products->map(fn (Product $product) => $this->productCard($product))->values(),
            'slots_per_category' => ProductPromotion::slotsPerCategory(),
        ]);
    }

    // =====================================================
    // POST /api/market/products/{product}/report
    // =====================================================

    public function reportProduct(Request $request, Product $product)
    {
        $data = $this->validateReport($request);

        $user = $request->user();

        if ((int) $product->shop->user_id === (int) $user->id) {
            return $this->cannotReportOwn();
        }

        if (!$this->visibleProductsFor($user)->whereKey($product->id)->exists()) {
            return $this->productNotFound();
        }

        // รายงานซ้ำไม่นับเพิ่ม
        $report = ProductReport::firstOrCreate(
            ['product_id' => $product->id, 'user_id' => $user->id],
            ['reason' => $data['reason'], 'details' => $data['details'] ?? null]
        );

        $count = $product->reports()->count();

        // ซ่อนอัตโนมัติเมื่อถูกรายงานครบ (รอ Admin ตรวจ)
        $hidden = $product->hidden_at === null && $count >= config('market.auto_hide_reports');

        if ($hidden) {
            $product->hidden_at = now();
            $product->save();
        }

        if ($report->wasRecentlyCreated) {
            $this->notifyAdmins(
                'มีผู้รายงานสินค้า',
                '"' . $product->title . '" (ร้าน ' . $product->shop->name . '): '
                    . (config('market.report_reasons')[$data['reason']] ?? $data['reason'])
                    . " · รวม {$count} คน" . ($hidden ? ' · ซ่อนสินค้าอัตโนมัติแล้ว' : ''),
                ['shop_id' => $product->shop_id, 'product_id' => $product->id]
            );
        }

        return response()->json([
            'status' => true,
            'message' => 'ขอบคุณที่รายงาน ผู้ดูแลจะตรวจสอบสินค้านี้',
        ]);
    }

    // =====================================================
    // POST /api/market/shops/{shop}/report
    // =====================================================

    public function reportShop(Request $request, Shop $shop)
    {
        $data = $this->validateReport($request);

        $user = $request->user();

        if ((int) $shop->user_id === (int) $user->id) {
            return $this->cannotReportOwn();
        }

        if (!$shop->isActive()) {
            return response()->json([
                'status' => false,
                'message' => 'ไม่พบร้านนี้ หรือร้านปิดอยู่',
            ], 404);
        }

        $report = ShopReport::firstOrCreate(
            ['shop_id' => $shop->id, 'user_id' => $user->id],
            ['reason' => $data['reason'], 'details' => $data['details'] ?? null]
        );

        if ($report->wasRecentlyCreated) {
            $count = $shop->reports()->count();

            // ถูกรายงานจากหลายคน → ปิดร้านชั่วคราวรอผู้ดูแล (แจ้งเจ้าของร้านด้วย)
            $suspended = $count >= config('market.auto_suspend_shop_reports');

            if ($suspended) {
                $shop->suspend(Shop::AUTO_REPORT_REASON);
            }

            $this->notifyAdmins(
                'มีผู้รายงานร้านค้า',
                'ร้าน "' . $shop->name . '": '
                    . (config('market.report_reasons')[$data['reason']] ?? $data['reason'])
                    . (filled($data['details'] ?? null) ? ' — ' . Str::limit($data['details'], 120) : '')
                    . " · รวม {$count} คน" . ($suspended ? ' · ปิดร้านชั่วคราวแล้ว' : ''),
                ['shop_id' => $shop->id]
            );
        }

        return response()->json([
            'status' => true,
            'message' => 'ขอบคุณที่รายงาน ผู้ดูแลจะตรวจสอบร้านนี้',
        ]);
    }

    // =====================================================
    // HELPERS
    // =====================================================

    // สินค้าที่ผู้ใช้คนนี้เห็นในตลาด
    private function visibleProductsFor(User $user): Builder
    {
        $blockedIds = $user->blockedUsers()->pluck('users.id');

        return Product::query()
            ->visibleInMarket()
            ->whereHas('shop', fn ($shops) => $shops->whereNotIn('user_id', $blockedIds))
            ->whereDoesntHave('reports', fn ($reports) => $reports->where('user_id', $user->id));
    }

    // สินค้าที่เจ้าของร้านไม่ได้ซ่อน และไม่ถูกซ่อนโดย Admin
    private function onlyShown($query)
    {
        return $query->where('status', Product::STATUS_ACTIVE)->whereNull('hidden_at');
    }

    // ข้อมูลสินค้าแบบย่อสำหรับการ์ดในตาราง
    // สินค้าที่ผู้ใช้คนนี้บันทึกไว้ (โหลดครั้งเดียวต่อคำขอ) → ♡ บนการ์ดสินค้า
    private ?array $savedProductIds = null;

    private function isSavedByViewer(Product $product): bool
    {
        if ($this->savedProductIds === null) {
            $userId = request()->user()?->id;

            $this->savedProductIds = $userId
                ? SavedProduct::where('user_id', $userId)->pluck('product_id')
                    ->map(fn ($id) => (int) $id)->flip()->all()
                : [];
        }

        return isset($this->savedProductIds[(int) $product->id]);
    }

    private function productCard(Product $product, bool $withShop = true): array
    {
        return [
            ...$product->only(['id', 'title', 'price', 'category', 'created_at']),
            'is_saved' => $this->isSavedByViewer($product),
            'image_url' => $product->images->first()?->url,
            'images_count' => $product->images->count(),
            'is_featured' => $product->isFeatured(),
            'has_video' => $product->video_path !== null,
            'sold_out' => $product->isSoldOut(),
            // ผู้ขายเลือกให้การ์ดเล่นวิดีโอ (แอปเล่นเองเมื่อเลื่อนมาหยุดที่การ์ด)
            ...($product->showsVideoOnCard() ? [
                'card_video_url' => $product->video_url,
                'card_video_thumbnail_url' => $product->video_thumbnail_url,
            ] : []),
            ...($withShop ? [
                'shop' => [
                    'id' => $product->shop->id,
                    'name' => $product->shop->name,
                    'province' => $product->shop->province,
                    'district' => $product->shop->district,
                    'logo_url' => $product->shop->logo_url,
                ],
            ] : []),
        ];
    }

    // ข้อมูลร้านที่เปิดให้ผู้ซื้อเห็น (ไม่มีข้อมูลเจ้าของบัญชี)
    private function shopPayload(Shop $shop): array
    {
        return [
            ...$this->shopPublicFields($shop),
            'payment_methods' => $shop->readyPaymentMethods(),
            'accepts_orders' => $shop->acceptsOrders(),
        ];
    }

    private function shopPublicFields(Shop $shop): array
    {
        return $shop->only([
            'id',
            'name',
            'description',
            'category',
            'phone',
            'line_id',
            'province',
            'district',
            'opening_hours',
            'delivery_methods',
            'ship_within_days',
            'logo_url',
            'video_url',
            'video_thumbnail_url',
            'is_featured',
        ]);
    }

    // ข้อมูลความน่าเชื่อถือที่ระบบคำนวณเอง (ไม่เปิดเผยข้อมูลส่วนตัวของเจ้าของ)
    private function trustInfo(Shop $shop, int $productsCount): array
    {
        $owner = $shop->owner;

        return [
            'approved_at' => $shop->approved_at,
            'member_since' => $owner?->created_at,
            // google / line / facebook (เข้าสู่ระบบด้วยบัญชีเหล่านี้)
            'login_methods' => $owner
                ? $owner->socialAccounts()->pluck('provider')->unique()->values()
                : [],
            'products_count' => $productsCount,
            'has_video' => $shop->video_path !== null,
        ];
    }

    // แจ้งผู้ดูแลทุกคน (แจ้งเตือนในแอป + เด้งบนมือถือ)
    private function notifyAdmins(string $title, string $message, array $data): void
    {
        foreach (User::where('is_admin', true)->pluck('id') as $adminId) {
            AppNotification::create([
                'user_id' => $adminId,
                'family_id' => null,
                'type' => 'market_report',
                'title' => $title,
                'message' => $message,
                'data' => $data,
                'is_read' => false,
            ]);
        }
    }

    private function validateReport(Request $request): array
    {
        return $request->validate([
            'reason' => ['required', Rule::in(array_keys(config('market.report_reasons')))],
            'details' => 'nullable|string|max:1000',
        ]);
    }

    private function productNotFound()
    {
        return response()->json([
            'status' => false,
            'message' => 'ไม่พบสินค้านี้ หรือสินค้าถูกซ่อนแล้ว',
        ], 404);
    }

    private function cannotReportOwn()
    {
        return response()->json([
            'status' => false,
            'message' => 'ไม่สามารถรายงานร้านหรือสินค้าของตัวเองได้',
        ], 422);
    }
}
