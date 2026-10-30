const { SUPABASE_URL: U, SUPABASE_ANON_KEY: K } = window.IK_CONFIG || {};
let jwt = null;
export const setJwt = (t) => { jwt = t; };
export const configured = () => !!U && !!K && !U.startsWith('REEMPLAZAR');

async function call(path, opts = {}) {
  const headers = { apikey: K, 'Content-Type': 'application/json', ...opts.headers };
  if (jwt) headers.Authorization = 'Bearer ' + jwt;
  const res = await fetch(U + path, { ...opts, headers });
  const txt = await res.text();
  let body = null;
  try { body = txt ? JSON.parse(txt) : null; } catch { body = txt; }
  if (!res.ok) {
    const e = new Error((body && (body.message || body.msg || body.error_description)) || 'error_red');
    e.status = res.status;
    throw e;
  }
  return body;
}
export const rpc = (fn, args = {}) => call('/rest/v1/rpc/' + fn, { method: 'POST', body: JSON.stringify(args) });
export const select = (q) => call('/rest/v1/' + q);
export const insert = (t, row) => call('/rest/v1/' + t, { method: 'POST', headers: { Prefer: 'return=minimal' }, body: JSON.stringify(row) });
export const auth = (p, body) => call('/auth/v1/' + p, { method: 'POST', body: JSON.stringify(body) });
export const imgUrl = (p) => (p ? `${U}/storage/v1/object/public/menu-images/${encodeURIComponent(p)}` : null);

export const fmtUsd = (n) => '$' + Number(n).toFixed(2);
export const fmtVes = (n) => 'Bs. ' + new Intl.NumberFormat('es-VE', { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(n);
export const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

export const ERR = {
  table_not_found: 'Este código QR no es válido.',
  items_invalid: 'Algún plato ya no está disponible. Revisa tu pedido.',
  items_count_invalid: 'Tu pedido debe tener entre 1 y 40 platos.',
  notes_too_long: 'Las instrucciones son demasiado largas.',
  no_exchange_rate: 'El restaurante aún no ha configurado la tasa del día.',
  rate_limited: 'Demasiados pedidos seguidos. Espera un momento.',
  Failed: 'Sin conexión. Intenta de nuevo.',
};
export const patch = (q, row) => call('/rest/v1/' + q, { method: 'PATCH', headers: { Prefer: 'return=minimal' }, body: JSON.stringify(row) });
export async function upload(path, blob) {
  const res = await fetch(`${U}/storage/v1/object/menu-images/${path}`, {
    method: 'POST',
    headers: { apikey: K, Authorization: 'Bearer ' + jwt, 'Content-Type': blob.type, 'x-upsert': 'true' },
    body: blob,
  });
  if (!res.ok) throw new Error('No se pudo subir la foto (' + res.status + ')');
}
export async function uploadEvidence(path, blob) {
  const headers = { apikey: K, 'Content-Type': blob.type };
  if (jwt) headers.Authorization = 'Bearer ' + jwt;
  const res = await fetch(`${U}/storage/v1/object/payment-evidence/${path}`, { method: 'POST', headers, body: blob });
  if (!res.ok) throw new Error('No se pudo subir el comprobante (' + res.status + ')');
}
export async function signedUrl(path) {
  const r = await call('/storage/v1/object/sign/payment-evidence/' + path, { method: 'POST', body: JSON.stringify({ expiresIn: 300 }) });
  return U + '/storage/v1' + r.signedURL;
}
