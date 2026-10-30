import { rpc, select, imgUrl, fmtUsd, fmtVes, esc, ERR, configured } from './api.js';

const $ = (s) => document.querySelector(s);
const token = new URLSearchParams(location.search).get('t');
const S = { cart: new Map(), rate: null, cats: [], prods: [], view: null, orders: [], nota: '' };
const ESTADOS = { recibido: 'Recibido', en_preparacion: 'En preparación', listo: 'Listo para servir', entregado: 'Entregado', cancelado: 'Cancelado' };

const toast = (m) => { const t = $('#toast'); t.textContent = m; t.classList.add('on'); clearTimeout(toast.h); toast.h = setTimeout(() => t.classList.remove('on'), 3200); };
const fail = (e) => toast(ERR[e.message] || (/fetch|network/i.test(e.message) ? ERR.Failed : 'Ocurrió un problema. Intenta de nuevo.'));
const price = (usd) => fmtUsd(usd) + (S.rate ? ` · ${fmtVes(usd * S.rate)}` : '');
const count = () => [...S.cart.values()].reduce((n, l) => n + l.qty, 0);
const subtotal = () => [...S.cart.values()].reduce((n, l) => n + l.qty * Number(l.p.price_usd), 0);
const aviso = (m) => { $('#app').hidden = true; $('#aviso').textContent = m; };

function cardViejo(p, i) {
  const img = imgUrl(p.image_path);
  return `<article class="card" style="--i:${i}"><div class="foto">${img ? `<img src="${esc(img)}" alt="" loading="lazy">` : `<span>${esc(p.name.charAt(0))}</span>`}</div>
  <div class="info"><h3>${esc(p.name)}</h3><p>${esc(p.description)}</p><div class="pie"><b>${price(p.price_usd)}</b>
  ${p.available ? `<button class="add" data-add="${esc(p.id)}" aria-label="Agregar ${esc(p.name)}">+</button>` : '<em>Agotado</em>'}</div></div></article>`;
}
function renderMenu() {
  const g = S.cats.map((c) => ({ c, items: S.prods.filter((p) => p.category_id === c.id) })).filter((x) => x.items.length);
  $('#tabs').innerHTML = g.map(({ c }) => `<a href="#c-${esc(c.id)}">${esc(c.name)}</a>`).join('');
  $('#menu').innerHTML = g.map(({ c, items }) => `<section id="c-${esc(c.id)}"><h2>${esc(c.name)}</h2>${items.map(card).join('')}</section>`).join('') || '<p class="vacio">El menú aún no está disponible.</p>';
}
function renderBar() {
  const n = count(), b = $('#bar');
  b.classList.toggle('on', n > 0);
  b.innerHTML = `<span>${n} ${n === 1 ? 'plato' : 'platos'}</span><b>${fmtUsd(subtotal())}</b><span>Ver pedido →</span>`;
}
function cartHtml() {
  if (!S.cart.size) return '<p class="vacio">Aún no has agregado platos.</p>';
  const lines = [...S.cart.values()].map(({ p, qty }) => `<div class="line"><div><b>${esc(p.name)}</b><small>${fmtUsd(p.price_usd)} c/u</small></div><div class="qty"><button data-dec="${esc(p.id)}" aria-label="Quitar uno">−</button><span>${qty}</span><button data-inc="${esc(p.id)}" aria-label="Agregar uno">+</button></div></div>`).join('');
  return `${lines}<textarea id="nota" maxlength="300" placeholder="Instrucciones especiales (opcional)">${esc(S.nota)}</textarea>
  <div class="tot"><span>Subtotal</span><b>${price(subtotal())}</b></div><p class="hint">Los impuestos y el total final los calcula el sistema al enviar.</p>${pagosHtml()}<button class="cta" data-send>Enviar pedido</button>`;
}
function ordersHtml() {
  const list = S.orders.length ? S.orders.map((o) => `<div class="ped ${esc(o.status)}"><div class="ph"><b>Pedido #${Number(o.number)}</b><span class="est">${ESTADOS[o.status] || esc(o.status)}</span></div><ul>${o.items.map((i) => `<li>${Number(i.quantity)}× ${esc(i.name)}</li>`).join('')}</ul><small>Total ${fmtUsd(o.total_usd)} · ${fmtVes(o.total_ves)}</small></div>`).join('') : '<p class="vacio">Todavía no tienes pedidos en esta mesa.</p>';
  return list + pagosHtml() + '<button class="ghost" data-call>Llamar al mesero</button>';
}
function renderSheet() {
  const nota = $('#nota'); if (nota) S.nota = nota.value;
  const a = (v) => (S.view === v ? 'act' : '');
  $('#panel').innerHTML = `<div class="stabs"><button data-view="cart" class="${a('cart')}">Tu pedido</button><button data-view="orders" class="${a('orders')}">Seguimiento</button><button data-view="pagar" class="${a("pagar")}">Pagar</button><button data-close aria-label="Cerrar">✕</button></div>` + (S.view === 'cart' ? cartHtml() : S.view === 'pagar' ? pagarHtml() : ordersHtml());
}
async function refreshOrders() {
  try { S.orders = await rpc('get_table_orders', { p_token: token }); if (S.view === 'orders') renderSheet(); } catch (e) { if (S.view === 'orders') fail(e); }
}
function openSheet(v) { S.view = v; renderSheet(); $('#sheet').classList.add('on'); document.body.classList.add('noscroll'); if (v === 'orders') refreshOrders(); }
function closeSheet() { S.view = null; $('#sheet').classList.remove('on'); document.body.classList.remove('noscroll'); }

