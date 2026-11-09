<?php

namespace App\Services;

use App\Models\AppNotification;
use App\Models\SupportAttachment;
use App\Models\SupportMessage;
use App\Models\SupportTicket;
use App\Models\SupportTicketEvent;
use App\Models\User;
use Illuminate\Database\UniqueConstraintViolationException;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;
use RuntimeException;
use Throwable;

// =======================================================
// ศูนย์ช่วยเหลือ: งานทั้งหมดของคำร้อง (แอปของผู้ใช้ + หลังบ้าน Filament ใช้ร่วมกัน)
//
// ผู้ใช้:  create() / addUserMessage()  — client_id กันสร้างซ้ำเมื่อกดซ้ำหรือส่งใหม่หลังหมดเวลา
// ทีมงาน: reply() / note() / changeStatus() / close()
//
// - บันทึกภายใน (note) ไม่แจ้งเตือนผู้ใช้ และไม่ส่งผ่าน API ของผู้ใช้
// - แจ้งเตือนผู้ใช้ด้วยระบบเดิม (AppNotification → Push) ข้อความไม่มีรายละเอียดส่วนตัว
// - ไม่แตะคำสั่งซื้อ / การคืนเงิน (ทีมงานดำเนินการเองหลังตรวจ)
// =======================================================

class SupportDesk
{
    // =====================================================
    // ผู้ใช้
    // =====================================================

    /**
     * @param  array{category: string, subject: string, body: string, client_id: string,
     *               order_id?: ?int, order_code?: ?string, previous_ticket_id?: ?int}  $data
     * @param  array<int, UploadedFile>  $files
     * @return array{0: SupportTicket, 1: bool} [คำร้อง, สร้างใหม่หรือไม่]
     */
    public function create(User $user, array $data, array $files = []): array
    {
        if ($existing = $this->ticketByClientId($user, $data['client_id'])) {
            return [$existing, false];
        }

        $stored = $this->storeFiles($user, $files);

        try {
            $ticket = DB::transaction(function () use ($user, $data, $stored) {
                $ticket = SupportTicket::create([
                    'code' => SupportTicket::newCode(),
                    'user_id' => $user->id,
                    'category' => $data['category'],
                    'subject' => SupportTicket::normalizeSubject($data['subject']),
                    'order_id' => $data['order_id'] ?? null,
                    'order_code' => $data['order_code'] ?? null,
                    'previous_ticket_id' => $data['previous_ticket_id'] ?? null,
                    'status' => SupportTicket::STATUS_SUBMITTED,
                    'client_id' => $data['client_id'],
                    'last_activity_at' => now(),
                ]);

                $message = $ticket->messages()->create([
                    'user_id' => $user->id,
                    'body' => trim($data['body']),
                    'client_id' => $data['client_id'],
                ]);

                $this->attach($ticket, $message, $stored);

                $this->event($ticket, $user, 'user', 'created', null, SupportTicket::STATUS_SUBMITTED);

                return $ticket;
            });
        } catch (UniqueConstraintViolationException $e) {
            // คำขอเดียวกันอีกคำขอสร้างไปก่อน (กดซ้ำ / ส่งใหม่พร้อมกัน)
            SupportAttachment::deleteFiles(array_column($stored, 'path'));

            return [$this->ticketByClientId($user, $data['client_id']) ?? throw $e, false];
        } catch (Throwable $e) {
            SupportAttachment::deleteFiles(array_column($stored, 'path'));

            throw $e;
        }

        return [$ticket, true];
    }

