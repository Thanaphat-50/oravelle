<?php

namespace App\Support;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Http\Exceptions\HttpResponseException;
use Illuminate\Http\Request;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Facades\RateLimiter;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Facades\URL;
use Illuminate\Support\Str;
use Illuminate\Validation\ValidationException;
use Throwable;

// =======================================================
// ไฟล์แนบในแชท (ส่วนตัว / ร้านค้า / กลุ่ม): ไฟล์เอกสาร + ข้อความเสียง
// - ชนิดที่รับ: PDF, TXT, DOCX, XLSX, PPTX (ไม่เกิน 10 MB) / เสียง M4A (AAC) ไม่เกิน 3 นาที 4 MB
// - ตรวจชนิดจากเนื้อไฟล์จริง: นามสกุลต้องตรงกับเนื้อไฟล์ ไม่เชื่อ MIME จากแอป ไม่รับไฟล์ที่รันได้
//   (DOCX/XLSX/PPTX ที่มีมาโคร vbaProject.bin ไม่รับ) / เสียงอ่านความยาวจากไฟล์เอง (mvhd)
// - เก็บใน disk ส่วนตัว (Cloud = Private Bucket) ชื่อไฟล์สุ่ม ไม่ใช้ชื่อจากผู้ใช้เป็นเส้นทาง
//   ชื่อที่แสดงผ่านการทำความสะอาด (ตัดตัวควบคุม/ตัวกลับทิศ/เส้นทาง)
// - เปิดผ่านลิงก์ลงลายเซ็นอายุ LINK_MINUTES นาที ผูกกับผู้ดู + ตรวจสิทธิ์ห้องซ้ำทุกครั้งที่เปิด
// - ลบไฟล์พร้อมข้อความ / ห้อง / บัญชี ตามนโยบายเดิมของรูปในแชท
// =======================================================

class ChatAttachment
{
    public const MAX_FILE_KB = 10240;

    public const MAX_VOICE_KB = 4096;

    public const MAX_VOICE_MS = 180000;

    public const LINK_MINUTES = 10;

    // ส่งไฟล์/เสียงได้ไม่เกินกี่ครั้งต่อนาที (ต่อผู้ใช้ รวมทุกห้อง)
    public const UPLOADS_PER_MINUTE = 20;

