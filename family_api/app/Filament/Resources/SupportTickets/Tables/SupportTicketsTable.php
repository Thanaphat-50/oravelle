<?php

namespace App\Filament\Resources\SupportTickets\Tables;

use App\Models\SupportTicket;
use Filament\Actions\ViewAction;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Filters\Filter;
use Filament\Tables\Filters\SelectFilter;
use Filament\Tables\Table;
use Illuminate\Database\Eloquent\Builder;

class SupportTicketsTable
{
    public static function configure(Table $table): Table
    {
        return $table
            ->defaultSort('last_activity_at', 'desc')
            ->recordUrl(fn (SupportTicket $record) => route('filament.admin.resources.support-tickets.view', $record))
            ->columns([
                TextColumn::make('code')
                    ->label('เลขคำร้อง')
                    ->searchable()
                    ->copyable(),

                TextColumn::make('subject')
                    ->label('หัวข้อ')
                    ->searchable()
                    ->limit(50)
                    ->wrap(),

                TextColumn::make('user.name')
                    ->label('ผู้ใช้')
                    ->description(fn (SupportTicket $record) => $record->user?->email)
                    ->searchable(['name', 'email']),

                TextColumn::make('category')
                    ->label('ประเภท')
                    ->formatStateUsing(fn (string $state) => SupportTicket::CATEGORY_LABELS[$state] ?? $state)
                    ->badge()
                    ->color('gray'),

                TextColumn::make('order_code')
                    ->label('คำสั่งซื้อ')
                    ->placeholder('-')
                    ->searchable(),

                TextColumn::make('status')
                    ->label('สถานะ')
                    ->formatStateUsing(fn (string $state) => SupportTicket::STATUS_LABELS[$state] ?? $state)
                    ->badge()
                    ->color(fn (string $state) => match ($state) {
                        SupportTicket::STATUS_SUBMITTED => 'warning',
                        SupportTicket::STATUS_IN_REVIEW => 'info',
                        SupportTicket::STATUS_WAITING_USER => 'gray',
                        SupportTicket::STATUS_CLOSED => 'success',
                        default => 'gray',
                    }),

                TextColumn::make('last_activity_at')
                    ->label('อัปเดตล่าสุด')
                    ->since()
                    ->sortable(),
            ])
            ->filters([
                SelectFilter::make('status')
                    ->label('สถานะ')
                    ->options(SupportTicket::STATUS_LABELS),

                SelectFilter::make('category')
                    ->label('ประเภท')
                    ->options(SupportTicket::CATEGORY_LABELS),

                Filter::make('has_order')
                    ->label('เกี่ยวกับคำสั่งซื้อ')
                    ->query(fn (Builder $query) => $query->whereNotNull('order_code')),
            ])
            ->recordActions([
                ViewAction::make()->label('เปิดดู'),
            ]);
    }
}
