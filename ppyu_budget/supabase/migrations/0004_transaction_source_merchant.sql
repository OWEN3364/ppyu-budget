alter table transactions
  add column source text not null default 'manual' check (source in ('manual', 'notification_auto')),
  add column merchant text;
