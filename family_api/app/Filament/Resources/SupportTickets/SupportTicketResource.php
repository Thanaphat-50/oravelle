<?php

namespace App\Filament\Resources\SupportTickets;

use App\Filament\Resources\SupportTickets\Pages\ListSupportTickets;
use App\Filament\Resources\SupportTickets\Pages\ViewSupportTicket;
use App\Filament\Resources\SupportTickets\Schemas\SupportTicketInfolist;
use App\Filament\Resources\SupportTickets\Tables\SupportTicketsTable;
use App\Models\SupportTicket;
use BackedEnum;
use Filament\Resources\Resource;
use Filament\Schemas\Schema;
use Filament\Support\Icons\Heroicon;
use Filament\Tables\Table;
use Illuminate\Database\Eloquent\Builder;

// =======================================================
// ศูนย์ช่วยเหลือ (หลังบ้าน): คำร้องจากผู้ใช้
// เข้าได้เฉพาะผู้ดูแล (users.is_admin — ดู User::canAccessPanel)
// ตอบผู้ใช้ / บันทึกภายใน / เปลี่ยนสถานะ / ปิดเรื่อง → หน้าดูคำร้อง (ViewSupportTicket)
// =======================================================

class SupportTicketResource extends Resource
{
    protected static ?string $model = SupportTicket::class;

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedLifebuoy;

    protected static ?string $modelLabel = 'คำร้อง';

    protected static ?string $pluralModelLabel = 'คำร้อง';

    protected static ?string $navigationLabel = 'ศูนย์ช่วยเหลือ';

    protected static ?int $navigationSort = 1;

    public static function getEloquentQuery(): Builder
    {
        return parent::getEloquentQuery()->with(['user:id,name,email']);
    }

    // เรื่องที่รอทีมงาน (ส่งแล้ว / กำลังตรวจสอบ)
    public static function getNavigationBadge(): ?string
    {
        $count = SupportTicket::whereIn('status', [SupportTicket::STATUS_SUBMITTED, SupportTicket::STATUS_IN_REVIEW])->count();

        return $count > 0 ? (string) $count : null;
    }

    public static function getNavigationBadgeColor(): ?string
    {
        return 'warning';
    }

    public static function canCreate(): bool
    {
        return false;
    }

    public static function table(Table $table): Table
    {
        return SupportTicketsTable::configure($table);
    }

    public static function infolist(Schema $schema): Schema
    {
        return SupportTicketInfolist::configure($schema);
    }

    public static function getPages(): array
    {
        return [
            'index' => ListSupportTickets::route('/'),
            'view' => ViewSupportTicket::route('/{record}'),
        ];
    }
}
