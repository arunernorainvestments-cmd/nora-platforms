-- Migration 010: Add duration_label to markets
-- Stores the human-readable duration string set at market creation time
-- e.g. '15 min', '1 Hour', '4 Hours', '1 Day'

ALTER TABLE public.markets
  ADD COLUMN duration_label text;
