<?php

use Illuminate\Http\Request;
use Illuminate\Support\Facades\Route;
use App\Http\Controllers\AccountDeletionRequestController;
use App\Http\Controllers\AddressController;
use App\Http\Controllers\CartController;
use App\Http\Controllers\AuthController;
use App\Http\Controllers\FamilyController;
use App\Http\Controllers\GroupChatController;
use App\Http\Controllers\FamilyInvitationController;
use App\Http\Controllers\FollowController;
use App\Http\Controllers\HashtagController;
use App\Http\Controllers\HistoryController;
use App\Http\Controllers\LocationController;
use App\Http\Controllers\MapStatusController;
use App\Http\Controllers\PostController;
use App\Http\Controllers\CallController;
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
use App\Http\Controllers\SavedPostController;
use App\Http\Controllers\SearchController;
use App\Http\Controllers\SessionController;
use App\Http\Controllers\SettingsController;
use App\Http\Controllers\SocialAuthController;
use App\Http\Controllers\NotificationController;
use App\Http\Controllers\OrderController;
use App\Http\Controllers\PasswordResetController;
use App\Http\Controllers\SupportTicketController;

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

    // บันทึกโพสต์ไว้อ่าน (ส่วนตัว) — บันทึก/ยกเลิกส่งซ้ำได้ ผลเหมือนเดิม
    Route::get('/saved-posts', [SavedPostController::class, 'index']);
    Route::put('/posts/{post}/save', [SavedPostController::class, 'store'])->middleware('throttle:60,1');
    Route::delete('/posts/{post}/save', [SavedPostController::class, 'destroy'])->middleware('throttle:60,1');

    // แก้ไขข้อความโพสต์ของตัวเอง
    Route::patch('/posts/{post}', [
        PostController::class,
        'update'
    ])->middleware('throttle:ugc');

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

    // แชทกลุ่มครอบครัว (GroupChatController) — สิทธิ์จากสมาชิกกลุ่มปัจจุบัน ตรวจทุกเส้นทาง
    Route::middleware('throttle:group-chat')->group(function () {
        Route::post('/group-chat/open', [GroupChatController::class, 'open']);
        Route::get('/group-chats/{chat}/messages', [GroupChatController::class, 'messages'])->whereNumber('chat');
        Route::get('/group-chats/{chat}/messages/{message}', [GroupChatController::class, 'show'])->whereNumber(['chat', 'message']);
        Route::post('/group-chats/{chat}/read', [GroupChatController::class, 'read'])->whereNumber('chat');
        Route::put('/group-chats/{chat}/messages/{message}/reaction', [GroupChatController::class, 'react'])->whereNumber(['chat', 'message']);
        Route::delete('/group-chats/{chat}/messages/{message}/reaction', [GroupChatController::class, 'unreact'])->whereNumber(['chat', 'message']);
        Route::put('/group-chats/{chat}/mute', [GroupChatController::class, 'mute'])->whereNumber('chat');
    });
    Route::post('/group-chats/{chat}/messages', [GroupChatController::class, 'send'])
        ->whereNumber('chat')
        ->middleware('throttle:group-chat-send');

    // อุปกรณ์ที่เข้าสู่ระบบ (SessionController) — จัดการได้เฉพาะเซสชันของตัวเอง
    Route::middleware('throttle:sessions')->group(function () {
        Route::get('/sessions', [SessionController::class, 'index']);
        Route::put('/sessions/current', [SessionController::class, 'updateCurrent']);
        Route::post('/sessions/revoke-others', [SessionController::class, 'revokeOthers']);
        Route::delete('/sessions/{session}', [SessionController::class, 'destroy'])->whereNumber('session');
    });

    // ค้นหาโพสต์ (ชุมชน / ในกลุ่ม) และผู้ใช้ (SearchController)
    Route::middleware('throttle:search')->group(function () {
        Route::get('/search/posts', [SearchController::class, 'posts']);
        Route::get('/search/users', [SearchController::class, 'users']);
    });

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

    Route::put('/chats/{conversation}/messages/{message}/reaction', [ChatController::class, 'react'])
        ->middleware('throttle:chat');

    Route::delete('/chats/{conversation}/messages/{message}/reaction', [ChatController::class, 'unreact'])
        ->middleware('throttle:chat');

    Route::post('/chats/{conversation}/read', [ChatController::class, 'read'])
        ->middleware('throttle:chat');

    Route::post('/chats/{conversation}/messages', [
        ChatController::class,
        'send'
    ])->middleware('throttle:chat');

    Route::delete('/chats/{conversation}/messages/{message}', [
        ChatController::class,
        'destroy'
    ]);

    // ข้อความเดียว (ลิงก์ไฟล์/เสียงใหม่เมื่อลิงก์เดิมหมดอายุ)
    Route::get('/chats/{conversation}/messages/{message}', [ChatController::class, 'show'])
        ->whereNumber(['conversation', 'message'])
        ->middleware('throttle:chat');

    // โทรเสียง/วิดีโอคอล 1 ต่อ 1 (สถานะสาย + token LiveKit อายุสั้น) — เริ่มสายได้ไม่เกิน 10 ครั้ง/นาที
    Route::post('/calls', [CallController::class, 'start'])->middleware('throttle:10,1');
    Route::middleware('throttle:120,1')->group(function () {
        Route::get('/calls/active', [CallController::class, 'active']);
        Route::get('/calls/{call}', [CallController::class, 'show'])->whereNumber('call');
        Route::post('/calls/{call}/accept', [CallController::class, 'accept'])->whereNumber('call');
        Route::post('/calls/{call}/decline', [CallController::class, 'decline'])->whereNumber('call');
        Route::post('/calls/{call}/hangup', [CallController::class, 'hangup'])->whereNumber('call');
        Route::post('/calls/{call}/heartbeat', [CallController::class, 'heartbeat'])->whereNumber('call');
    });

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

    // ผู้ซื้อยืนยันว่าได้รับเงินคืนแล้ว
    Route::post('/orders/{order}/refund-received', [
        OrderController::class,
        'refundReceived'
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

    // รายละเอียดกิจกรรม (เปิดจากแจ้งเตือน) และตั้งเตือนของตัวเอง (สมาชิกที่เห็นกิจกรรมตั้งได้ ไม่ต้องมีสิทธิ์แก้ไข)
    Route::get('/activities/{activity}', [
        ActivityController::class,
        'show'
    ]);

    Route::put('/activities/{activity}/reminder', [
        ActivityController::class,
        'reminder'
    ])->middleware('throttle:30,1');

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


    // =====================================================
    // ศูนย์ช่วยเหลือ (SupportTicketController) — ทีมงานตอบใน /admin
    // =====================================================

    Route::get('/support/tickets', [SupportTicketController::class, 'index']);

    // ประกาศก่อน {ticket}
    Route::get('/support/tickets/open', [SupportTicketController::class, 'openForOrder']);

    Route::post('/support/tickets', [SupportTicketController::class, 'store'])
        ->middleware('throttle:support-ticket');

    Route::get('/support/tickets/{ticket}', [SupportTicketController::class, 'show'])
        ->whereNumber('ticket');

    Route::post('/support/tickets/{ticket}/messages', [SupportTicketController::class, 'storeMessage'])
        ->whereNumber('ticket')
        ->middleware('throttle:support-message');
});

