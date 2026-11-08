<?php

namespace Tests\Concerns;

use Illuminate\Http\Client\Pool;
use Illuminate\Http\Client\Response;
use Illuminate\Support\Facades\Artisan;
use Illuminate\Support\Facades\Http;

// =======================================================
// ทดสอบคำขอที่เข้าพร้อมกันจริง
// เปิดเซิร์ฟเวอร์ PHP หลายตัว (คนละ process) ที่ใช้ฐานข้อมูลทดสอบเดียวกัน แล้วยิงคำขอพร้อมกัน
//
// รันเฉพาะเมื่อตั้ง CONCURRENCY_TESTS=1 และฐานข้อมูลเป็นฐานทดสอบเท่านั้น
// (MySQL ชื่อลงท้าย _test / ไฟล์ SQLite ในโฟลเดอร์ชั่วคราว) เพราะทดสอบนี้ล้างทุกตาราง
// วิธีรันดูที่ docs/orders.md หัวข้อ "ทดสอบคำขอพร้อมกัน"
// =======================================================

trait RunsParallelServers
{
    /** @var array<int, resource> */
    private array $serverProcesses = [];

    /** @var array<int, string> */
    private array $serverUrls = [];

    protected function setUpParallelDatabase(): void
    {
        if (!filter_var(env('CONCURRENCY_TESTS'), FILTER_VALIDATE_BOOL)) {
            $this->markTestSkipped('ตั้ง CONCURRENCY_TESTS=1 พร้อมฐานข้อมูลทดสอบเพื่อรันทดสอบคำขอพร้อมกัน');
        }

        $this->assertSafeTestDatabase();

        Artisan::call('migrate:fresh', ['--force' => true]);
    }

    // กันล้างฐานข้อมูลจริงโดยไม่ตั้งใจ
    private function assertSafeTestDatabase(): void
    {
        if (app()->environment('production')) {
            $this->fail('ไม่รันทดสอบคำขอพร้อมกันบน production');
        }

        $connection = (string) config('database.default');
        $config = (array) config("database.connections.{$connection}");
        $database = (string) ($config['database'] ?? '');

        $safe = match ($config['driver'] ?? null) {
            'sqlite' => $database !== ':memory:'
                && is_file($database)
                && str_starts_with(
                    strtolower((string) realpath(dirname($database))),
                    strtolower((string) realpath(sys_get_temp_dir()))
                ),
            'mysql', 'mariadb' => preg_match('/_test(ing)?$/i', $database) === 1
                && in_array($config['host'] ?? null, ['127.0.0.1', 'localhost'], true),
            default => false,
        };

        if (!$safe) {
            $this->fail("ฐานข้อมูล {$connection}:{$database} ไม่ใช่ฐานทดสอบ (MySQL ต้องลงท้าย _test / SQLite ต้องอยู่ในโฟลเดอร์ชั่วคราว)");
        }
    }

    // ใช้ฐานข้อมูลเดียวกับ process ทดสอบ ปิดบริการภายนอก (ตรวจสลิป / Push)
    private function childEnv(): array
    {
        return [
            ...getenv(),
            'APP_ENV' => 'testing',
            'CACHE_STORE' => 'array',
            'SESSION_DRIVER' => 'array',
            'QUEUE_CONNECTION' => 'sync',
            'MAIL_MAILER' => 'array',
            'EASYSLIP_API_KEY' => '',
            'FIREBASE_CREDENTIALS_BASE64' => '',
        ];
    }

    private function nullDevice(): string
    {
        return PHP_OS_FAMILY === 'Windows' ? 'NUL' : '/dev/null';
    }

    // เริ่มคำสั่ง artisan หลาย process พร้อมกัน (ไม่รอ) → ส่งให้ waitForCommands()
    protected function startCommands(string $command, int $count): array
    {
        $processes = [];

        for ($i = 0; $i < $count; $i++) {
            $process = proc_open(
                [PHP_BINARY, base_path('artisan'), $command],
                [0 => ['pipe', 'r'], 1 => ['file', $this->nullDevice(), 'w'], 2 => ['file', $this->nullDevice(), 'w']],
                $pipes,
                base_path(),
                $this->childEnv()
            );

            $this->assertIsResource($process, "เริ่ม {$command} ไม่ได้");

            $processes[] = $process;
        }

        return $processes;
    }

    /** @return array<int, int> exit code ของแต่ละ process */
    protected function waitForCommands(array $processes): array
    {
        return array_map(fn ($process) => proc_close($process), $processes);
    }

    protected function startServers(int $count): void
    {
        $base = (int) (env('CONCURRENCY_PORT') ?: 8190);
        $null = $this->nullDevice();
        $env = $this->childEnv();

        for ($i = 0; $i < $count; $i++) {
            $port = $base + $i;

            $process = proc_open(
                [PHP_BINARY, '-S', "127.0.0.1:{$port}", base_path('vendor/laravel/framework/src/Illuminate/Foundation/resources/server.php')],
                [0 => ['pipe', 'r'], 1 => ['file', $null, 'w'], 2 => ['file', $null, 'w']],
                $pipes,
                public_path(),
                $env
            );

            $this->assertIsResource($process, "เปิดเซิร์ฟเวอร์ทดสอบพอร์ต {$port} ไม่ได้");

            $this->serverProcesses[] = $process;
            $this->serverUrls[] = "http://127.0.0.1:{$port}";
        }

        foreach ($this->serverUrls as $url) {
            $this->waitForServer($url);
        }
    }

    private function waitForServer(string $url): void
    {
        $deadline = microtime(true) + 15;

        while (microtime(true) < $deadline) {
            try {
                if (Http::timeout(2)->get("{$url}/up")->successful()) {
                    return;
                }
            } catch (\Throwable) {
                // ยังไม่พร้อม
            }

            usleep(200_000);
        }

        $this->fail("เซิร์ฟเวอร์ทดสอบ {$url} ไม่ตอบ");
    }

    /**
     * ยิงคำขอทั้งหมดพร้อมกัน (กระจายไปทุกเซิร์ฟเวอร์)
     *
     * @param  array<int, array{method: string, path: string, token: string, data?: array}>  $requests
     * @return array<int, Response>
     */
    protected function sendAtOnce(array $requests): array
    {
        $urls = $this->serverUrls;

        $responses = Http::pool(fn (Pool $pool) => collect($requests)->values()->map(
            fn (array $request, int $i) => $pool->as((string) $i)
                ->timeout(60)
                ->acceptJson()
                ->withToken($request['token'])
                ->send($request['method'], $urls[$i % count($urls)] . $request['path'], [
                    'json' => $request['data'] ?? [],
                ])
        )->all());

        return collect($responses)->sortKeys()->values()->all();
    }

    protected function tearDown(): void
    {
        foreach ($this->serverProcesses as $process) {
            proc_terminate($process);
            proc_close($process);
        }

        $this->serverProcesses = [];
        $this->serverUrls = [];

        parent::tearDown();
    }
}
