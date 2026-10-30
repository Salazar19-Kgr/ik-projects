import { auth, select, rpc, setJwt, esc, configured } from './api.js';

const $ = (s) => document.querySelector(s);
const toast = (m) => { const t = $('#toast'); t.textContent = m; t.classList.add('on'); clearTimeout(toast.h); toast.h = setTimeout(() => t.classList.remove('on'), 4500); };
const show = (id) => { for (const x of ['paso-correo', 'paso-codigo', 'panel']) $('#' + x).hidden = x !== id; };
const motivo = (e) => String(e && e.message ? e.message : e).slice(0, 90);
let correo = '', rol = null, tab = 'recibido', timer = null, ultimos = -1;

const minutos = (f) => Math.max(0, Math.floor((Date.now() - new Date(f).getTime()) / 60000));

function alerta() {
  try { if (navigator.vibrate) navigator.vibrate([200, 100, 200]); } catch { /* sin vibración */ }
  try {
    const ctx = new (window.AudioContext || window.webkitAudioContext)();
    const o = ctx.createOscillator(), g = ctx.createGain();
    o.connect(g); g.connect(ctx.destination);
    o.frequency.value = 880; g.gain.value = 0.15;
    o.start(); o.stop(ctx.currentTime + 0.25);
  } catch { /* sin audio */ }
  toast('¡Nuevo pedido!');
}

function botones(o) {
  const cocina = rol === 'cocina' || rol === 'admin';
  const sala = rol === 'mesero' || rol === 'admin';
  const id = esc(o.id);
  const b = [];
  if (o.status === 'recibido' && cocina) b.push(`<button class="cta" data-mover="${id}" data-a="en_preparacion">Empezar a preparar</button>`);
  if (o.status === 'en_preparacion' && cocina) b.push(`<button class="cta" data-mover="${id}" data-a="listo">Marcar listo</button>`);
  if (o.status === 'listo' && sala) b.push(`<button class="cta" data-mover="${id}" data-a="entregado">Entregado a la mesa</button>`);
  if (rol === 'admin') b.push(`<button class="mini off" data-mover="${id}" data-a="cancelado">Cancelar</button>`);
  return b.join('') || '<small>Esperando al mesero…</small>';
}

function tarjeta(o) {
  const m = minutos(o.created_at);
  const mesa = o.dining_tables ? (o.dining_tables.label || 'Mesa ' + o.dining_tables.number) : 'Mesa';
  const items = (o.order_items || []).map((i) => `<li><b>${Number(i.quantity)}×</b> ${esc(i.product_name)}${i.notes ? `<em>“${esc(i.notes)}”</em>` : ''}</li>`).join('');
  return `<article class="tk ${m >= 15 ? 'tarde' : m >= 8 ? 'medio' : ''}"><div class="th"><b>${esc(mesa)}</b><span>#${Number(o.order_number)} · hace ${m} min</span></div><ul>${items}</ul>${o.notes ? `<p class="nota-pedido">Nota: ${esc(o.notes)}</p>` : ''}<div class="acc">${botones(o)}</div></article>`;
}

async function cargar() {
  let rows;
  try {
    rows = await select('orders?select=id,order_number,status,notes,created_at,dining_tables(number,label),order_items(product_name,quantity,notes)&status=in.(recibido,en_preparacion,listo)&order=created_at.asc&limit=100');
  } catch (e) { $('#lista').innerHTML = '<p class="vacio">No se pudo cargar: ' + esc(motivo(e)) + '</p>'; return; }
  const nuevos = rows.filter((o) => o.status === 'recibido').length;
  if (ultimos >= 0 && nuevos > ultimos) alerta();
  ultimos = nuevos;
  document.querySelectorAll('.tabs button').forEach((b) => {
    b.querySelector('i').textContent = rows.filter((o) => o.status === b.dataset.col).length;
    b.classList.toggle('act', b.dataset.col === tab);
  });
  const lista = rows.filter((o) => o.status === tab);
  $('#lista').innerHTML = lista.length ? lista.map(tarjeta).join('') : '<p class="vacio">Nada por aquí. ¡Buen trabajo!</p>';
}

async function entrar(jwt) {
  setJwt(jwt);
  const perfil = (await select('profiles?select=role&limit=1'))[0];
  if (!perfil) { setJwt(null); throw new Error('sin_permiso'); }
  rol = perfil.role;
  try { sessionStorage.setItem('ik_jwt', jwt); } catch { /* sin almacenamiento */ }
  show('panel');
  try { if (navigator.wakeLock) navigator.wakeLock.request('screen'); } catch { /* sin wake lock */ }
  await cargar();
  clearInterval(timer);
  timer = setInterval(cargar, 5000);
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
    if (e.message === 'sin_permiso') { show('paso-correo'); toast('Esta cuenta no tiene permisos.'); }
    else toast('El código era correcto, pero falló la base de datos: ' + motivo(e));
  }
  $('#entrar').disabled = false;
};

document.addEventListener('click', async (e) => {
  const t = e.target.closest('[data-col],[data-mover],#salir');
  if (!t) return;
  if (t.id === 'salir') { try { sessionStorage.removeItem('ik_jwt'); } catch { /* nada */ } location.reload(); return; }
  if (t.dataset.col) { tab = t.dataset.col; return cargar(); }
  const a = t.dataset.a;
  let razon = null;
  if (a === 'cancelado') { razon = prompt('Motivo de la cancelación:'); if (!razon) return; }
  t.disabled = true;
  try {
    await rpc('advance_order_status', { p_order_id: t.dataset.mover, p_new_status: a, p_reason: razon });
    toast(a === 'en_preparacion' ? 'Pedido en preparación' : a === 'listo' ? 'Pedido listo' : a === 'entregado' ? 'Pedido entregado' : 'Pedido cancelado');
  } catch (err) { toast('No se pudo cambiar el estado: ' + motivo(err)); }
  cargar();
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
