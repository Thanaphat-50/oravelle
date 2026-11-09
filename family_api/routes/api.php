<?php

use Illuminate\Http\Request;
use Illuminate\Support\Facades\Route;
use App\Http\Controllers\AccountDeletionRequestController;
use App\Http\Controllers\AddressController;
use App\Http\Controllers\CartController;
use App\Http\Controllers\AuthController;
use App\Http\Controllers\FamilyController;
use App\Http\Controllers\FamilyInvitationController;
use App\Http\Controllers\FollowController;
use App\Http\Controllers\HashtagController;
use App\Http\Controllers\HistoryController;
use App\Http\Controllers\LocationController;
use App\Http\Controllers\MapStatusController;
use App\Http\Controllers\PostController;
use App\Http\Controllers\ChatController;
use App\Http\Controllers\CommentController;
use App\Http\Controllers\CommunityController;
use App\Http\Controllers\DeviceTokenController;
use App\Http\Controllers\MarketController;
use App\Http\Controllers\MyProductController;
use App\Http\Controllers\MyShopController;
use App\Http\Controllers\MyPromotionController;
use App\Http\Controllers\ShopReviewController;
use App\Http\Controllers\ActivityController;
use App\Http\Controllers\ProfileController;
use App\Http\Controllers\SettingsController;
use App\Http\Controllers\SocialAuthController;
use App\Http\Controllers\NotificationController;
use App\Http\Controllers\OrderController;
use App\Http\Controllers\PasswordResetController;

Route::get('/user', function (Request $request) {
    return $request->user();
})->middleware('auth:sanctum');

Route::get('/test', function () {
    return response()->json([
        'status' => true,
        'message' => 'Family API is working'
    ]);
});

// จำกัดจำนวนครั้ง (ตั้งค่าใน AppServiceProvider)
Route::post('/register', [AuthController::class, 'register'])
    ->middleware('throttle:register');

Route::post('/login', [AuthController::class, 'login'])
    ->middleware('throttle:login');

// ลืมรหัสผ่าน: ขอรหัส 6 หลักทางอีเมล → ตั้งรหัสผ่านใหม่ (PasswordResetController)
Route::post('/password/forgot', [PasswordResetController::class, 'forgot'])
    ->middleware('throttle:password-reset');

Route::post('/password/reset', [PasswordResetController::class, 'reset'])
    ->middleware('throttle:password-reset');

// เข้าสู่ระบบ / สมัคร ด้วย Google, LINE, Facebook
Route::get('/auth/providers', [SocialAuthController::class, 'providers']);

Route::post('/auth/social/{provider}', [SocialAuthController::class, 'login'])
    ->middleware('throttle:login');

Route::post('/logout', [AuthController::class, 'logout'])
    ->middleware('auth:sanctum');

// ลบบัญชี (จำกัด 5 ครั้ง/นาที กันเดารหัสผ่าน)
// แอปเวอร์ชันเก่า: "ลบบัญชี" → ส่งคำขอลบแทน
Route::delete('/account', [AccountDeletionRequestController::class, 'store'])
    ->middleware(['auth:sanctum', 'throttle:5,1']);

