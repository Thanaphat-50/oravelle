<?php

namespace App\Mail;

use App\Models\User;
use Illuminate\Bus\Queueable;
use Illuminate\Mail\Mailable;
use Illuminate\Mail\Mailables\Content;
use Illuminate\Mail\Mailables\Envelope;
use Illuminate\Queue\SerializesModels;

// รหัส 6 หลักสำหรับตั้งรหัสผ่านใหม่ (ส่งทันที ไม่เข้าคิว — Laravel Cloud ยังไม่มี Queue worker)
class PasswordResetCode extends Mailable
{
    use Queueable, SerializesModels;

    /**
     * @param  array<int, string>  $providers  ชื่อบริการที่บัญชีนี้ใช้เข้าสู่ระบบ (Google / LINE / Facebook)
     */
    public function __construct(
        public User $user,
        public string $code,
        public int $minutes,
        public bool $hasPassword,
        public array $providers,
    ) {}

    public function envelope(): Envelope
    {
        return new Envelope(
            // ไม่ใช้ APP_NAME (บน Cloud อาจยังเป็น "Laravel")
            subject: 'รหัสตั้งรหัสผ่านใหม่ ORAVELLE',
        );
    }

    public function content(): Content
    {
        return new Content(
            text: 'mail.password-reset-code',
        );
    }
}
