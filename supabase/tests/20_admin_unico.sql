begin;
insert into public.allowed_emails (email, role, full_name)
values ('admin@prueba.local', 'admin', 'Administrador');

do $$
declare v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email) values (v_id, 'Admin@Prueba.local');
  assert (select role from public.profiles where id = v_id) = 'admin', 'perfil admin no creado';

  begin
    insert into auth.users (id, email) values (gen_random_uuid(), 'intruso@prueba.local');
    raise exception 'DEBIO_FALLAR';
  exception when others then
    assert sqlerrm = 'email_no_autorizado', 'intruso: ' || sqlerrm;
  end;

  begin
    update auth.users set email = 'otro@prueba.local' where id = v_id;
    raise exception 'DEBIO_FALLAR';
  exception when others then
    assert sqlerrm = 'email_no_autorizado', 'cambio de correo: ' || sqlerrm;
  end;

  raise notice 'OK: solo correos autorizados';
end;
$$;
rollback;