Route::middleware('auth:sanctum')->group(function () {

    Route::post('/families', [
        FamilyController::class,
        'create'
    ]);

    Route::post('/families/join', [
        FamilyController::class,
        'join'
    ]);

    // ชวนเข้าครอบครัว / ขอเข้าครอบครัว
    Route::get('/family-invitations', [
        FamilyInvitationController::class,
        'index'
    ]);

    Route::post('/family-invitations', [
        FamilyInvitationController::class,
        'invite'
    ])->middleware('throttle:ugc');

    Route::post('/users/{user}/family-request', [
        FamilyInvitationController::class,
        'request'
    ])->middleware('throttle:ugc');

    Route::post('/family-invitations/{invitation}/accept', [
        FamilyInvitationController::class,
        'accept'
    ]);

    Route::post('/family-invitations/{invitation}/decline', [
        FamilyInvitationController::class,
        'decline'
    ]);

    Route::delete('/family-invitations/{invitation}', [
        FamilyInvitationController::class,
        'cancel'
    ]);

    Route::get('/families/current', [
        FamilyController::class,
        'current'
    ]);

    Route::post('/location', [
        LocationController::class,
        'update'
    ]);

    Route::get('/family/locations', [
        LocationController::class,
        'familyLocations'
    ]);

    // เส้นทางตามถนนไปหาสมาชิก (Google Routes API)
    Route::get('/family/members/{user}/route', [
        LocationController::class,
        'route'
    ])->middleware('throttle:route');

    // แฮชแท็กยอดนิยมในชุมชน (ปุ่มลัดตอนเขียนโพสต์)
    Route::get('/hashtags/popular', [
        HashtagController::class,
        'popular'
    ]);

    // รายละเอียดตำแหน่งสมาชิก: หมู่บ้าน/ชุมชน + สถานที่ใกล้เคียง
    Route::get('/family/members/{user}/place', [
        LocationController::class,
        'place'
    ])->middleware('throttle:place');

    Route::get('/posts', [
        PostController::class,
        'index'
    ]);

    // throttle:ugc = กันสแปมโพสต์/ความคิดเห็น/รายงาน (ตั้งค่าใน AppServiceProvider)
    Route::post('/posts', [
        PostController::class,
        'store'
    ])->middleware('throttle:ugc');

    Route::get('/posts/{post}', [
        PostController::class,
        'show'
    ]);

    Route::delete('/posts/{post}', [
        PostController::class,
        'destroy'
    ]);

    Route::post('/posts/{post}/comments', [
        CommentController::class,
        'store'
    ])->middleware('throttle:ugc');

    Route::post('/posts/{post}/report', [
        PostController::class,
        'report'
    ])->middleware('throttle:ugc');

    Route::post('/posts/{post}/like', [
        PostController::class,
        'like'
    ])->middleware('throttle:ugc');

    // ลิงก์อัปโหลดวิดีโอตรงเข้า Bucket (ก่อนสร้างโพสต์)
    Route::post('/posts/video-upload', [
        PostController::class,
        'videoUploadUrl'
    ])->middleware('throttle:ugc');

    // แชร์: ส่งต่อไปแอปอื่น / แชร์ซ้ำในชุมชน / ส่งให้ครอบครัว
    Route::post('/posts/{post}/share', [
        PostController::class,
        'share'
    ])->middleware('throttle:ugc');

    // ติดตามผู้ใช้อื่น
    Route::get('/users/suggestions', [
        FollowController::class,
        'suggestions'
    ]);

    Route::post('/users/{user}/follow', [
        FollowController::class,
        'store'
    ])->middleware('throttle:ugc');

    Route::delete('/users/{user}/follow', [
        FollowController::class,
        'destroy'
    ]);

    // รายชื่อผู้ติดตาม / กำลังติดตาม ของเราเอง (หน้าโปรไฟล์)
    Route::get('/me/followers', [
        FollowController::class,
        'myFollowers'
    ]);

    Route::get('/me/following', [
        FollowController::class,
        'myFollowing'
    ]);

    // ประวัติการใช้งานของเรา
    Route::get('/me/history', [
        HistoryController::class,
        'index'
    ]);

    Route::delete('/me/history', [
        HistoryController::class,
        'clear'
    ]);

    // ข้อความบนแผนที่ (แสดง / เอาออก)
    Route::post('/posts/{post}/map-status', [
        MapStatusController::class,
        'store'
    ]);

    Route::delete('/posts/{post}/map-status', [
        MapStatusController::class,
        'destroy'
    ]);

    Route::post('/comments/{comment}/report', [
        CommentController::class,
        'report'
    ])->middleware('throttle:ugc');

    // ชุมชน: กฎชุมชน และการบล็อกผู้ใช้
    Route::post('/community/accept-terms', [
        CommunityController::class,
        'acceptTerms'
    ]);

    Route::get('/blocks', [
        CommunityController::class,
        'blocks'
    ]);

    Route::post('/users/{user}/block', [
        CommunityController::class,
        'block'
    ]);

    Route::delete('/users/{user}/block', [
        CommunityController::class,
        'unblock'
    ]);

    // แชทส่วนตัว (คนในครอบครัวเดียวกัน)
    Route::get('/chats', [
        ChatController::class,
        'index'
    ]);

    Route::get('/chats/unread-count', [
        ChatController::class,
        'unreadCount'
    ]);

    Route::post('/chats', [
        ChatController::class,
        'open'
    ]);

    Route::get('/chats/{conversation}/messages', [
        ChatController::class,
        'messages'
    ]);

    Route::post('/chats/{conversation}/messages', [
        ChatController::class,
        'send'
    ])->middleware('throttle:chat');

    Route::delete('/chats/{conversation}/messages/{message}', [
        ChatController::class,
        'destroy'
    ]);

    // บัญชี Google / LINE / Facebook ที่เชื่อมไว้ (หน้าตั้งค่า)
    Route::get('/social-accounts', [
        SocialAuthController::class,
        'index'
    ]);

    Route::post('/social-accounts/{provider}', [
        SocialAuthController::class,
        'link'
    ])->middleware('throttle:login');

    Route::delete('/social-accounts/{provider}', [
        SocialAuthController::class,
        'unlink'
    ]);

    // คำขอลบบัญชี (ผู้ดูแลเป็นคนลบ)
    Route::get('/account/deletion-request', [
        AccountDeletionRequestController::class,
        'show'
    ]);

    Route::post('/account/deletion-request', [
        AccountDeletionRequestController::class,
        'store'
    ])->middleware('throttle:5,1');

    Route::delete('/account/deletion-request', [
        AccountDeletionRequestController::class,
        'destroy'
    ]);

    // มือถือสำหรับแจ้งเตือนเด้ง (ออกจากระบบแล้วถูกลบเอง)
    Route::post('/device-tokens', [
        DeviceTokenController::class,
        'store'
    ]);

    Route::get('/users/{user}/profile', [
        CommunityController::class,
        'profile'
    ]);

    Route::post('/users/{user}/report', [
        CommunityController::class,
        'report'
    ])->middleware('throttle:ugc');

    Route::delete('/comments/{comment}', [
        CommentController::class,
        'destroy'
    ]);

    // ตลาด: ฝั่งผู้ซื้อ
    Route::get('/market/products', [
        MarketController::class,
        'products'
    ]);

    Route::get('/market/products/{product}', [
        MarketController::class,
        'showProduct'
    ]);

    Route::post('/market/products/{product}/report', [
        MarketController::class,
        'reportProduct'
    ])->middleware('throttle:ugc');

    // ร้านแนะนำ (ร้านที่เช่าพื้นที่) บนสุดของตลาด
    Route::get('/market/products/{product}/reviews', [
        MarketController::class,
        'productReviews'
    ]);

    Route::post('/market/products/{product}/save', [
        MarketController::class,
        'save'
    ]);

    Route::delete('/market/products/{product}/save', [
        MarketController::class,
        'unsave'
    ]);

    Route::get('/market/saved-products', [
        MarketController::class,
        'savedProducts'
    ]);

    Route::get('/market/featured', [
        MarketController::class,
        'featured'
    ]);

    Route::get('/market/shops/{shop}', [
        MarketController::class,
        'showShop'
    ]);

    Route::post('/market/shops/{shop}/report', [
        MarketController::class,
        'reportShop'
    ])->middleware('throttle:ugc');

    // สินค้าช่องแนะนำ (ชำระเงินแล้ว) ทั้งหมด / ตามหมวด
    Route::get('/market/featured-products', [
        MarketController::class,
        'featuredProducts'
    ]);

    // รีวิวร้าน
    Route::get('/market/shops/{shop}/reviews', [
        ShopReviewController::class,
        'index'
    ]);

    Route::post('/market/shops/{shop}/reviews', [
        ShopReviewController::class,
        'store'
    ])->middleware('throttle:ugc');

    Route::delete('/market/shops/{shop}/reviews', [
        ShopReviewController::class,
        'destroy'
    ]);

    // ตลาด: ร้านของฉัน (ฝั่งผู้ขาย)
    Route::get('/my-shop', [
        MyShopController::class,
        'show'
    ]);

    Route::post('/my-shop', [
        MyShopController::class,
        'store'
    ])->middleware('throttle:ugc');

    Route::post('/my-shop/update', [
        MyShopController::class,
        'update'
    ])->middleware('throttle:ugc');

    // รูปหน้าร้าน + วิดีโอแนะนำร้าน
    Route::post('/my-shop/media', [
        MyShopController::class,
        'updateMedia'
    ])->middleware('throttle:ugc');

    // ตลาด: สินค้าในร้านของฉัน
    Route::get('/my-shop/products', [
        MyProductController::class,
        'index'
    ]);

    Route::post('/my-shop/products', [
        MyProductController::class,
        'store'
    ])->middleware('throttle:ugc');

    Route::post('/my-shop/products/{product}/update', [
        MyProductController::class,
        'update'
    ])->middleware('throttle:ugc');

    Route::patch('/my-shop/products/{product}/status', [
        MyProductController::class,
        'updateStatus'
    ]);

    Route::delete('/my-shop/products/{product}', [
        MyProductController::class,
        'destroy'
    ]);

    // วิดีโอแนะนำสินค้า
    Route::post('/my-shop/products/{product}/video', [
        MyProductController::class,
        'updateVideo'
    ])->middleware('throttle:ugc');

    Route::delete('/my-shop/products/{product}/video', [
        MyProductController::class,
        'destroyVideo'
    ]);

    // ช่องแนะนำสินค้า (โอนพร้อมเพย์ + แนบสลิป)
    Route::get('/my-shop/products/{product}/promotion', [
        MyPromotionController::class,
        'show'
    ]);

    Route::post('/my-shop/products/{product}/promotion', [
        MyPromotionController::class,
        'store'
    ])->middleware('throttle:ugc');

    Route::get('/my-shop/promotions', [
        MyPromotionController::class,
        'index'
    ]);

    Route::post('/my-shop/promotions/{promotion}/slip', [
        MyPromotionController::class,
        'uploadSlip'
    ])->middleware('throttle:ugc');

    Route::post('/my-shop/promotions/{promotion}/cancel', [
        MyPromotionController::class,
        'cancel'
    ]);

    // ช่องร้านแนะนำ (แบนเนอร์ใหญ่ ราคาแพงกว่า)
    Route::get('/my-shop/promotion', [
        MyPromotionController::class,
        'showShop'
    ]);

    Route::post('/my-shop/promotion', [
        MyPromotionController::class,
        'storeShop'
    ])->middleware('throttle:ugc');

    Route::post('/my-shop/shop-promotions/{shopPromotion}/slip', [
        MyPromotionController::class,
        'uploadShopSlip'
    ])->middleware('throttle:ugc');

    Route::post('/my-shop/shop-promotions/{shopPromotion}/cancel', [
        MyPromotionController::class,
        'cancelShop'
    ]);

    // สั่งซื้อสินค้า (ผู้ซื้อ + ร้าน) ดู App\Models\Order
    Route::get('/orders/checkout', [
        OrderController::class,
        'checkout'
    ]);

    Route::post('/orders/preview', [
        OrderController::class,
        'preview'
    ]);

    Route::get('/orders', [
        OrderController::class,
        'index'
    ]);

    // ตะกร้าสินค้า
    Route::get('/cart', [
        CartController::class,
        'index'
    ]);

    Route::get('/cart/count', [
        CartController::class,
        'count'
    ]);

    Route::post('/cart', [
        CartController::class,
        'store'
    ])->middleware('throttle:ugc');

    Route::patch('/cart/{cartItem}', [
        CartController::class,
        'update'
    ]);

    Route::delete('/cart/{cartItem}', [
        CartController::class,
        'destroy'
    ]);

    // ที่อยู่จัดส่งของฉัน
    Route::get('/addresses', [
        AddressController::class,
        'index'
    ]);

    Route::post('/addresses', [
        AddressController::class,
        'store'
    ])->middleware('throttle:ugc');

    Route::put('/addresses/{address}', [
        AddressController::class,
        'update'
    ]);

    Route::delete('/addresses/{address}', [
        AddressController::class,
        'destroy'
    ]);

    Route::post('/orders', [
        OrderController::class,
        'store'
    ])->middleware('throttle:ugc');

    Route::get('/my-shop/orders', [
        OrderController::class,
        'shopIndex'
    ]);

    Route::get('/my-shop/sales', [
        OrderController::class,
        'shopSales'
    ]);

    Route::get('/orders/{order}', [
        OrderController::class,
        'show'
    ]);

    Route::post('/orders/{order}/slip', [
        OrderController::class,
        'uploadSlip'
    ])->middleware('throttle:ugc');

    Route::post('/orders/{order}/confirm-payment', [
        OrderController::class,
        'confirmPayment'
    ]);

    Route::post('/orders/{order}/reject-slip', [
        OrderController::class,
        'rejectSlip'
    ]);

    Route::post('/orders/{order}/ship', [
        OrderController::class,
        'ship'
    ]);

    Route::post('/orders/{order}/reviews', [
        OrderController::class,
        'review'
    ])->middleware('throttle:ugc');

    Route::post('/orders/{order}/received', [
        OrderController::class,
        'received'
    ]);

    Route::post('/orders/{order}/cancel', [
        OrderController::class,
        'cancel'
    ]);

    Route::post('/orders/{order}/refund', [
        OrderController::class,
        'refund'
    ]);

    Route::get('/activities', [
        ActivityController::class,
        'index'
    ]);

    Route::post('/activities', [
        ActivityController::class,
        'store'
    ]);

    Route::patch('/activities/{activity}/toggle', [
        ActivityController::class,
        'toggle'
    ]);

    // แก้ไขชื่อ / รายละเอียด / วันเวลา (เจ้าของเท่านั้น)
    Route::patch('/activities/{activity}', [
        ActivityController::class,
        'update'
    ]);

    Route::delete('/activities/{activity}', [
        ActivityController::class,
        'destroy'
    ]);

    // ตั้งค่า: แชร์ตำแหน่ง และการแจ้งเตือน
    Route::get('/settings', [
        SettingsController::class,
        'show'
    ]);

    Route::put('/settings', [
        SettingsController::class,
        'update'
    ]);

    Route::get('/profile', [
        ProfileController::class,
        'show'
    ]);

    Route::put('/profile', [
        ProfileController::class,
        'update'
    ]);

    Route::put('/profile/password', [
        ProfileController::class,
        'changePassword'
    ]);

    Route::post('/profile/photo',[
        ProfileController::class,
        'uploadPhoto'
    ]);

    Route::delete('/profile/photo',[
        ProfileController::class,
        'deletePhoto'
    ]);

    Route::put('/families/{family}', [
        FamilyController::class,
        'update'
    ]);

    Route::post('/families/regenerate-code', [
        FamilyController::class,
        'regenerateCode'
    ]);

    Route::delete('/families/members/{userId}', [
        FamilyController::class,
        'removeMember'
    ]);

    Route::post('/families/leave', [
        FamilyController::class,
        'leave'
    ]);

    Route::post('/families/transfer-owner/{userId}', [
            FamilyController::class,
            'transferOwner'
        ]
    );

    Route::delete('/families/current', [
        FamilyController::class,
        'deleteFamily'
    ]);

    Route::get('/notifications', [
        NotificationController::class,
        'index'
    ]);

    Route::get('/notifications/unread-count', [
        NotificationController::class,
        'unreadCount'
    ]);

    Route::patch('/notifications/read-all', [
        NotificationController::class,
        'markAllAsRead'
    ]);

    Route::patch('/notifications/{notification}/read', [
        NotificationController::class,
        'markAsRead'
    ]);

    // ต้องอยู่ก่อน /notifications/{notification}
    // ไม่งั้นคำว่า "read" จะถูกมองเป็นเลข ID
    Route::delete('/notifications/read', [
        NotificationController::class,
        'clearRead'
    ]);

    Route::delete('/notifications/{notification}', [
        NotificationController::class,
        'destroy'
    ]);

    Route::patch(
    '/activities/{activity}/visibility',
    [
        ActivityController::class,
        'updateVisibility'
    ]);

});