async function send() {
  const btn = $('[data-send]'); btn.disabled = true;
  try {
    const nota = ($('#nota')?.value || '').trim();
    const items = [...S.cart.values()].map(({ p, qty }) => ({ product_id: p.id, quantity: qty }));
    await rpc('create_order', { p_token: token, p_items: items, p_notes: nota });
    S.cart.clear(); S.nota = ''; renderBar(); exito(); toast('¡Pedido enviado a cocina!'); openSheet('orders');
  } catch (e) { fail(e); btn.disabled = false; }
}

document.addEventListener('click', (e) => {
  const t = e.target.closest('[data-add],[data-inc],[data-dec],[data-view],[data-close],[data-send],[data-call]');
  if (!t) return;
  const d = t.dataset;
  if ('add' in d || 'inc' in d) {
    const id = d.add || d.inc, p = S.prods.find((x) => x.id === id);
    if (!p) return;
    const l = S.cart.get(id) || { p, qty: 0 };
    if (l.qty < 50) l.qty++;
    S.cart.set(id, l); renderBar();
    if (S.view === 'cart') renderSheet();
    if ('add' in d) { t.classList.add('pop'); setTimeout(() => t.classList.remove('pop'), 250); }
  } else if ('dec' in d) {
    const l = S.cart.get(d.dec);
    if (l && --l.qty < 1) S.cart.delete(d.dec);
    renderBar(); renderSheet();
  } else if ('view' in d) openSheet(d.view);
  else if ('close' in d) closeSheet();
  else if ('send' in d) send();
  else if ('call' in d) rpc('create_service_call', { p_token: token, p_type: 'mesero' }).then(() => toast('Un mesero va en camino')).catch(fail);
});
setInterval(() => { if (S.view === 'orders') refreshOrders(); }, 8000);

(async function init() {
  if (!configured()) return aviso('Falta configurar la conexión del sistema.');
  if (!token) return inicio();
  try {
    const t = (await rpc('resolve_table', { p_token: token }))[0];
    if (!t) return aviso('Este código QR no es válido. Pide ayuda al personal.');
    const [cats, prods, info] = await Promise.all([select('categories?select=*&order=sort_order'), select('products?select=*&order=sort_order'), rpc('public_info')]);
    S.cats = cats; S.prods = prods; S.rate = info && info.rate_ves ? Number(info.rate_ves) : null;
    if (info && info.name) { $('#nombre').textContent = info.name; document.title = info.name; }
    $('#mesa').textContent = t.label || 'Mesa ' + t.number;
    renderMenu(); renderBar();
    $('#app').hidden = false; $('#aviso').hidden = true;
  } catch (e) { aviso(ERR[e.message] || 'No pudimos cargar el menú. Revisa tu conexión.'); }
})();

function inicio() {
  $('#app').hidden = true;
  $('#aviso').innerHTML = '<h1 style="font-size:36px;margin-bottom:10px">Bienvenido</h1><p>Si eres cliente, escanea el código QR de tu mesa para ver el menú y hacer tu pedido.</p><a class="cta" style="display:block;text-decoration:none;text-align:center;margin-top:26px" href="/admin/">Entrar a administración</a>';
}

