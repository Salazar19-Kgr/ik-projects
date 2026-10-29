import { auth, select, insert, patch, setJwt, esc, fmtUsd, fmtVes, configured } from './api.js';

const $ = (s) => document.querySelector(s);
const toast = (m) => { const t = $('#toast'); t.textContent = m; t.classList.add('on'); clearTimeout(toast.h); toast.h = setTimeout(() => t.classList.remove('on'), 5000); };
const show = (id) => { for (const x of ['paso-correo', 'paso-codigo', 'panel-admin']) $('#' + x).hidden = x !== id; };
const motivo = (e) => String(e && e.message ? e.message : e).slice(0, 90);
const num = (s) => { const r = String(s).trim(); const n = Number(r.includes(',') ? r.replace(/\./g, '').replace(',', '.') : r); return Number.isFinite(n) && n > 0 && n < 1e9 ? n : null; };
const ESTADOS = { recibido: 'Recibido', en_preparacion: 'En preparación', listo: 'Listo', entregado: 'Entregado', cancelado: 'Cancelado' };
let correo = '', tab = 'pedidos', timer = null;

const VISTAS = {
  async pedidos() {
    const rows = await select('orders?select=order_number,status,total_usd,total_ves,created_at,dining_tables(number)&order=created_at.desc&limit=30');
    if (!rows.length) return '<h2>Pedidos</h2><p class="vacio">Aún no hay pedidos.</p>';
    return '<h2>Pedidos</h2>' + rows.map((o) => `<div class="ped ${esc(o.status)}"><div class="ph"><b>#${Number(o.order_number)} · Mesa ${esc(o.dining_tables?.number ?? '?')}</b><span class="est">${ESTADOS[o.status] || esc(o.status)}</span></div><small>${fmtUsd(o.total_usd)} · ${fmtVes(o.total_ves)} · ${esc(new Date(o.created_at).toLocaleString('es-VE'))}</small></div>`).join('');
  },
  async menu() {
    const [cats, prods] = await Promise.all([select('categories?select=id,name&order=sort_order'), select('products?select=id,category_id,name,price_usd,available&order=sort_order')]);
    const opts = cats.map((c) => `<option value="${esc(c.id)}">${esc(c.name)}</option>`).join('');
    const lista = cats.map((c) => `<h3 class="sub">${esc(c.name)}</h3>` + prods.filter((p) => p.category_id === c.id).map((p) => `<div class="fila-admin"><div><b>${esc(p.name)}</b><small>${fmtUsd(p.price_usd)}</small></div><div class="acc"><input class="precio" id="pr-${esc(p.id)}" inputmode="decimal" value="${Number(p.price_usd).toFixed(2)}"><button class="mini" data-precio="${esc(p.id)}">Guardar</button><button class="mini ${p.available ? '' : 'off'}" data-disp="${esc(p.id)}" data-val="${p.available}">${p.available ? 'Disponible' : 'Agotado'}</button></div></div>`).join('')).join('');
    return `<h2>Menú</h2>${lista}<h3 class="sub">Agregar categoría</h3><div class="form"><input id="nc" placeholder="Nombre de la categoría"><button class="cta" data-acc="cat" style="margin-top:14px">Agregar categoría</button></div><h3 class="sub">Agregar plato</h3><div class="form"><select id="np-cat">${opts}</select><input id="np-n" placeholder="Nombre del plato"><input id="np-d" placeholder="Descripción"><input id="np-p" inputmode="decimal" placeholder="Precio en USD (ej: 8.50)"><button class="cta" data-acc="plato" style="margin-top:14px">Agregar plato</button></div>`;
  },
  async mesas() {
    const rows = await select('dining_tables?select=number,label,status,qr_token&order=number');
    return '<h2>Mesas y QR</h2><p class="hint">Cada enlace es el QR de una mesa. No lo compartas fuera del restaurante.</p>' + rows.map((t) => { const url = `${location.origin}/?t=${t.qr_token}`; return `<div class="fila-admin"><div><b>${esc(t.label || 'Mesa ' + t.number)}</b><small>${esc(t.status)}</small></div><div class="acc"><button class="mini" data-copiar="${esc(url)}">Copiar enlace</button><a class="mini" href="${esc(url)}" target="_blank" rel="noopener">Abrir</a></div></div>`; }).join('');
  },
  async tasa() {
    const rows = await select('exchange_rates?select=rate_ves,effective_at&order=effective_at.desc,id.desc&limit=8');
    return `<h2>Tasa del día</h2><p class="hint">Bs. por cada 1 USD. Se usa en los precios y cuentas en bolívares.</p><p><b>${rows.length ? 'Tasa vigente: ' + fmtVes(rows[0].rate_ves) : 'Aún no hay tasa: los pedidos están bloqueados.'}</b></p><input id="tasa" inputmode="decimal" placeholder="Ej: 832,48"><button class="cta" data-acc="tasa" style="margin-top:14px">Guardar tasa</button><div class="hist">${rows.map((r) => `<div><span>${esc(new Date(r.effective_at).toLocaleString('es-VE'))}</span><b>${fmtVes(r.rate_ves)}</b></div>`).join('')}</div>`;
  },
};