    /**
     * ผู้ใช้ส่งข้อมูลเพิ่ม (เฉพาะเรื่องที่ยังไม่ปิด)
     * รอข้อมูลเพิ่มเติม → กลับเป็นกำลังตรวจสอบ
     *
     * @return array{0: SupportMessage, 1: bool} [ข้อความ, สร้างใหม่หรือไม่]
     */
    public function addUserMessage(SupportTicket $ticket, User $user, ?string $body, array $files, string $clientId): array
    {
        if ($existing = $this->messageByClientId($ticket, $user, $clientId)) {
            return [$existing, false];
        }

        $stored = $this->storeFiles($user, $files);

        try {
            $message = DB::transaction(function () use ($ticket, $user, $body, $stored, $clientId) {
                $locked = SupportTicket::whereKey($ticket->id)->lockForUpdate()->firstOrFail();

                if ($locked->isClosed()) {
                    throw new SupportTicketClosed();
                }

                $message = $locked->messages()->create([
                    'user_id' => $user->id,
                    'body' => filled($body) ? trim($body) : null,
                    'client_id' => $clientId,
                ]);

                $this->attach($locked, $message, $stored);

                $this->event($locked, $user, 'user', 'message');

                $updates = ['last_activity_at' => now()];

                if ($locked->status === SupportTicket::STATUS_WAITING_USER) {
                    $updates['status'] = SupportTicket::STATUS_IN_REVIEW;

                    $this->event(
                        $locked,
                        null,
                        'system',
                        'status',
                        SupportTicket::STATUS_WAITING_USER,
                        SupportTicket::STATUS_IN_REVIEW,
                        'ผู้ใช้ส่งข้อมูลเพิ่มแล้ว'
                    );
                }

                $locked->forceFill($updates)->save();

                return $message;
            });
        } catch (UniqueConstraintViolationException $e) {
            SupportAttachment::deleteFiles(array_column($stored, 'path'));

            return [$this->messageByClientId($ticket, $user, $clientId) ?? throw $e, false];
        } catch (Throwable $e) {
            SupportAttachment::deleteFiles(array_column($stored, 'path'));

            throw $e;
        }

        $ticket->refresh();

        return [$message, true];
    }

    // =====================================================
    // ทีมงาน (หลังบ้าน)
    // =====================================================

    // ตอบผู้ใช้ (+ เปลี่ยนสถานะได้ในครั้งเดียว) → แจ้งเตือนผู้ใช้ 1 ครั้ง
    public function reply(SupportTicket $ticket, User $staff, string $body, ?string $status = null): SupportMessage
    {
        $message = DB::transaction(function () use ($ticket, $staff, $body, $status) {
            $locked = $this->lockOpen($ticket);

            $message = $locked->messages()->create([
                'user_id' => $staff->id,
                'is_staff' => true,
                'body' => trim($body),
            ]);

            $this->event($locked, $staff, 'staff', 'staff_reply', null, null, Str::limit(trim($body), 120));

            $this->applyStatus($locked, $staff, $status);

            $locked->forceFill(['last_activity_at' => now()])->save();

            return $message;
        });

        $ticket->refresh();

        $this->notifyUser(
            $ticket,
            $ticket->status === SupportTicket::STATUS_WAITING_USER ? 'ทีมงานขอข้อมูลเพิ่มเติม' : 'ทีมงานตอบคำร้องของคุณ',
            'คำร้อง ' . $ticket->code . ' · แตะเพื่ออ่านข้อความจากทีมงาน'
        );

        return $message;
    }

    // บันทึกภายในทีมงาน: ผู้ใช้ไม่เห็น ไม่แจ้งเตือน
    public function note(SupportTicket $ticket, User $staff, string $body): SupportMessage
    {
        return DB::transaction(function () use ($ticket, $staff, $body) {
            $message = $ticket->messages()->create([
                'user_id' => $staff->id,
                'is_staff' => true,
                'is_internal' => true,
                'body' => trim($body),
            ]);

            $this->event($ticket, $staff, 'staff', 'internal_note', null, null, Str::limit(trim($body), 120));

            return $message;
        });
    }

    // เปลี่ยนสถานะ (ยังไม่ปิด) → แจ้งผู้ใช้เมื่อเป็นสถานะสำคัญ
    public function changeStatus(SupportTicket $ticket, User $staff, string $status, ?string $note = null): bool
    {
        if ($status === SupportTicket::STATUS_CLOSED || !isset(SupportTicket::STATUS_LABELS[$status])) {
            throw new RuntimeException('สถานะไม่ถูกต้อง (ปิดเรื่องใช้ปุ่มปิดเรื่อง)');
        }

        $changed = DB::transaction(function () use ($ticket, $staff, $status, $note) {
            $locked = $this->lockOpen($ticket);

            return $this->applyStatus($locked, $staff, $status, $note);
        });

        $ticket->refresh();

        if ($changed) {
            match ($status) {
                SupportTicket::STATUS_IN_REVIEW => $this->notifyUser($ticket, 'ทีมงานกำลังตรวจสอบคำร้องของคุณ', 'คำร้อง ' . $ticket->code),
                SupportTicket::STATUS_WAITING_USER => $this->notifyUser(
                    $ticket,
                    'ทีมงานขอข้อมูลเพิ่มเติม',
                    'คำร้อง ' . $ticket->code . ' · แตะเพื่อดูว่าต้องส่งข้อมูลอะไรเพิ่ม'
                ),
                default => null,
            };
        }

        return $changed;
    }