S.pagos = [];
function pagosHtml() {
  const lista = S.pagos || [];
  if (!lista.length) return '';
  return '<h3 class="sub">Formas de pago</h3>' + lista.map((p) => `<div class="pago"><b>${esc(p.label)}</b><small>${p.currency === 'VES' ? 'Bolívares' : 'Dólares'}</small><p>${esc(p.instructions)}</p></div>`).join('');
}
async function cargarPagos() {
  try { S.pagos = await select('payment_methods?select=id,kind,label,currency,instructions&order=sort_order'); if (S.view) renderSheet(); } catch { /* sin formas de pago */ }
}
cargarPagos();
function exito() {
  const d = document.createElement('div');
  d.className = 'exito';
  d.innerHTML = '<svg viewBox="0 0 52 52" width="96" height="96"><circle cx="26" cy="26" r="24" fill="none" stroke="#2E6B55" stroke-width="3"/><path d="M15 27l8 8 14-16" fill="none" stroke="#2E6B55" stroke-width="3.5" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  document.body.appendChild(d);
  setTimeout(() => d.remove(), 1500);
}

import { uploadEvidence } from './api.js';

Object.assign(ERR, {
  payer_name_invalid: 'Escribe tu nombre completo.',
  payer_doc_invalid: 'Revisa tu cédula.',
  amount_invalid: 'El monto no es válido.',
  no_open_check: 'Aún no tienes consumo para pagar.',
  method_invalid: 'Esa forma de pago ya no está disponible.',
  evidence_invalid: 'No se pudo adjuntar el comprobante.',
});

const EMOJI = [[/combo/i, '🍱'], [/hamburg/i, '🍔'], [/perro|hot ?dog/i, '🌭'], [/pizza/i, '🍕'], [/papa|frita|aros/i, '🍟'], [/brownie|helado|postre/i, '🍰'], [/refresc|malta|jugo|papel[oó]n|bebida/i, '🥤'], [/teque/i, '🧀'], [/pabell/i, '🍛']];
const icono = (p) => {
  const cat = (S.cats.find((c) => c.id === p.category_id) || {}).name || '';
  const hit = EMOJI.find(([r]) => r.test(p.name) || r.test(cat));
  return hit ? hit[1] : '🍽️';
};
function card(p, i) {
  const img = imgUrl(p.image_path);
  return `<article class="card" style="--i:${i}"><div class="foto">${img ? `<img src="${esc(img)}" alt="${esc(p.name)}" loading="lazy">` : `<span class="emo">${icono(p)}</span>`}${p.available ? '' : '<span class="agot">Agotado</span>'}</div>
  <div class="info"><h3>${esc(p.name)}</h3><p>${esc(p.description)}</p><div class="pie"><div class="pr"><b>${fmtUsd(p.price_usd)}</b>${S.rate ? `<small>${fmtVes(p.price_usd * S.rate)}</small>` : ''}</div>${p.available ? `<button class="add" data-add="${esc(p.id)}" aria-label="Agregar ${esc(p.name)}">+</button>` : ''}</div></div></article>`;
}

const esEfectivo = (m) => m && (m.kind === 'efectivo_usd' || m.kind === 'efectivo_ves');
const metodoSel = () => { const el = $('#pg-m'); return el ? (S.pagos || []).find((p) => p.id === el.value) : null; };

function pagarHtml() {
  const c = S.cuenta;
  if (S.pagoOk) return '<div class="okpago"><h3>¡Pago enviado!</h3><p class="hint">Lo estamos verificando. El mesero te confirmará en breve.</p><button class="ghost" data-pagonuevo>Registrar otro pago</button></div>';
  if (!c) return '<p class="vacio">Cargando tu cuenta…</p>';
  if (!c.check_id) return '<p class="vacio">Todavía no tienes consumo en esta mesa.</p>';
  const ms = S.pagos || [];
  if (!ms.length) return '<p class="vacio">Aún no hay formas de pago configuradas. Pide ayuda al mesero.</p>';
  const m0 = ms[0], bal = Number(c.balance_usd), ves = S.rate ? bal * S.rate : null;
  const monto0 = (m0.currency === 'VES' && S.rate ? bal * S.rate : bal).toFixed(2);
  return `<div class="resumen"><div><small>Total</small><b>${fmtUsd(c.total_usd)}</b></div><div><small>Pagado</small><b>${fmtUsd(c.paid_usd)}</b></div><div class="debe"><small>Por pagar</small><b>${fmtUsd(bal)}</b>${ves ? `<em>${fmtVes(ves)}</em>` : ''}</div></div>
  <h3 class="sub">Datos del pago</h3>
  <label class="campo">Forma de pago<select id="pg-m">${ms.map((p) => `<option value="${esc(p.id)}">${esc(p.label)}</option>`).join('')}</select></label>
  <div class="pago"><p id="pg-info">${esc(m0.instructions)}</p></div>
  <label class="campo">Nombre completo<input id="pg-n" autocomplete="name" maxlength="120" placeholder="Como aparece en tu cédula"></label>
  <div class="campo"><span>Cédula</span><div class="dos"><select id="pg-t"><option>V</option><option>E</option><option>J</option><option>G</option><option>P</option></select><input id="pg-d" inputmode="numeric" maxlength="10" placeholder="12345678"></div></div>
  <label class="campo"><span id="pg-mon">${m0.currency === 'VES' ? 'Monto en bolívares (Bs.)' : 'Monto en dólares (USD)'}</span><input id="pg-a" inputmode="decimal" value="${monto0}"></label>
  <label class="campo">Número de referencia<input id="pg-r" maxlength="80" placeholder="Últimos dígitos de la operación"></label>
  <label class="campo" id="pg-fl" ${esEfectivo(m0) ? 'hidden' : ''}>Foto del comprobante<input id="pg-f" type="file" accept="image/*"></label>
  <p class="hint">Tus datos solo los ve el personal del restaurante para verificar el pago.</p>
  <button class="cta" data-enviarpago>Enviar pago para verificación</button>`;
}

