-- =====================================================================
-- 0005 · Almacenamiento (Supabase Storage)
--  · menu-images      → público (fotos del catálogo), escritura solo admin.
--  · payment-evidence → PRIVADO, sin acceso directo desde el navegador del
--    cliente; la subida se hará con URLs firmadas desde el servidor (Fase 4).
-- Se omite sin error si el esquema "storage" no existe (p. ej. en CI).
-- =====================================================================

do $$
begin
  if to_regnamespace('storage') is null then
    raise notice 'Esquema storage no encontrado: se omite 0005.';
    return;
  end if;

  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values
    ('menu-images', 'menu-images', true, 2097152,
     array['image/jpeg', 'image/png', 'image/webp']),
    ('payment-evidence', 'payment-evidence', false, 5242880,
     array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'])
  on conflict (id) do update
    set public = excluded.public,
        file_size_limit = excluded.file_size_limit,
        allowed_mime_types = excluded.allowed_mime_types;

  drop policy if exists menu_images_public_read  on storage.objects;
  drop policy if exists menu_images_admin_write  on storage.objects;
  drop policy if exists evidence_staff_read      on storage.objects;

  create policy menu_images_public_read on storage.objects
    for select to anon, authenticated
    using (bucket_id = 'menu-images');

  create policy menu_images_admin_write on storage.objects
    for all to authenticated
    using (bucket_id = 'menu-images' and (select public.staff_role()) = 'admin')
    with check (bucket_id = 'menu-images' and (select public.staff_role()) = 'admin');

  create policy evidence_staff_read on storage.objects
    for select to authenticated
    using (bucket_id = 'payment-evidence' and (select public.staff_role()) in ('admin', 'mesero'));
end;
$$;