async function render() {
  clearInterval(timer);
  document.querySelectorAll('.tabs button').forEach((b) => b.classList.toggle('act', b.dataset.tab === tab));
  const v = $('#vista');
  try { v.innerHTML = await VISTAS[tab](); } catch (e) { v.innerHTML = '<p class="vacio">No se pudo cargar: ' + esc(motivo(e)) + '</p>'; }
  if (tab === 'pedidos') timer = setInterval(render, 10000);
}

async function entrar(jwt) {
  setJwt(jwt);
  const perfil = (await select('profiles?select=role&limit=1'))[0];
  if (!perfil || perfil.role !== 'admin') { setJwt(null); throw new Error('sin_permiso'); }
  try { sessionStorage.setItem('ik_jwt', jwt); } catch { /* sin almacenamiento */ }
  show('panel-admin');
  render();
}

$('#enviar').onclick = async () => {
  correo = $('#correo').value.trim().toLowerCase();
  if (!/^\S+@\S+\.\S+$/.test(correo)) return toast('Escribe un correo válido.');
  $('#enviar').disabled = true;
  try { await auth('otp', { email: correo, create_user: true }); show('paso-codigo'); }
  catch (e) { toast(/database|signup|not allowed|422|500/i.test(e.message) ? 'Correo no autorizado.' : 'No se pudo enviar el código: ' + motivo(e)); }
  $('#enviar').disabled = false;
};

$('#entrar').onclick = async () => {
  const token = $('#codigo').value.replace(/\s/g, '');
  if (!token) return toast('Escribe el código.');
  $('#entrar').disabled = true;
  let r;
  try {
    try { r = await auth('verify', { type: 'email', email: correo, token }); }
    catch { r = await auth('verify', { type: 'signup', email: correo, token }); }
  } catch (e) { $('#entrar').disabled = false; return toast('Código incorrecto o vencido: ' + motivo(e)); }
  try { await entrar(r.access_token); }
  catch (e) {
    if (e.message === 'sin_permiso') { show('paso-correo'); toast('Esta cuenta no tiene permisos de administración.'); }
    else toast('El código era correcto, pero falló la base de datos: ' + motivo(e));
  }
  $('#entrar').disabled = false;
};

