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

function card(p, i) {
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
  $('#panel').innerHTML = `<div class="stabs"><button data-view="cart" class="${a('cart')}">Tu pedido</button><button data-view="orders" class="${a('orders')}">Seguimiento</button><button data-close aria-label="Cerrar">✕</button></div>` + (S.view === 'cart' ? cartHtml() : ordersHtml());
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
  try { S.pagos = await select('payment_methods?select=label,currency,instructions&order=sort_order'); if (S.view) renderSheet(); } catch { /* sin formas de pago */ }
}
cargarPagos();
function exito() {
  const d = document.createElement('div');
  d.className = 'exito';
  d.innerHTML = '<svg viewBox="0 0 52 52" width="96" height="96"><circle cx="26" cy="26" r="24" fill="none" stroke="#2E6B55" stroke-width="3"/><path d="M15 27l8 8 14-16" fill="none" stroke="#2E6B55" stroke-width="3.5" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  document.body.appendChild(d);
  setTimeout(() => d.remove(), 1500);
}