    public const FILE_TYPES = [
        'pdf' => 'application/pdf',
        'txt' => 'text/plain',
        'docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'xlsx' => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        'pptx' => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    ];

    private const OFFICE_MAIN_PART = [
        'docx' => 'word/document.xml',
        'xlsx' => 'xl/workbook.xml',
        'pptx' => 'ppt/presentation.xml',
    ];

    public const VOICE_MIME = 'audio/mp4';

    public static function disk(): string
    {
        $disk = MediaStorage::disk();

        return $disk === 'public' ? 'local' : $disk;
    }

    // กฎตรวจขนาดเบื้องต้น (ตรวจเนื้อไฟล์จริงต่อใน inspect)
    public static function rules(): array
    {
        return [
            'file' => 'nullable|file|max:' . self::MAX_FILE_KB,
            'voice' => 'nullable|file|max:' . self::MAX_VOICE_KB,
            'voice_duration_ms' => 'nullable|integer|min:0|max:' . (self::MAX_VOICE_MS + 2000),
        ];
    }

    public static function messages(): array
    {
        return [
            'file.file' => 'ส่งไฟล์ไม่สำเร็จ กรุณาเลือกไฟล์ใหม่',
            'file.max' => 'ไฟล์ต้องมีขนาดไม่เกิน 10 MB',
            'file.uploaded' => 'ไฟล์ต้องมีขนาดไม่เกิน 10 MB',
            'voice.file' => 'ส่งข้อความเสียงไม่สำเร็จ กรุณาอัดใหม่',
            'voice.max' => 'ข้อความเสียงต้องมีขนาดไม่เกิน 4 MB',
            'voice.uploaded' => 'ข้อความเสียงต้องมีขนาดไม่เกิน 4 MB',
            'voice_duration_ms.max' => 'ข้อความเสียงยาวได้ไม่เกิน 3 นาที',
        ];
    }

    public static function hasUpload(Request $request): bool
    {
        return $request->hasFile('file') || $request->hasFile('voice');
    }

    // ตรวจไฟล์แนบของคำขอ → ข้อมูลที่จะบันทึก (null = ไม่มีไฟล์แนบ) / ไม่ผ่าน → 422 ภาษาไทย
    public static function inspect(Request $request, int $userId): ?array
    {
        $file = $request->file('file');
        $voice = $request->file('voice');

        if (!$file && !$voice) {
            return null;
        }

        if (($file && $voice) || $request->hasFile('image')) {
            throw ValidationException::withMessages([
                'file' => 'ส่งไฟล์แนบได้ครั้งละ 1 อย่าง',
            ]);
        }

        // จำกัดความถี่อัปโหลด (ส่งซ้ำด้วย client_id เดิมไม่ถึงจุดนี้)
        $key = 'chat-upload:' . $userId;

        if (RateLimiter::tooManyAttempts($key, self::UPLOADS_PER_MINUTE)) {
            throw new HttpResponseException(response()->json([
                'status' => false,
                'message' => 'ส่งไฟล์ถี่เกินไป กรุณารอสักครู่แล้วลองใหม่',
            ], 429));
        }

        RateLimiter::hit($key, 60);

        return $file ? self::inspectFile($file) : self::inspectVoice($voice);
    }

    private static function inspectFile(UploadedFile $file): array
    {
        $extension = strtolower($file->getClientOriginalExtension());
        $path = $file->getRealPath();

        if (!isset(self::FILE_TYPES[$extension]) || $path === false) {
            throw ValidationException::withMessages([
                'file' => 'รองรับเฉพาะไฟล์ PDF, TXT, DOCX, XLSX และ PPTX',
            ]);
        }

        $content = (string) file_get_contents($path);

        $valid = match ($extension) {
            'pdf' => str_starts_with($content, '%PDF-'),
            'txt' => self::isPlainText($content),
            default => self::isOfficeFile($content, self::OFFICE_MAIN_PART[$extension]),
        };

        if (!$valid || self::looksExecutable($content)) {
            throw ValidationException::withMessages([
                'file' => 'ไฟล์นี้ไม่ตรงกับชนิดที่แจ้ง หรือเป็นชนิดที่ไม่รองรับ',
            ]);
        }

        return [
            'upload' => $file,
            'kind' => 'file',
            'name' => self::displayName($file->getClientOriginalName(), $extension),
            'mime' => self::FILE_TYPES[$extension],
            'size' => strlen($content),
            'duration_ms' => null,
        ];
    }

    private static function inspectVoice(UploadedFile $voice): array
    {
        $path = $voice->getRealPath();
        $content = $path === false ? '' : (string) file_get_contents($path);
        $duration = self::mp4DurationMs($content);

        if ($duration === null || $duration < 300) {
            throw ValidationException::withMessages([
                'voice' => 'ไฟล์เสียงไม่ถูกต้อง กรุณาอัดใหม่',
            ]);
        }

        if ($duration > self::MAX_VOICE_MS + 2000) {
            throw ValidationException::withMessages([
                'voice' => 'ข้อความเสียงยาวได้ไม่เกิน 3 นาที',
            ]);
        }

        return [
            'upload' => $voice,
            'kind' => 'voice',
            'name' => 'ข้อความเสียง.m4a',
            'mime' => self::VOICE_MIME,
            'size' => strlen($content),
            'duration_ms' => min($duration, self::MAX_VOICE_MS),
        ];
    }

    // ข้อความล้วน: ไม่มี NUL / ตัวควบคุมแปลก ๆ ไม่เกิน 1% (รองรับไฟล์ภาษาไทยทั้ง UTF-8 และรหัสเก่า)
    private static function isPlainText(string $content): bool
    {
        if ($content === '' || str_contains($content, "\0")) {
            return false;
        }

        $sample = substr($content, 0, 65536);
        $controls = preg_match_all('/[\x01-\x08\x0B\x0E-\x1F\x7F]/', $sample);

        return $controls !== false && $controls <= max(1, intdiv(strlen($sample), 100));
    }

    // DOCX/XLSX/PPTX = ZIP ที่มี [Content_Types].xml + ส่วนหลักของชนิดนั้น และไม่มีมาโคร
    private static function isOfficeFile(string $content, string $mainPart): bool
    {
        return str_starts_with($content, "PK\x03\x04")
            && str_contains($content, '[Content_Types].xml')
            && str_contains($content, $mainPart)
            && !str_contains($content, 'vbaProject.bin');
    }

    // โปรแกรม Windows / Linux / macOS / สคริปต์ที่ขึ้นต้นด้วย #!
    private static function looksExecutable(string $content): bool
    {
        $head = substr($content, 0, 4);

        return str_starts_with($head, 'MZ')
            || $head === "\x7FELF"
            || in_array($head, ["\xCF\xFA\xED\xFE", "\xCE\xFA\xED\xFE", "\xCA\xFE\xBA\xBE"], true)
            || str_starts_with($content, '#!');
    }

    // ความยาวเสียงจากกล่อง mvhd ของไฟล์ MP4/M4A (null = ไม่ใช่ไฟล์ MP4)
    public static function mp4DurationMs(string $content): ?int
    {
        if (strlen($content) < 16 || substr($content, 4, 4) !== 'ftyp') {
            return null;
        }

        $at = strpos($content, 'mvhd');

        if ($at === false || strlen($content) < $at + 32) {
            return null;
        }

        $version = ord($content[$at + 4]);

        if ($version === 1) {
            if (strlen($content) < $at + 40) {
                return null;
            }

            $timescale = unpack('N', substr($content, $at + 24, 4))[1];
            $parts = unpack('N2', substr($content, $at + 28, 8));
            $duration = ($parts[1] * 4294967296) + $parts[2];
        } else {
            $timescale = unpack('N', substr($content, $at + 16, 4))[1];
            $duration = unpack('N', substr($content, $at + 20, 4))[1];
        }

        if ($timescale <= 0) {
            return null;
        }

        return (int) round($duration * 1000 / $timescale);
    }

    // ชื่อที่แสดง: เฉพาะชื่อไฟล์ ตัดตัวควบคุม/ตัวกลับทิศ ยาวไม่เกิน 100 ตัวอักษร นามสกุลตามชนิดจริง
    public static function displayName(string $original, string $extension): string
    {
        $name = basename(str_replace('\\', '/', $original));
        $name = preg_replace('/[\x{0000}-\x{001F}\x{007F}\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}\x{FEFF}]/u', '', $name) ?? '';
        $base = trim((string) pathinfo($name, PATHINFO_FILENAME), " .\t");
        $base = mb_substr($base, 0, 100);

        return ($base === '' ? 'ไฟล์' : $base) . '.' . $extension;
    }

    // บันทึกลง disk ส่วนตัว ชื่อสุ่ม (ไม่มีนามสกุล/ชื่อเดิม)
    public static function store(array $inspected, string $folder): string
    {
        /** @var UploadedFile $upload */
        $upload = $inspected['upload'];

        return Storage::disk(self::disk())->putFileAs($folder, $upload, (string) Str::uuid());
    }

    public static function columns(?array $inspected, ?string $path): array
    {
        return [
            'attachment_path' => $path,
            'attachment_kind' => $inspected['kind'] ?? null,
            'attachment_name' => $inspected['name'] ?? null,
            'attachment_mime' => $inspected['mime'] ?? null,
            'attachment_size' => $inspected['size'] ?? null,
            'voice_duration_ms' => $inspected['duration_ms'] ?? null,
        ];
    }

    // ข้อมูลไฟล์แนบสำหรับผู้ดูที่มีสิทธิ์เห็นข้อความนี้แล้วเท่านั้น
    public static function payload(Model $message, string $route, int $viewerId): ?array
    {
        if (!$message->attachment_path) {
            return null;
        }

        return [
            'kind' => $message->attachment_kind,
            'name' => $message->attachment_name,
            'mime' => $message->attachment_mime,
            'size' => (int) $message->attachment_size,
            'duration_ms' => $message->voice_duration_ms === null ? null : (int) $message->voice_duration_ms,
            'url' => URL::temporarySignedRoute(
                $route,
                now()->addMinutes(self::LINK_MINUTES),
                ['message' => $message->id, 'viewer' => $viewerId]
            ),
            'expires_in' => self::LINK_MINUTES * 60,
        ];
    }

    // ส่งไฟล์ให้ผู้มีสิทธิ์ (เรียกหลังตรวจสิทธิ์แล้ว)
    public static function respond(Model $message)
    {
        $disk = Storage::disk(self::disk());

        if (!$message->attachment_path || !$disk->exists($message->attachment_path)) {
            return response()->json(['status' => false, 'message' => 'ไม่พบไฟล์นี้'], 404);
        }

        $headers = [
            'Content-Type' => $message->attachment_mime ?: 'application/octet-stream',
            'Cache-Control' => 'private, max-age=300',
            'X-Content-Type-Options' => 'nosniff',
            'Content-Security-Policy' => "default-src 'none'; sandbox",
        ];

        return $message->attachment_kind === 'voice'
            ? $disk->response($message->attachment_path, $message->attachment_name, $headers)
            : $disk->download($message->attachment_path, $message->attachment_name, $headers);
    }

    public static function deleteFiles(array $paths): void
    {
        $paths = array_values(array_filter($paths));

        if ($paths === []) {
            return;
        }

        $disk = self::disk();

        DB::afterCommit(function () use ($disk, $paths) {
            try {
                Storage::disk($disk)->delete($paths);
            } catch (Throwable $e) {
                Log::warning('Could not delete chat attachments', ['error' => $e->getMessage()]);
            }
        });
    }
}
