<?php

namespace App\Services;

use App\Models\AccountDeletionRequest;
use App\Models\AppNotification;
use App\Models\Comment;
use App\Models\Family;
use App\Models\FamilyMember;
use App\Models\GroupChat;
use App\Models\GroupChatMessage;
use App\Models\Conversation;
use App\Models\Post;
use App\Models\PostImage;
use App\Models\PostVideo;
use App\Models\Shop;
use App\Models\User;
use App\Models\SupportAttachment;
use App\Models\SupportTicket;
use App\Support\MediaStorage;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Facades\Storage;
use RuntimeException;
use Throwable;

// =======================================================
// ลบบัญชีผู้ใช้และข้อมูลทั้งหมด
// ผู้ใช้ส่งคำขอ (แอป / หน้าเว็บ) → ผู้ดูแลกดลบในหน้า Admin (completeRequest)
// =======================================================

class AccountDeletionService
{
    // =====================================================
    // ตรวจว่าลบได้หรือไม่
    // คืนข้อความเหตุผลถ้าลบไม่ได้ / null ถ้าลบได้
    // =====================================================

    public function blockingReason(User $user): ?string
    {
        $family = Family::where('owner_id', $user->id)->first();

        if (!$family) {
            return null;
        }

        $hasOtherMembers = FamilyMember::where('family_id', $family->id)
            ->where('user_id', '!=', $user->id)
            ->exists();

        return $hasOtherMembers
            ? 'คุณเป็นเจ้าของกลุ่มที่ยังมีสมาชิกอยู่ '
                . 'กรุณาโอนสิทธิ์ Owner ให้สมาชิกคนอื่นก่อนลบบัญชี'
            : null;
    }

    // =====================================================
    // ลบบัญชี
    //
    // ลบโดยอัตโนมัติผ่าน Foreign Key (cascade):
    // สมาชิกครอบครัว, ตำแหน่ง, โพสต์, ความคิดเห็น, กิจกรรม,
    // การแจ้งเตือน, รายงาน และการบล็อก
    // =====================================================

