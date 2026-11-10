<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

// Reaction ของข้อความ (1 คน 1 Reaction ต่อข้อความ — unique)
class GroupChatMessageReaction extends Model
{
    protected $table = 'group_chat_message_reactions';

    protected $fillable = [
        'group_chat_message_id',
        'user_id',
        'emoji',
    ];

    public function message()
    {
        return $this->belongsTo(GroupChatMessage::class, 'group_chat_message_id');
    }
}
