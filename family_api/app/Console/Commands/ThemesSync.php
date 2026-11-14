<?php

namespace App\Console\Commands;

use App\Services\Themes\ThemeCatalog;
use Illuminate\Console\Command;

// แค็ตตาล็อก + ชุดไฟล์ธีมจาก resources/themes → ฐานข้อมูล (ตรวจ sha256/ขนาด/ชนิดทุกไฟล์)
class ThemesSync extends Command
{
    protected $signature = 'themes:sync';

    protected $description = 'Sync theme catalog and packs from resources/themes';

    public function handle(): int
    {
        $errors = ThemeCatalog::sync();

        foreach ($errors as $error) {
            $this->error($error);
        }

        if ($errors === []) {
            $this->info('Theme catalog synced');
        }

        return $errors === [] ? self::SUCCESS : self::FAILURE;
    }
}