    public function delete(User $user): void
    {
        $reason = $this->blockingReason($user);

        if ($reason !== null) {
            throw new RuntimeException($reason);
        }

        $photoPath = $user->profile_photo;

        // ไฟล์รูปในโพสต์ที่จะถูกลบตาม cascade:
        // โพสต์ของผู้ใช้ + โพสต์ของครอบครัวที่ผู้ใช้เป็น Owner คนเดียว
        $imagePaths = PostImage::whereHas('post', function ($posts) use ($user) {
            $posts->where('user_id', $user->id)
                ->orWhereIn(
                    'family_id',
                    Family::where('owner_id', $user->id)->select('id')
                );
        })->pluck('path')->all();

        // วิดีโอและรูปตัวอย่างในโพสต์เดียวกัน
        $videoPaths = PostVideo::whereHas('post', function ($posts) use ($user) {
            $posts->where('user_id', $user->id)
                ->orWhereIn(
                    'family_id',
                    Family::where('owner_id', $user->id)->select('id')
                );
        })->get()->flatMap(fn (PostVideo $video) => $video->filePaths())->all();

        // ไฟล์แนบในความคิดเห็นของผู้ใช้ + ความคิดเห็นในโพสต์ที่จะถูกลบ
        $commentMediaPaths = Comment::whereNotNull('media_path')
            ->where(function ($comments) use ($user) {
                $comments->where('user_id', $user->id)
                    ->orWhereIn('post_id', Post::where('user_id', $user->id)
                        ->orWhereIn('family_id', Family::where('owner_id', $user->id)->select('id'))
                        ->select('id'));
            })
            ->get()
            ->flatMap(fn (Comment $comment) => $comment->mediaPaths())
            ->all();

        // โลโก้ร้านและรูปสินค้าของผู้ใช้ (ร้านถูกลบตาม cascade)
        $shopMediaPaths = Shop::mediaPathsOfOwner($user->id);

        // รูปในห้องแชทของผู้ใช้ (ห้องถูกลบตาม cascade)
        $chatMediaPaths = Conversation::mediaPathsOf($user->id);

        // แชทกลุ่ม: ข้อความของผู้ใช้ (ลบตาม cascade) + ห้องของกลุ่มที่ผู้ใช้เป็นเจ้าของ (ถูกลบทั้งห้อง)
        $groupChatPaths = GroupChatMessage::whereNotNull('image_path')
            ->where(function ($messages) use ($user) {
                $messages->where('sender_id', $user->id)
                    ->orWhereIn('group_chat_id', GroupChat::whereIn(
                        'family_id',
                        Family::where('owner_id', $user->id)->select('id')
                    )->select('id'));
            })
            ->pluck('image_path')
            ->all();

        // รูปแนบในคำร้องศูนย์ช่วยเหลือของผู้ใช้ (คำร้อง/ข้อความ/บันทึกภายในถูกลบตาม cascade)
        $supportPaths = SupportAttachment::whereIn(
            'ticket_id',
            SupportTicket::where('user_id', $user->id)->select('id')
        )->pluck('path')->all();

        DB::transaction(function () use ($user) {
            // Owner คนเดียวของครอบครัว → ลบครอบครัวด้วย
            Family::where('owner_id', $user->id)->delete();

            // Token ไม่มี Foreign Key ต้องลบเอง
            $user->tokens()->delete();

            $user->delete();
        });

        // ลบไฟล์รูปในโพสต์และไฟล์ของร้านหลังลบข้อมูลสำเร็จแล้ว
        MediaStorage::delete([
            ...$imagePaths,
            ...$videoPaths,
            ...$commentMediaPaths,
            ...$shopMediaPaths,
            ...$chatMediaPaths,
        ]);

        // ไฟล์แนบคำร้องอยู่ใน disk ส่วนตัวของศูนย์ช่วยเหลือ
        SupportAttachment::deleteFiles($supportPaths);

        // รูปในแชทกลุ่มอยู่ใน disk ส่วนตัว
        GroupChatMessage::deleteFiles($groupChatPaths);

        // ลบรูปโปรไฟล์หลังลบข้อมูลสำเร็จแล้ว
        if ($photoPath) {
            try {
                Storage::disk(User::profilePhotoDisk())->delete($photoPath);
            } catch (Throwable $e) {
                Log::warning('Could not delete profile photo of deleted account', [
                    'error' => $e->getMessage(),
                ]);
            }
        }
    }

    // =====================================================
    // ผู้ดูแลอนุมัติคำขอ → ลบบัญชี
    // ลบไม่ได้ (เช่น ยังเป็น Owner ที่มีสมาชิก) → RuntimeException พร้อมเหตุผล
    // =====================================================

    public function completeRequest(AccountDeletionRequest $request, ?User $admin): void
    {
        if (!$request->isPending()) {
            throw new RuntimeException('คำขอนี้ดำเนินการไปแล้ว');
        }

        // ผู้ใช้ถูกลบไปแล้วทางอื่น → ปิดคำขอได้เลย
        $user = $request->user;

        if ($user) {
            $this->delete($user);
        }

        $request->forceFill([
            'status' => AccountDeletionRequest::STATUS_COMPLETED,
            'processed_by' => $admin?->id,
            'processed_at' => now(),
        ])->save();
    }

    // ผู้ดูแลไม่ลบ (เช่น ต้องให้ผู้ใช้โอนสิทธิ์ Owner ก่อน) → แจ้งผู้ใช้พร้อมเหตุผล
    public function rejectRequest(AccountDeletionRequest $request, ?User $admin, string $note): void
    {
        if (!$request->isPending()) {
            throw new RuntimeException('คำขอนี้ดำเนินการไปแล้ว');
        }

        $request->forceFill([
            'status' => AccountDeletionRequest::STATUS_REJECTED,
            'processed_by' => $admin?->id,
            'processed_at' => now(),
            'note' => $note,
        ])->save();

        if ($request->user_id) {
            AppNotification::create([
                'user_id' => $request->user_id,
                'type' => 'account_deletion',
                'title' => 'คำขอลบบัญชี',
                'message' => 'ยังไม่ได้ลบบัญชีของคุณ: ' . $note,
                'data' => [],
                'is_read' => false,
            ]);
        }
    }
}