    // ปิดเรื่อง: ต้องมีสรุปผลการดำเนินการ (ผู้ใช้เห็นสรุปนี้) + ข้อความถึงผู้ใช้ (ไม่บังคับ)
    public function close(SupportTicket $ticket, User $staff, string $resolution, ?string $message = null): void
    {
        DB::transaction(function () use ($ticket, $staff, $resolution, $message) {
            $locked = $this->lockOpen($ticket);

            if (filled($message)) {
                $locked->messages()->create([
                    'user_id' => $staff->id,
                    'is_staff' => true,
                    'body' => trim($message),
                ]);
            }

            $this->event($locked, $staff, 'staff', 'closed', $locked->status, SupportTicket::STATUS_CLOSED, Str::limit(trim($resolution), 280));

            $locked->forceFill([
                'status' => SupportTicket::STATUS_CLOSED,
                'resolution' => trim($resolution),
                'closed_at' => now(),
                'last_activity_at' => now(),
            ])->save();
        });

        $ticket->refresh();

        $this->notifyUser($ticket, 'ปิดเรื่องคำร้องแล้ว', 'คำร้อง ' . $ticket->code . ' · แตะเพื่อดูสรุปผล');
    }

    // =====================================================
    // HELPERS
    // =====================================================

    private function lockOpen(SupportTicket $ticket): SupportTicket
    {
        $locked = SupportTicket::whereKey($ticket->id)->lockForUpdate()->firstOrFail();

        if ($locked->isClosed()) {
            throw new SupportTicketClosed();
        }

        return $locked;
    }

    private function applyStatus(SupportTicket $ticket, User $staff, ?string $status, ?string $note = null): bool
    {
        if ($status === null || $status === $ticket->status || $status === SupportTicket::STATUS_CLOSED) {
            return false;
        }

        $this->event($ticket, $staff, 'staff', 'status', $ticket->status, $status, $note);

        $ticket->forceFill(['status' => $status, 'last_activity_at' => now()])->save();

        return true;
    }

    private function ticketByClientId(User $user, string $clientId): ?SupportTicket
    {
        return SupportTicket::where('user_id', $user->id)->where('client_id', $clientId)->first();
    }

    private function messageByClientId(SupportTicket $ticket, User $user, string $clientId): ?SupportMessage
    {
        return SupportMessage::where('ticket_id', $ticket->id)
            ->where('user_id', $user->id)
            ->where('client_id', $clientId)
            ->first();
    }

    /**
     * @param  array<int, UploadedFile>  $files
     * @return array<int, array{path: string, mime: ?string, size: int}>
     */
    private function storeFiles(User $user, array $files): array
    {
        $stored = [];

        try {
            foreach ($files as $file) {
                $path = $file->store('support/u' . $user->id, SupportAttachment::disk())
                    ?: throw new RuntimeException('Could not store support file.');

                $stored[] = [
                    'path' => $path,
                    'mime' => $file->getMimeType(),
                    'size' => (int) $file->getSize(),
                ];
            }
        } catch (Throwable $e) {
            SupportAttachment::deleteFiles(array_column($stored, 'path'));

            throw $e;
        }

        return $stored;
    }

    private function attach(SupportTicket $ticket, SupportMessage $message, array $stored): void
    {
        foreach ($stored as $file) {
            $message->attachments()->create([
                'ticket_id' => $ticket->id,
                ...$file,
            ]);
        }
    }

    private function event(
        SupportTicket $ticket,
        ?User $actor,
        string $role,
        string $type,
        ?string $from = null,
        ?string $to = null,
        ?string $note = null
    ): void {
        SupportTicketEvent::create([
            'ticket_id' => $ticket->id,
            'actor_id' => $actor?->id,
            'actor_role' => $role,
            'type' => $type,
            'from_status' => $from,
            'to_status' => $to,
            'note' => $note === null ? null : Str::limit($note, 297),
        ]);
    }

    // ไม่ใส่รายละเอียดคำร้อง / ข้อมูลการชำระเงินในแจ้งเตือน (Push แสดงบนหน้าจอล็อก)
    private function notifyUser(SupportTicket $ticket, string $title, string $message): void
    {
        AppNotification::create([
            'user_id' => $ticket->user_id,
            'family_id' => null,
            'type' => 'support_ticket',
            'title' => $title,
            'message' => $message,
            'data' => ['ticket_id' => $ticket->id],
            'is_read' => false,
        ]);
    }
}
