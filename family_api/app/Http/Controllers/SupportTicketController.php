<?php

namespace App\Http\Controllers;

use App\Models\Order;
use App\Models\SupportAttachment;
use App\Models\SupportMessage;
use App\Models\SupportTicket;
use App\Models\User;
use App\Services\SupportDesk;
use App\Services\SupportTicketClosed;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Storage;
use Illuminate\Validation\Rule;

// =======================================================
// ศูนย์ช่วยเหลือ (ฝั่งผู้ใช้) — ทีมงานตอบใน /admin → คำร้อง
//
// GET  /api/support/tickets?filter=all|open|closed&page=   คำร้องของฉัน
// GET  /api/support/tickets/open?order_id=&category=       มีเรื่องที่ยังไม่ปิดของออเดอร์นี้ไหม
// POST /api/support/tickets                                 แจ้งปัญหา (multipart: images[])
// GET  /api/support/tickets/{ticket}                        รายละเอียด + ข้อความ (ไม่รวมบันทึกภายใน)
// POST /api/support/tickets/{ticket}/messages               ส่งข้อมูลเพิ่ม
// GET  /api/support/files/{attachment}?signature=           เปิดรูปแนบ (ลิงก์ชั่วคราว)
//
// ทุกเส้นทางตรวจเจ้าของคำร้องที่เซิร์ฟเวอร์ (คำร้องของคนอื่น = 404)
// =======================================================

class SupportTicketController extends Controller
{
    private const PAGE_SIZE = 20;

    public function __construct(private SupportDesk $desk)
    {
    }

    public function index(Request $request)
    {
        $data = $request->validate([
            'filter' => ['nullable', Rule::in(['all', 'open', 'closed'])],
            'page' => 'nullable|integer|min:1',
        ]);

        $user = $request->user();

        $paginator = SupportTicket::where('user_id', $user->id)
            ->when(($data['filter'] ?? 'all') === 'open', fn ($query) => $query->open())
            ->when(($data['filter'] ?? 'all') === 'closed', fn ($query) => $query->where('status', SupportTicket::STATUS_CLOSED))
            ->with('previousTicket:id,code')
            ->orderByDesc('last_activity_at')
            ->orderByDesc('id')
            ->simplePaginate(self::PAGE_SIZE);

        return response()->json([
            'status' => true,
            'tickets' => collect($paginator->items())
                ->map(fn (SupportTicket $ticket) => $ticket->summaryPayload())
                ->values(),
            'page' => $paginator->currentPage(),
            'has_more' => $paginator->hasMorePages(),
            'limits' => $this->limits(),
        ]);
    }

    // เข้าจากออเดอร์: มีเรื่องที่ยังไม่ปิดของออเดอร์ + ประเภทนี้อยู่แล้ว → แอปเสนอเปิดเรื่องเดิมก่อน
    public function openForOrder(Request $request)
    {
        $data = $request->validate([
            'order_id' => 'required|integer',
            'category' => ['required', Rule::in(array_keys(SupportTicket::CATEGORY_LABELS))],
        ]);

        $ticket = $this->openTicket($request->user(), (int) $data['order_id'], $data['category']);

        return response()->json([
            'status' => true,
            'ticket' => $ticket?->summaryPayload(),
            'limits' => $this->limits(),
        ]);
    }

    public function store(Request $request)
    {
        $data = $request->validate([
            'category' => ['required', Rule::in(array_keys(SupportTicket::CATEGORY_LABELS))],
            'subject' => 'required|string|max:120',
            'body' => 'required|string|max:3000',
            'order_id' => 'nullable|integer',
            'previous_ticket_id' => 'nullable|integer',
            'client_id' => 'required|string|max:64',
            'confirm_new' => 'nullable|boolean',
            ...$this->imageRules(),
        ], [
            'category.*' => 'กรุณาเลือกประเภทปัญหา',
            'subject.required' => 'กรุณาใส่หัวข้อ',
            'subject.max' => 'หัวข้อยาวได้ไม่เกิน 120 ตัวอักษร',
            'body.required' => 'กรุณาเล่ารายละเอียดของปัญหา',
            'body.max' => 'รายละเอียดยาวได้ไม่เกิน 3000 ตัวอักษร',
            'client_id.*' => 'ส่งเรื่องไม่สำเร็จ กรุณาลองอีกครั้ง',
            ...$this->imageMessages(),
        ]);

        $user = $request->user();

        // ส่งซ้ำ (กดซ้ำ / หมดเวลารอ) → คำร้องเดิม
        $sent = SupportTicket::where('user_id', $user->id)->where('client_id', $data['client_id'])->first();

        if ($sent) {
            return $this->ticketResponse($sent, 200);
        }

        $order = null;

        if (isset($data['order_id'])) {
            $order = Order::with('shop')->find($data['order_id']);

            // ต้องเป็นผู้ซื้อหรือร้านของคำสั่งซื้อนี้
            if (!$order || (!$order->isBuyer($user) && !$order->isSeller($user))) {
                return $this->fail('ไม่พบคำสั่งซื้อนี้', 404);
            }

            if (!($data['confirm_new'] ?? false) && ($open = $this->openTicket($user, $order->id, $data['category']))) {
                return response()->json([
                    'status' => false,
                    'code' => 'open_ticket_exists',
                    'message' => 'มีเรื่องที่ยังไม่ปิดของคำสั่งซื้อนี้อยู่แล้ว เปิดเรื่องเดิมเพื่อส่งข้อมูลเพิ่มได้',
                    'ticket' => $open->summaryPayload(),
                ], 409);
            }
        }

        if (isset($data['previous_ticket_id'])
            && !SupportTicket::where('user_id', $user->id)->whereKey($data['previous_ticket_id'])->exists()) {
            return $this->fail('ไม่พบคำร้องเดิมที่อ้างอิง', 404);
        }

        [$ticket, $created] = $this->desk->create($user, [
            'category' => $data['category'],
            'subject' => $data['subject'],
            'body' => $data['body'],
            'client_id' => $data['client_id'],
            'order_id' => $order?->id,
            'order_code' => $order?->code,
            'previous_ticket_id' => $data['previous_ticket_id'] ?? null,
        ], $request->file('images', []));

        return $this->ticketResponse($ticket, $created ? 201 : 200);
    }