function actualizarMetodo() {
  const m = metodoSel();
  if (!m) return;
  const bal = S.cuenta ? Number(S.cuenta.balance_usd) : 0;
  $('#pg-info').textContent = m.instructions || '';
  $('#pg-a').value = (m.currency === 'VES' && S.rate ? bal * S.rate : bal).toFixed(2);
  $('#pg-mon').textContent = m.currency === 'VES' ? 'Monto en bolívares (Bs.)' : 'Monto en dólares (USD)';
  $('#pg-fl').hidden = esEfectivo(m);
}

async function cargarCuenta() {
  try { S.cuenta = await rpc('get_table_check', { p_token: token }); if (S.view === 'pagar') renderSheet(); } catch (e) { fail(e); }
}

async function reducirFoto(file) {
  const bmp = await createImageBitmap(file);
  const k = Math.min(1, 1000 / Math.max(bmp.width, bmp.height));
  const c = document.createElement('canvas');
  c.width = Math.round(bmp.width * k);
  c.height = Math.round(bmp.height * k);
  c.getContext('2d').drawImage(bmp, 0, 0, c.width, c.height);
  return new Promise((ok, no) => c.toBlob((b) => (b ? ok(b) : no(new Error('No se pudo procesar la foto'))), 'image/jpeg', 0.82));
}

async function enviarPago() {
  const m = metodoSel();
  const nombre = $('#pg-n').value.trim();
  const doc = $('#pg-t').value + '-' + $('#pg-d').value.replace(/\D/g, '');
  const monto = Number(String($('#pg-a').value).replace(',', '.'));
  const ref = $('#pg-r').value.trim();
  const archivo = $('#pg-f').files[0];
  const efectivo = esEfectivo(m);
  if (!m) return toast('Elige una forma de pago.');
  if (nombre.length < 3) return toast('Escribe tu nombre completo.');
  if (!/^[VEJGP]-\d{5,10}$/.test(doc)) return toast('Revisa tu cédula.');
  if (!(monto > 0)) return toast('Escribe el monto pagado.');
  if (!efectivo && !ref) return toast('Escribe el número de referencia.');
  if (!efectivo && !archivo) return toast('Adjunta la foto del comprobante.');
  const btn = $('[data-enviarpago]');
  btn.disabled = true;
  let id;
  try {
    id = await rpc('submit_payment', { p_token: token, p_method_id: m.id, p_amount: monto, p_reference: ref, p_payer_name: nombre, p_payer_doc: doc });
  } catch (e) { fail(e); btn.disabled = false; return; }
  try {
    if (archivo) {
      const blob = await reducirFoto(archivo);
      const path = `${id}/${Date.now()}.jpg`;
      await uploadEvidence(path, blob);
      await rpc('attach_evidence', { p_payment_id: id, p_path: path, p_mime: 'image/jpeg', p_size: blob.size });
    }
  } catch { toast('El pago se registró, pero la foto no se pudo subir. Avisa al mesero.'); }
  S.pagoOk = true;
  exito();
  renderSheet();
  cargarCuenta();
}

document.addEventListener('click', (e) => {
  if (e.target.closest('[data-view="pagar"]')) cargarCuenta();
  if (e.target.closest('[data-pagonuevo]')) { S.pagoOk = false; renderSheet(); }
  if (e.target.closest('[data-enviarpago]')) enviarPago();
});
document.addEventListener('change', (e) => { if (e.target.id === 'pg-m') actualizarMetodo(); });