document.addEventListener('click', async (e) => {
  const t = e.target.closest('[data-tab],[data-acc],[data-copiar],[data-precio],[data-disp],#salir');
  if (!t) return;
  const d = t.dataset;
  try {
    if (t.id === 'salir') { try { sessionStorage.removeItem('ik_jwt'); } catch { /* nada */ } location.reload(); return; }
    if ('tab' in d) { tab = d.tab; return render(); }
    if ('copiar' in d) { await navigator.clipboard.writeText(d.copiar); return toast('Enlace copiado'); }
    if ('precio' in d) { const n = num($('#pr-' + d.precio).value); if (!n) return toast('Precio no válido.'); await patch('products?id=eq.' + encodeURIComponent(d.precio), { price_usd: n }); toast('Precio actualizado'); return render(); }
    if ('disp' in d) { await patch('products?id=eq.' + encodeURIComponent(d.disp), { available: d.val !== 'true' }); return render(); }
    if (d.acc === 'tasa') { const n = num($('#tasa').value); if (!n) return toast('Escribe una tasa válida.'); await insert('exchange_rates', { rate_ves: n, source: 'BCV' }); toast('Tasa guardada'); return render(); }
    if (d.acc === 'cat') { const name = $('#nc').value.trim(); if (!name) return toast('Escribe el nombre.'); await insert('categories', { name, sort_order: 99 }); toast('Categoría agregada'); return render(); }
    if (d.acc === 'plato') {
      const name = $('#np-n').value.trim(), price = num($('#np-p').value), category_id = $('#np-cat').value;
      if (!name || !price || !category_id) return toast('Completa categoría, nombre y precio.');
      await insert('products', { category_id, name, description: $('#np-d').value.trim(), price_usd: price, sort_order: 99 });
      toast('Plato agregado'); return render();
    }
  } catch (err) { toast('No se pudo completar: ' + motivo(err)); }
});

(async () => {
  if (!configured()) { toast('Falta configurar la conexión (config.js).'); return; }
  let j = null;
  try { j = sessionStorage.getItem('ik_jwt'); } catch { /* nada */ }
  if (j) {
    try { await entrar(j); }
    catch { setJwt(null); try { sessionStorage.removeItem('ik_jwt'); } catch { /* nada */ } }
  }
})();

import { imgUrl, upload } from './api.js';

VISTAS.pagos = async function () {
  const rows = await select('payment_methods?select=id,kind,label,currency,instructions,active&order=sort_order,created_at');
  const lista = rows.map((p) => `<div class="fila-admin" style="display:block"><div style="display:flex;justify-content:space-between;gap:8px;align-items:center"><div><b>${esc(p.label)}</b><small>${p.currency === 'VES' ? 'Bolívares' : 'Dólares'}</small></div><button class="mini ${p.active ? '' : 'off'}" data-pact="${esc(p.id)}" data-val="${p.active}">${p.active ? 'Visible' : 'Oculto'}</button></div><textarea id="pi-${esc(p.id)}" maxlength="1000" placeholder="Instrucciones para el cliente">${esc(p.instructions)}</textarea><button class="mini" style="margin-top:8px" data-pins="${esc(p.id)}">Guardar instrucciones</button></div>`).join('');
  return `<h2>Formas de pago</h2><p class="hint">Lo que dejes visible aquí lo ven los clientes en su mesa. Escribe solo datos que quieras que sean públicos.</p>${lista}<h3 class="sub">Agregar forma de pago</h3><div class="form"><select id="pm-k"><option value="pago_movil">Pago móvil</option><option value="transferencia_ves">Transferencia (Bs.)</option><option value="zelle">Zelle</option><option value="efectivo_usd">Efectivo USD</option><option value="efectivo_ves">Efectivo Bs.</option><option value="tarjeta">Tarjeta</option><option value="otro">Otro</option></select><input id="pm-l" placeholder="Nombre (ej: Pago móvil Banesco)"><select id="pm-c"><option value="VES">Bolívares</option><option value="USD">Dólares</option></select><textarea id="pm-i" maxlength="1000" placeholder="Datos para pagar (banco, teléfono, cédula o RIF...)"></textarea><button class="cta" data-acc="pago" style="margin-top:14px">Agregar</button></div>`;
};

