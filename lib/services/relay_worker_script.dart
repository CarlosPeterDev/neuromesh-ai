/// The Cloudflare Worker (free plan) that lets you reach this phone from
/// anywhere. The phone connects OUT to it over a WebSocket; the Worker serves
/// a small chat page and the same API as the local server, forwarding every
/// request to the phone. Nothing is stored in the cloud.
const kRelayWorkerScript = r'''
const enc = new TextEncoder();
const b64 = {
  enc(buf) { let s = ''; const u = new Uint8Array(buf); for (let i = 0; i < u.length; i += 0x8000) s += String.fromCharCode.apply(null, u.subarray(i, i + 0x8000)); return btoa(s); },
  dec(str) { const s = atob(str); const u = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) u[i] = s.charCodeAt(i); return u; },
};

async function sig(env) {
  const d = await crypto.subtle.digest('SHA-256', enc.encode('nm|' + (env.PASSWORD || '') + '|' + env.RELAY_TOKEN));
  return Array.from(new Uint8Array(d)).map(x => x.toString(16).padStart(2, '0')).join('');
}
function cookie(req, name) {
  const m = (req.headers.get('cookie') || '').match(new RegExp('(?:^|; )' + name + '=([^;]*)'));
  return m ? m[1] : '';
}

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    const stub = env.RELAY.get(env.RELAY.idFromName('main'));
    if (url.pathname === '/_phone') return stub.fetch(req);

    const needPw = !!env.PASSWORD, needKey = !!env.API_KEY;
    const cookieOk = needPw && cookie(req, 'nm') === await sig(env);

    if (url.pathname === '/_login' && req.method === 'POST') {
      const form = await req.formData();
      if (needPw && form.get('password') === env.PASSWORD) {
        return new Response(null, { status: 303, headers: { Location: '/', 'Set-Cookie': 'nm=' + await sig(env) + '; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=2592000' } });
      }
      return new Response(loginPage('Wrong password'), { status: 401, headers: { 'content-type': 'text/html; charset=utf-8' } });
    }

    const isApi = url.pathname.startsWith('/v1/');
    const bearer = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
    let verified = false, allowed = false;
    if (cookieOk) { allowed = true; verified = true; }
    else if (isApi && needKey && bearer === env.API_KEY) { allowed = true; verified = true; }
    else if (isApi && env.KEY_MODE === 'local' && bearer) { allowed = true; }       // the phone checks its own key
    else if (!needPw && !(isApi && needKey)) { allowed = env.KEY_MODE !== 'local' || !isApi; verified = allowed; }
    if (!allowed) {
      if (!isApi && needPw) return new Response(loginPage(''), { status: 401, headers: { 'content-type': 'text/html; charset=utf-8' } });
      return new Response(JSON.stringify({ error: 'Unauthorized' }), { status: 401, headers: { 'content-type': 'application/json' } });
    }
    if (!isApi && url.pathname === '/') return new Response(chatPage(), { headers: { 'content-type': 'text/html; charset=utf-8' } });
    if (!isApi && url.pathname !== '/health') return new Response('Not found', { status: 404 });
    const fwd = new Request(req, { headers: new Headers(req.headers) });
    fwd.headers.set('x-relay-verified', verified ? '1' : '0');
    return stub.fetch(fwd);
  },
};

export class Relay {
  constructor(state, env) {
    this.state = state; this.env = env; this.pending = new Map();
    state.setWebSocketAutoResponse(new WebSocketRequestResponsePair('ping', 'pong'));
  }
  async fetch(req) {
    const url = new URL(req.url);
    if (url.pathname === '/_phone') {
      if (req.headers.get('Upgrade') !== 'websocket') return new Response('expected websocket', { status: 426 });
      if (url.searchParams.get('token') !== this.env.RELAY_TOKEN) return new Response('forbidden', { status: 403 });
      for (const old of this.state.getWebSockets('phone')) { try { old.close(1000, 'replaced'); } catch (e) {} }
      const pair = new WebSocketPair();
      this.state.acceptWebSocket(pair[1], ['phone']);
      return new Response(null, { status: 101, webSocket: pair[0] });
    }
    if (url.pathname === '/health') {
      return new Response(JSON.stringify({ status: 'ok', phone: this.state.getWebSockets('phone').length > 0 }), { headers: { 'content-type': 'application/json' } });
    }
    const phone = this.state.getWebSockets('phone')[0];
    if (!phone) return new Response(JSON.stringify({ error: 'The phone is offline. Open the app and turn the relay on.' }), { status: 503, headers: { 'content-type': 'application/json' } });

    const id = crypto.randomUUID();
    const headers = {};
    for (const [k, v] of req.headers) { if (!['host', 'cookie', 'cf-connecting-ip', 'x-forwarded-for', 'x-real-ip'].includes(k) && !k.startsWith('cf-')) headers[k] = v; }
    if (headers['x-relay-verified'] !== '1') delete headers['x-relay-verified'];
    const ts = new TransformStream();
    const writer = ts.writable.getWriter();
    const head = new Promise((resolve, reject) => { this.pending.set(id, { resolve, reject, writer }); });
    phone.send(JSON.stringify({ t: 'req', id, method: req.method, path: url.pathname + url.search, headers }));
    if (req.body) {
      const buf = new Uint8Array(await req.arrayBuffer());
      for (let i = 0; i < buf.length; i += 196608) phone.send(JSON.stringify({ t: 'body', id, b: b64.enc(buf.subarray(i, i + 196608)) }));
    }
    phone.send(JSON.stringify({ t: 'go', id }));
    const timer = setTimeout(() => { const p = this.pending.get(id); if (p) { p.reject(new Error('timeout')); this.pending.delete(id); } }, 600000);
    try {
      const r = await head;
      return new Response(ts.readable, { status: r.status, headers: r.headers });
    } catch (e) {
      return new Response(JSON.stringify({ error: String(e.message || e) }), { status: 504, headers: { 'content-type': 'application/json' } });
    } finally { clearTimeout(timer); }
  }
  async webSocketMessage(ws, message) {
    let m; try { m = JSON.parse(message); } catch (e) { return; }
    const p = this.pending.get(m.id); if (!p) return;
    if (m.t === 'head') { p.resolve({ status: m.status, headers: m.headers }); }
    else if (m.t === 'chunk') { await p.writer.write(b64.dec(m.b)); }
    else if (m.t === 'end') { await p.writer.close(); this.pending.delete(m.id); }
    else if (m.t === 'err') { p.reject(new Error(m.msg)); try { await p.writer.abort(); } catch (e) {} this.pending.delete(m.id); }
  }
  async webSocketClose(ws) { this.failAll('The phone disconnected.'); }
  async webSocketError(ws) { this.failAll('The phone connection failed.'); }
  failAll(msg) { for (const [id, p] of this.pending) { try { p.reject(new Error(msg)); p.writer.abort(); } catch (e) {} } this.pending.clear(); }
}

function loginPage(err) {
  return `<!doctype html><meta name=viewport content="width=device-width,initial-scale=1"><title>NeuroMesh</title>
<style>body{font:16px system-ui;background:#0f1115;color:#eee;display:grid;place-items:center;height:100vh;margin:0}form{display:grid;gap:12px;width:min(320px,90vw)}input,button{padding:12px;border-radius:10px;border:1px solid #333;background:#1b1e25;color:#eee;font-size:16px}button{background:#4f7cff;border:0}</style>
<form method=post action=/_login><h3>NeuroMesh AI</h3><input type=password name=password placeholder=Password autofocus><button>Open</button><small style=color:#f88>${err}</small></form>`;
}

function chatPage() {
  return `<!doctype html><html><head><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><title>NeuroMesh AI</title>
<style>
:root{color-scheme:dark light}body{margin:0;font:16px system-ui;background:#0f1115;color:#e8e8ea;display:flex;flex-direction:column;height:100dvh}
header{padding:12px 16px;border-bottom:1px solid #262a33;display:flex;gap:12px;align-items:center}header b{flex:1}header a{color:#8aa8ff;text-decoration:none;font-size:14px}
#log{flex:1;overflow:auto;padding:16px;display:flex;flex-direction:column;gap:10px}
.m{max-width:85%;padding:10px 14px;border-radius:16px;white-space:pre-wrap;word-wrap:break-word;line-height:1.45}
.u{align-self:flex-end;background:#2b4fd8}.a{align-self:flex-start;background:#1b1e25}
form{display:flex;gap:8px;padding:12px;border-top:1px solid #262a33}textarea{flex:1;resize:none;padding:12px;border-radius:12px;border:1px solid #333;background:#1b1e25;color:inherit;font:inherit;max-height:30vh}
button{padding:0 18px;border-radius:12px;border:0;background:#4f7cff;color:#fff;font-size:16px}
img{max-width:100%;border-radius:10px}
</style></head><body>
<header><b>NeuroMesh AI</b><a href="#" id="files">Files</a></header>
<div id=log></div>
<form id=f><textarea id=t rows=1 placeholder="Message your phone…"></textarea><button>Send</button></form>
<script>
const log=document.getElementById('log'),t=document.getElementById('t');let hist=[];
function add(c,x){const d=document.createElement('div');d.className='m '+c;d.textContent=x;log.appendChild(d);log.scrollTop=log.scrollHeight;return d}
function render(d,text){d.innerHTML='';const re=/!\\[[^\\]]*\\]\\(nmfile:([^)]+)\\)/g;let last=0,m;
 while((m=re.exec(text))){d.append(text.slice(last,m.index));const i=document.createElement('img');i.src='/v1/files/'+encodeURIComponent(m[1]);d.append(i);last=re.lastIndex}
 d.append(text.slice(last).replace(/\\[(.*?)\\]\\(nmfile:([^)]+)\\)/g,'$1'))}
document.getElementById('files').onclick=async e=>{e.preventDefault();const r=await fetch('/v1/files');const j=await r.json();
 const d=add('a','');d.innerHTML=(j.data||[]).map(f=>'<a style=color:#8aa8ff href="/v1/files/'+encodeURIComponent(f.name)+'">'+f.name+'</a>').join('<br>')||'No files yet.'};
document.getElementById('f').onsubmit=async e=>{e.preventDefault();const q=t.value.trim();if(!q)return;t.value='';add('u',q);hist.push({role:'user',content:q});
 const out=add('a','…');let acc='';
 try{const r=await fetch('/v1/chat/completions',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({model:'local',stream:true,messages:hist})});
  if(!r.ok){out.textContent='Error '+r.status+': '+await r.text();return}
  const rd=r.body.getReader(),dec=new TextDecoder();let buf='';
  for(;;){const {done,value}=await rd.read();if(done)break;buf+=dec.decode(value,{stream:true});const lines=buf.split('\\n');buf=lines.pop();
   for(const l of lines){if(!l.startsWith('data:'))continue;const p=l.slice(5).trim();if(p==='[DONE]')continue;try{const j=JSON.parse(p);acc+=(j.choices?.[0]?.delta?.content)||''; render(out,acc)}catch(_){}}
   log.scrollTop=log.scrollHeight}
  hist.push({role:'assistant',content:acc})}catch(err){out.textContent='Failed: '+err}};
t.addEventListener('keydown',e=>{if(e.key==='Enter'&&!e.shiftKey&&innerWidth>700){e.preventDefault();document.getElementById('f').requestSubmit()}});
</script></body></html>`;
}
''';
