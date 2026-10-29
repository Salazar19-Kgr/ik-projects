-- 0006 · Acceso solo para correos autorizados
-- Un correo que no esté en allowed_emails no puede crear ni cambiar cuentas.
-- Al registrarse un correo autorizado, su perfil y rol se crean automáticamente.

create table public.allowed_emails (
  email      text primary key check (email = lower(btrim(email)) and email like '%@%'),
  role       public.app_role not null,
  full_name  text not null default 'Personal' check (char_length(full_name) between 2 and 120),
  created_at timestamptz not null default now()
);
alter table public.allowed_emails enable row level security;
revoke all on public.allowed_emails from anon, authenticated;

create or replace function public.enforce_allowed_email()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.email is null
     or not exists (select 1 from public.allowed_emails a where a.email = lower(btrim(new.email))) then
    raise exception 'email_no_autorizado';
  end if;
  return new;
end;
$$;

create or replace function public.provision_profile()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.profiles (id, full_name, role)
  select new.id, a.full_name, a.role
  from public.allowed_emails a
  where a.email = lower(btrim(new.email))
  on conflict (id) do update
    set role = excluded.role, full_name = excluded.full_name, active = true;
  return new;
end;
$$;

revoke all on function public.enforce_allowed_email(), public.provision_profile()
  from public, anon, authenticated;

create trigger trg_enforce_allowed_email
  before insert or update of email on auth.users
  for each row execute function public.enforce_allowed_email();

create trigger trg_provision_profile
  after insert on auth.users
  for each row execute function public.provision_profile();