// รูปในแชทกลุ่ม: ลิงก์ชั่วคราวที่ลงลายเซ็น ผูกกับผู้ดู + ตรวจสิทธิ์ผู้ดูซ้ำทุกครั้ง
Route::get('/group-chat-images/{message}', [GroupChatController::class, 'image'])
    ->middleware(['signed', 'throttle:240,1'])
    ->whereNumber('message')
    ->name('group-chat.image');

// ไฟล์แนบ/ข้อความเสียงในแชท: ลิงก์ชั่วคราว 10 นาทีที่ลงลายเซ็น ผูกกับผู้ดู + ตรวจสิทธิ์ผู้ดูซ้ำทุกครั้ง
Route::get('/chat-files/{message}', [ChatController::class, 'file'])
    ->middleware(['signed', 'throttle:240,1'])
    ->whereNumber('message')
    ->name('chat.file');

Route::get('/group-chat-files/{message}', [GroupChatController::class, 'file'])
    ->middleware(['signed', 'throttle:240,1'])
    ->whereNumber('message')
    ->name('group-chat.file');

// รูปแนบในคำร้อง: ลิงก์ชั่วคราวที่ลงลายเซ็น (สร้างให้เฉพาะเจ้าของคำร้องและทีมงาน)
Route::get('/support/files/{attachment}', [SupportTicketController::class, 'file'])
    ->middleware('signed')
    ->whereNumber('attachment')
    ->name('support.file');