    public function show(Request $request, SupportTicket $ticket)
    {
        if (!$this->owns($request->user(), $ticket)) {
            return $this->notFound();
        }

        return $this->ticketResponse($ticket, 200);
    }

    public function storeMessage(Request $request, SupportTicket $ticket)
    {
        $user = $request->user();

        if (!$this->owns($user, $ticket)) {
            return $this->notFound();
        }

        if ($ticket->isClosed()) {
            return $this->closed($ticket);
        }

        $data = $request->validate([
            'body' => 'required_without:images|nullable|string|max:3000',
            'client_id' => 'required|string|max:64',
            ...$this->imageRules(),
        ], [
            'body.required_without' => 'กรุณาพิมพ์ข้อความหรือแนบรูป',
            'body.max' => 'ข้อความยาวได้ไม่เกิน 3000 ตัวอักษร',
            'client_id.*' => 'ส่งข้อความไม่สำเร็จ กรุณาลองอีกครั้ง',
            ...$this->imageMessages(),
        ]);

        try {
            [$message, $created] = $this->desk->addUserMessage(
                $ticket,
                $user,
                $data['body'] ?? null,
                $request->file('images', []),
                $data['client_id']
            );
        } catch (SupportTicketClosed) {
            return $this->closed($ticket->refresh());
        }

        $message->load('attachments');

        return response()->json([
            'status' => true,
            'message' => $message->userPayload(),
            'ticket' => $ticket->refresh()->summaryPayload(),
        ], $created ? 201 : 200);
    }

    // รูปแนบ: ลิงก์ลงลายเซ็นหมดอายุใน 30 นาที (middleware signed) — สร้างให้เฉพาะผู้มีสิทธิ์
    public function file(SupportAttachment $attachment)
    {
        $disk = Storage::disk(SupportAttachment::disk());

        if (!$disk->exists($attachment->path)) {
            return $this->fail('ไม่พบไฟล์นี้', 404);
        }

        return $disk->response($attachment->path, null, [
            'Cache-Control' => 'private, max-age=600',
            'X-Content-Type-Options' => 'nosniff',
        ]);
    }

    // =====================================================
    // HELPERS
    // =====================================================

    private function owns(User $user, SupportTicket $ticket): bool
    {
        return (int) $ticket->user_id === (int) $user->id;
    }

    private function openTicket(User $user, int $orderId, string $category): ?SupportTicket
    {
        return SupportTicket::where('user_id', $user->id)
            ->where('order_id', $orderId)
            ->where('category', $category)
            ->open()
            ->latest('id')
            ->first();
    }

    private function ticketResponse(SupportTicket $ticket, int $status): JsonResponse
    {
        $ticket->load(['previousTicket:id,code', 'publicMessages.attachments']);

        return response()->json([
            'status' => true,
            'ticket' => [
                ...$ticket->summaryPayload(),
                'messages' => $ticket->publicMessages
                    ->map(fn (SupportMessage $message) => $message->userPayload())
                    ->values(),
            ],
            'limits' => $this->limits(),
        ], $status);
    }

    private function imageRules(): array
    {
        return [
            'images' => 'nullable|array|max:' . SupportTicket::MAX_IMAGES,
            'images.*' => 'file|image|mimes:' . implode(',', SupportTicket::IMAGE_MIMES) . '|max:' . SupportTicket::MAX_IMAGE_KB,
        ];
    }

    private function imageMessages(): array
    {
        return [
            'images.max' => 'แนบรูปได้ไม่เกิน ' . SupportTicket::MAX_IMAGES . ' รูป',
            'images.*.image' => 'แนบได้เฉพาะรูป JPG, PNG หรือ WEBP',
            'images.*.mimes' => 'แนบได้เฉพาะรูป JPG, PNG หรือ WEBP',
            'images.*.file' => 'แนบได้เฉพาะรูป JPG, PNG หรือ WEBP',
            'images.*.max' => 'รูปต้องมีขนาดไม่เกิน ' . (SupportTicket::MAX_IMAGE_KB / 1024) . ' MB',
        ];
    }

    // แอปแสดงข้อจำกัดเดียวกับที่เซิร์ฟเวอร์ตรวจ
    private function limits(): array
    {
        return [
            'max_images' => SupportTicket::MAX_IMAGES,
            'max_image_mb' => SupportTicket::MAX_IMAGE_KB / 1024,
            'image_types' => 'JPG, PNG, WEBP',
        ];
    }

    private function closed(SupportTicket $ticket): JsonResponse
    {
        return response()->json([
            'status' => false,
            'code' => 'ticket_closed',
            'message' => 'เรื่องนี้ปิดแล้ว สร้างเรื่องใหม่โดยอ้างอิงเรื่องนี้ได้',
            'ticket' => $ticket->summaryPayload(),
        ], 409);
    }

    private function fail(string $message, int $status): JsonResponse
    {
        return response()->json(['status' => false, 'message' => $message], $status);
    }

    private function notFound(): JsonResponse
    {
        return $this->fail('ไม่พบคำร้องนี้', 404);
    }
}