VISTAS.menu = async function () {
  const [cats, prods] = await Promise.all([select('categories?select=id,name&order=sort_order'), select('products?select=id,category_id,name,price_usd,available,image_path&order=sort_order')]);
  const opts = cats.map((c) => `<option value="${esc(c.id)}">${esc(c.name)}</option>`).join('');
  const fila = (p) => {
    const img = imgUrl(p.image_path);
    return `<div class="fila-admin"><div class="mini-foto">${img ? `<img src="${esc(img)}" alt="">` : esc(p.name.charAt(0))}</div><div class="grow"><b>${esc(p.name)}</b><small>${fmtUsd(p.price_usd)}</small><div class="acc" style="justify-content:flex-start;margin-top:8px"><input class="precio" id="pr-${esc(p.id)}" inputmode="decimal" value="${Number(p.price_usd).toFixed(2)}"><button class="mini" data-precio="${esc(p.id)}">Guardar</button><label class="mini" for="ph-${esc(p.id)}">Foto</label><input type="file" accept="image/*" id="ph-${esc(p.id)}" data-foto="${esc(p.id)}" hidden><button class="mini ${p.available ? '' : 'off'}" data-disp="${esc(p.id)}" data-val="${p.available}">${p.available ? 'Disponible' : 'Agotado'}</button></div></div></div>`;
  };
  const lista = cats.map((c) => `<h3 class="sub">${esc(c.name)}</h3>` + prods.filter((p) => p.category_id === c.id).map(fila).join('')).join('');
  return `<h2>Menú</h2>${lista}<h3 class="sub">Agregar categoría</h3><div class="form"><input id="nc" placeholder="Nombre de la categoría"><button class="cta" data-acc="cat" style="margin-top:14px">Agregar categoría</button></div><h3 class="sub">Agregar plato</h3><div class="form"><select id="np-cat">${opts}</select><input id="np-n" placeholder="Nombre del plato"><input id="np-d" placeholder="Descripción"><input id="np-p" inputmode="decimal" placeholder="Precio en USD (ej: 8.50)"><button class="cta" data-acc="plato" style="margin-top:14px">Agregar plato</button></div>`;
};

async function reducir(file) {
  const bmp = await createImageBitmap(file);
  const k = Math.min(1, 1000 / Math.max(bmp.width, bmp.height));
  const c = document.createElement('canvas');
  c.width = Math.round(bmp.width * k);
  c.height = Math.round(bmp.height * k);
  c.getContext('2d').drawImage(bmp, 0, 0, c.width, c.height);
  return new Promise((ok, no) => c.toBlob((b) => (b ? ok(b) : no(new Error('No se pudo procesar la foto'))), 'image/jpeg', 0.82));
}

document.addEventListener('click', async (e) => {
  const t = e.target.closest('[data-pact],[data-pins],[data-acc="pago"]');
  if (!t) return;
  const d = t.dataset;
  try {
    if ('pact' in d) { await patch('payment_methods?id=eq.' + encodeURIComponent(d.pact), { active: d.val !== 'true' }); return render(); }
    if ('pins' in d) { await patch('payment_methods?id=eq.' + encodeURIComponent(d.pins), { instructions: $('#pi-' + d.pins).value.trim() }); return toast('Instrucciones guardadas'); }
    const label = $('#pm-l').value.trim();
    if (!label) return toast('Escribe el nombre.');
    await insert('payment_methods', { kind: $('#pm-k').value, label, currency: $('#pm-c').value, instructions: $('#pm-i').value.trim(), sort_order: 99 });
    toast('Forma de pago agregada');
    return render();
  } catch (err) { toast('No se pudo completar: ' + motivo(err)); }
});

document.addEventListener('change', async (e) => {
  const id = e.target.dataset && e.target.dataset.foto;
  if (!id || !e.target.files[0]) return;
  toast('Subiendo foto…');
  try {
    const blob = await reducir(e.target.files[0]);
    const path = `${id}-${Date.now()}.jpg`;
    await upload(path, blob);
    await patch('products?id=eq.' + encodeURIComponent(id), { image_path: path });
    toast('Foto actualizada');
    render();
  } catch (err) { toast('No se pudo subir la foto: ' + motivo(err)); }
});
