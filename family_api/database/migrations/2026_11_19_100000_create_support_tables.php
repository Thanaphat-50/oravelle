<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * ศูนย์ช่วยเหลือ (App\Models\SupportTicket)
     * - support_tickets: คำร้อง 1 เรื่อง (เลขอ้างอิง code) ของผู้ใช้ 1 คน
     *   client_id: กันสร้างซ้ำเมื่อกดซ้ำ / ส่งใหม่หลังหมดเวลารอ (unique ต่อผู้ใช้)
     *   order_id + order_code: คำสั่งซื้อที่เกี่ยวข้อง (คำสั่งซื้อถูกลบ → ยังเห็นเลขเดิม)
     * - support_messages: ข้อความของผู้ใช้ / ทีมงาน / บันทึกภายใน (is_internal ผู้ใช้ไม่เห็น)
     * - support_attachments: รูปแนบ (ไฟล์ส่วนตัว เปิดผ่านลิงก์ชั่วคราวที่ตรวจสิทธิ์แล้ว)
     * - support_ticket_events: ประวัติผู้ดำเนินการและการเปลี่ยนสถานะ (ทีมงานเห็นเท่านั้น)
     *
     * ลบบัญชี → คำร้องของผู้ใช้ถูกลบตาม (cascade) ไฟล์ลบใน AccountDeletionService
     * ตารางใหม่ทั้งหมด ไม่แตะข้อมูลเดิม / รันซ้ำได้
     */
    public function up(): void
    {
        if (!Schema::hasTable('support_tickets')) {
            Schema::create('support_tickets', function (Blueprint $table) {
                $table->id();
                $table->string('code', 20)->unique();
                $table->foreignId('user_id')->constrained('users')->cascadeOnDelete();
                $table->string('category', 20);
                $table->string('subject', 120);
                $table->foreignId('order_id')->nullable()->constrained('orders')->nullOnDelete();
                $table->string('order_code', 20)->nullable();
                $table->foreignId('previous_ticket_id')->nullable()->constrained('support_tickets')->nullOnDelete();
                $table->string('status', 20)->default('submitted');
                $table->string('client_id', 64);
                $table->text('resolution')->nullable();
                $table->timestamp('closed_at')->nullable();
                $table->timestamp('last_activity_at')->nullable();
                $table->timestamps();

                $table->unique(['user_id', 'client_id']);
                $table->index(['user_id', 'status', 'last_activity_at']);
                $table->index(['status', 'last_activity_at']);
                $table->index(['order_id', 'category']);
            });
        }

        if (!Schema::hasTable('support_messages')) {
            Schema::create('support_messages', function (Blueprint $table) {
                $table->id();
                $table->foreignId('ticket_id')->constrained('support_tickets')->cascadeOnDelete();
                // ผู้เขียน (ทีมงานถูกลบบัญชี → ข้อความยังอยู่)
                $table->foreignId('user_id')->nullable()->constrained('users')->nullOnDelete();
                $table->boolean('is_staff')->default(false);
                $table->boolean('is_internal')->default(false);
                $table->text('body')->nullable();
                $table->string('client_id', 64)->nullable();
                $table->timestamps();

                $table->unique(['ticket_id', 'user_id', 'client_id']);
                $table->index(['ticket_id', 'is_internal', 'id']);
            });
        }

        if (!Schema::hasTable('support_attachments')) {
            Schema::create('support_attachments', function (Blueprint $table) {
                $table->id();
                $table->foreignId('ticket_id')->constrained('support_tickets')->cascadeOnDelete();
                $table->foreignId('message_id')->constrained('support_messages')->cascadeOnDelete();
                $table->string('path');
                $table->string('mime', 50)->nullable();
                $table->unsignedInteger('size')->default(0);
                $table->timestamps();
            });
        }

        if (!Schema::hasTable('support_ticket_events')) {
            Schema::create('support_ticket_events', function (Blueprint $table) {
                $table->id();
                $table->foreignId('ticket_id')->constrained('support_tickets')->cascadeOnDelete();
                $table->foreignId('actor_id')->nullable()->constrained('users')->nullOnDelete();
                // user / staff / system
                $table->string('actor_role', 10);
                // created / message / staff_reply / internal_note / status / closed
                $table->string('type', 20);
                $table->string('from_status', 20)->nullable();
                $table->string('to_status', 20)->nullable();
                $table->string('note', 300)->nullable();
                $table->timestamp('created_at')->nullable();
            });
        }
    }

    public function down(): void
    {
        Schema::dropIfExists('support_ticket_events');
        Schema::dropIfExists('support_attachments');
        Schema::dropIfExists('support_messages');
        Schema::dropIfExists('support_tickets');
    }
};
