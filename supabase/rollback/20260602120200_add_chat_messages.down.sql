-- Rollback for 20260602120200_add_chat_messages.sql
-- Drops the chat table. meetings / transcripts are untouched.
-- WARNING: destroys every saved chat conversation.

drop table if exists public.chat_messages cascade;
