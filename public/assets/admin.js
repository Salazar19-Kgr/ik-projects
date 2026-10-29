import { auth, select, insert, setJwt, esc, fmtVes, configured } from './api.js';

const $ = (s) => document.querySelector(s);
const toast = (m) => { const t = $('#toast'); t.textContent = m; t.classList.add('on'); clearTimeout(toast.h); toast.h = setTimeout(() => t.classList.remove('on'), 3500); };
const show = (id) => { for (const x of ['paso-correo', 'paso-codigo', 'panel-admin']) $('#' + x).hidden = x !== id; };
let correo = '';

async function cargarTasas() {
  const rows = await select('exchange_rates?select=rate_ves,source,effective_at&order=effective_at.desc,id.desc&limit=8');
  $('#actual').textContent = rows.length ? 'Tasa vigente: ' + fmtVes(rows[0].rate_ves) : 'Aún no hay tasa registrada: los pedidos están bloqueados.';
  $('#hist').innerHTML = rows.map((r) => `<div><span>${esc(new Date(r.effective_at).toLocaleString('es-VE'))}</span><b>${fmtVes(r.rate_ves)}</b></div>`).join('');
}

$('#enviar').onclick = async () => {
  correo = $('#correo').value.trim().toLowerCase();
  if (!/^\S+@\S+\.\S+$/.test(correo)) return toast('Escribe un correo válido.');
  $('#enviar').disabled = true;
  try { await auth('otp', { email: correo, create_user: true }); show('paso-codigo'); }
  catch (e) { toast(/database|signup|not allowed|422|500/i.test(e.message) ? 'Correo no autorizado.' : 'No se pudo enviar el código. Espera un momento e intenta de nuevo.'); }
  $('#enviar').disabled = false;
};

$('#entrar').onclick = async () => {
  const token = $('#codigo').value.replace(/\s/g, '');
  if (!token) return toast('Escribe el código.');
  $('#entrar').disabled = true;
  try {
    let r;
    try { r = await auth('verify', { type: 'email', email: correo, token }); }
    catch { r = await auth('verify', { type: 'signup', email: correo, token }); }
    setJwt(r.access_token);
    const perfil = (await select('profiles?select=role&limit=1'))[0];
    if (!perfil || perfil.role !== 'admin') { setJwt(null); show('paso-correo'); return toast('Esta cuenta no tiene permisos de administración.'); }
    show('panel-admin'); await cargarTasas();
  } catch { toast('Código incorrecto o vencido.'); }
  $('#entrar').disabled = false;
};

$('#guardar').onclick = async () => {
  const v = Number($('#tasa').value.trim().replace(/\./g, '').replace(',', '.') || NaN);
  const raw = Number($('#tasa').value.trim().replace(',', '.'));
  const n = Number.isFinite(raw) && raw > 0 ? raw : v;
  if (!Number.isFinite(n) || n <= 0 || n > 1e9) return toast('Escribe una tasa válida.');
  $('#guardar').disabled = true;
  try { await insert('exchange_rates', { rate_ves: n, source: 'BCV' }); $('#tasa').value = ''; toast('Tasa guardada'); await cargarTasas(); }
  catch { toast('No se pudo guardar la tasa.'); }
  $('#guardar').disabled = false;
};

if (!configured()) { show('paso-correo'); toast('Falta configurar la conexión (config.js).'); }
