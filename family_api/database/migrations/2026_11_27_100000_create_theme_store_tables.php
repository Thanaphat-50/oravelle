<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * ร้านธีม: แค็ตตาล็อก / เวอร์ชันชุดธีม / รหัสสินค้าแต่ละช่องทาง / ธุรกรรมซื้อ / สิทธิ์ใช้ธีม / เหตุการณ์จากผู้ให้บริการ
     *
     * themes:               แค็ตตาล็อก (ข้อมูลตั้งต้นจาก resources/themes/catalog.json ผ่าน themes:sync)
     * theme_versions:       ชุดไฟล์แต่ละเวอร์ชัน + ความเข้ากันได้กับแอป (min_app_build)
     * theme_products:       รหัสสินค้าของแต่ละช่องทาง (google_play / test)
     * theme_purchases:      หลักฐานการซื้อ 1 ใบ = 1 แถว (unique provider + token_hash) → ใช้ซ้ำกับบัญชีอื่นไม่ได้
     * theme_entitlements:   สิทธิ์ใช้ธีมของบัญชี (unique user + theme) เพิกถอนแล้วเก็บเหตุผลไว้บอกผู้ใช้
     * theme_billing_events: เหตุการณ์จากผู้ให้บริการ (unique provider + event_key) → ประมวลผลซ้ำได้อย่างปลอดภัย
     *
     * ตารางใหม่เท่านั้น ไม่แตะข้อมูลเดิม / รันซ้ำได้
     */
    public function up(): void
    {
        if (!Schema::hasTable('themes')) {
            Schema::create('themes', function (Blueprint $table) {
                $table->id();
                $table->string('slug', 60)->unique();
                $table->string('name', 80);
                $table->text('description');
                $table->string('category', 20);
                $table->boolean('is_free')->default(false);
                // ราคาเป้าหมาย (บาท) ใช้ในเอกสาร/หลังบ้านเท่านั้น — ราคาที่เรียกเก็บจริงมาจากช่องทางชำระเงิน
                $table->unsignedSmallInteger('target_price_thb')->nullable();
                $table->boolean('supports_light')->default(true);
                $table->boolean('supports_dark')->default(true);
                $table->json('changes')->nullable();
                $table->json('previews')->nullable();
                // สีตัวอย่างบนการ์ดในร้าน [หลัก, พื้นหลัง, การ์ด, สีอ่อน]
                $table->json('swatch')->nullable();
                $table->unsignedInteger('current_version')->default(0);
                $table->unsignedInteger('sort_order')->default(0);
                $table->string('status', 12)->default('active');
                $table->timestamps();
            });
        }

        if (!Schema::hasTable('theme_versions')) {
            Schema::create('theme_versions', function (Blueprint $table) {
                $table->id();
                $table->foreignId('theme_id')->constrained('themes')->cascadeOnDelete();
                $table->unsignedInteger('version');
                $table->unsignedTinyInteger('format');
                $table->unsignedInteger('min_app_build')->default(1);
                $table->json('manifest');
                $table->unsignedInteger('total_bytes')->default(0);
                $table->timestamps();

                $table->unique(['theme_id', 'version']);
            });
        }

        if (!Schema::hasTable('theme_products')) {
            Schema::create('theme_products', function (Blueprint $table) {
                $table->id();
                $table->foreignId('theme_id')->constrained('themes')->cascadeOnDelete();
                $table->string('provider', 20);
                $table->string('product_id', 100);
                $table->timestamps();

                $table->unique(['provider', 'product_id']);
                $table->unique(['theme_id', 'provider']);
            });
        }

        if (!Schema::hasTable('theme_purchases')) {
            Schema::create('theme_purchases', function (Blueprint $table) {
                $table->id();
                $table->foreignId('user_id')->constrained('users')->cascadeOnDelete();
                $table->foreignId('theme_id')->constrained('themes')->cascadeOnDelete();
                $table->string('provider', 20);
                $table->string('product_id', 100);
                $table->char('token_hash', 64);
                $table->text('purchase_token');
                $table->string('order_id', 100)->nullable();
                // production / sandbox (การซื้อทดสอบของ Google) / test (จำลองในระบบนี้)
                $table->string('environment', 12);
                // pending / purchased / cancelled / refunded / revoked
                $table->string('status', 12);
                $table->timestamp('purchased_at')->nullable();
                $table->timestamp('acknowledged_at')->nullable();
                $table->timestamp('verified_at')->nullable();
                $table->timestamp('revoked_at')->nullable();
                $table->string('revoke_reason', 40)->nullable();
                $table->json('raw')->nullable();
                $table->timestamps();

                $table->unique(['provider', 'token_hash']);
                $table->index(['user_id', 'status']);
            });
        }

        if (!Schema::hasTable('theme_entitlements')) {
            Schema::create('theme_entitlements', function (Blueprint $table) {
                $table->id();
                $table->foreignId('user_id')->constrained('users')->cascadeOnDelete();
                $table->foreignId('theme_id')->constrained('themes')->cascadeOnDelete();
                $table->foreignId('purchase_id')->nullable()->constrained('theme_purchases')->nullOnDelete();
                // purchase / admin / test
                $table->string('source', 12);
                $table->timestamp('granted_at');
                $table->timestamp('revoked_at')->nullable();
                $table->string('revoke_reason', 40)->nullable();
                $table->timestamps();

                $table->unique(['user_id', 'theme_id']);
            });
        }

        if (!Schema::hasTable('theme_billing_events')) {
            Schema::create('theme_billing_events', function (Blueprint $table) {
                $table->id();
                $table->string('provider', 20);
                $table->string('event_key', 191);
                $table->string('type', 40);
                $table->char('token_hash', 64)->nullable();
                $table->json('payload')->nullable();
                $table->string('result', 40)->nullable();
                $table->timestamp('processed_at')->nullable();
                $table->timestamps();

                $table->unique(['provider', 'event_key']);
            });
        }
    }

    public function down(): void
    {
        Schema::dropIfExists('theme_billing_events');
        Schema::dropIfExists('theme_entitlements');
        Schema::dropIfExists('theme_purchases');
        Schema::dropIfExists('theme_products');
        Schema::dropIfExists('theme_versions');
        Schema::dropIfExists('themes');
    }
};
