<?php

namespace App\Support;

use Illuminate\Auth\AuthenticationException;
use Illuminate\Http\Exceptions\HttpResponseException;
use Illuminate\Http\Exceptions\PostTooLargeException;
use Illuminate\Http\Exceptions\ThrottleRequestsException;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Validation\ValidationException;
use Symfony\Component\HttpKernel\Exception\AccessDeniedHttpException;
use Symfony\Component\HttpKernel\Exception\HttpExceptionInterface;
use Symfony\Component\HttpKernel\Exception\MethodNotAllowedHttpException;
use Symfony\Component\HttpKernel\Exception\NotFoundHttpException;
use Throwable;

// =======================================================
// ข้อผิดพลาดของ API เป็นภาษาไทยที่ผู้ใช้เข้าใจ (ใช้ใน bootstrap/app.php)
// ไม่ส่งข้อความภายในของ Laravel เช่น "No query results for model [...]", "Server Error"
// รายละเอียดจริงยังถูกบันทึกใน log ตามปกติ (Laravel report ก่อน render)
//
// ไม่แตะ: ValidationException (แต่ละ Controller มีข้อความไทยเอง)
//        HttpResponseException / Response ที่ Controller ส่งเอง (เช่น 409, 429 ของ login)
// APP_DEBUG=true (ในเครื่อง) → ข้อผิดพลาด 500 ยังแสดงรายละเอียดให้นักพัฒนาเห็น
// =======================================================

class ApiErrors
{
    public static function render(Throwable $e, Request $request): ?JsonResponse
    {
        if (!$request->is('api/*')
            || $e instanceof ValidationException
            || $e instanceof HttpResponseException) {
            return null;
        }

        if ($e instanceof AuthenticationException) {
            return self::json(401, 'เซสชันหมดอายุ กรุณาเข้าสู่ระบบใหม่', ['code' => 'unauthenticated']);
        }

        if ($e instanceof ThrottleRequestsException) {
            $seconds = (int) ($e->getHeaders()['Retry-After'] ?? 60);

            return self::json(
                429,
                "ทำรายการบ่อยเกินไป กรุณารอ {$seconds} วินาทีแล้วลองใหม่",
                ['retry_after' => $seconds],
                $e->getHeaders()
            );
        }

        if ($e instanceof PostTooLargeException) {
            return self::json(413, 'ไฟล์ใหญ่เกินไป กรุณาเลือกไฟล์ที่เล็กลง');
        }

        if ($e instanceof HttpExceptionInterface && $e->getStatusCode() < 500) {
            $message = match (true) {
                $e instanceof NotFoundHttpException => 'ไม่พบข้อมูลที่ต้องการ อาจถูกลบไปแล้ว',
                $e instanceof AccessDeniedHttpException => 'คุณไม่มีสิทธิ์ทำรายการนี้',
                $e instanceof MethodNotAllowedHttpException => 'ทำรายการนี้ไม่ได้',
                default => 'ทำรายการไม่สำเร็จ กรุณาลองอีกครั้ง',
            };

            return self::json($e->getStatusCode(), $message, [], $e->getHeaders());
        }

        // ข้อผิดพลาดของระบบ: ในเครื่อง (debug) ให้ Laravel แสดงรายละเอียดตามเดิม
        if (config('app.debug')) {
            return null;
        }

        $status = $e instanceof HttpExceptionInterface ? $e->getStatusCode() : 500;

        return self::json(
            $status,
            $status === 503
                ? 'ระบบกำลังปรับปรุง กรุณาลองใหม่อีกสักครู่'
                : 'ระบบขัดข้องชั่วคราว กรุณาลองใหม่อีกสักครู่',
            [],
            $e instanceof HttpExceptionInterface ? $e->getHeaders() : []
        );
    }

    private static function json(int $status, string $message, array $extra = [], array $headers = []): JsonResponse
    {
        return response()->json([
            'status' => false,
            'message' => $message,
            ...$extra,
        ], $status, $headers);
    }
}
