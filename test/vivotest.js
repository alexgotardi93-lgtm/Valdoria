/* Duelo ao Vivo — dois navegadores contra UM servidor de mentira.
 *
 * O servidor falso mora aqui no Node e as duas paginas falam com ele por
 * exposeFunction, entao os dois clientes veem exatamente a mesma linha de
 * jogadas — que e a coisa que precisa ser testada. As regras copiadas do
 * banco (live_turno, live_auto, live_livre, live_avanca) estao reescritas
 * abaixo em JavaScript; se a migracao mudar, este arquivo tem que mudar
 * junto, e e de proposito: divergir aqui e o jeito de descobrir cedo.
 *
 * Nao encosta no Supabase de verdade.
 */
const { chromium } = require('playwright');
const DIR = require('path').join(__dirname, '..');
const ok = [], bad = [];
function t(nome, cond, extra) { (cond ? ok : bad).push(nome + (cond ? '' : ' -> ' + JSON.stringify(extra))); }
const wait = ms => new Promise(r => setTimeout(r, ms));

/* ===================== servidor de mentira ============================ */
const DECK_A = ['gladiadora-ember', 'berserker-cinzas', 'salamandra-de-guerra', 'piromante-vingativa',
                'ignarok-o-incandescente', 'fenix-de-chamalar', 'sanguessuga-abissal', 'corsaria-das-brumas'];
const DECK_B = ['alcateia-unida', 'guardiao-do-arco-iris', 'urso-espirito', 'ent-anciao',
                'aguia-trovejante', 'condutor-temerario', 'cavaleira-do-trovao', 'xama-das-tempestades'];

/* copia exata de live_turno(): devolve o SLOT (1 ou 2) que joga agora */
function turno(starter, rodada, fase) {
  const atk = rodada <= 3
    ? (rodada % 2 === 0 ? starter : 3 - starter)
    : ((rodada - 3) % 2 === 1 ? 3 - starter : starter);
  return fase === 'atk' ? atk : 3 - atk;
}
/* copia de live_auto(): a menor carta ainda na mao (nas 4..7, a da rodada) */
function auto(js, rodada, slot) {
  if (rodada >= 4) return rodada;
  for (let i = 0; i <= 3; i++) if (!js.some(j => j.s === slot && j.c === i)) return i;
  return null;
}
/* copia de live_livre() */
function livre(js, rodada, slot, carta) {
  if (carta == null || carta < 0 || carta > 7) return false;
  if (rodada >= 4) return carta === rodada;
  if (carta > 3) return false;
  return !js.some(j => j.s === slot && j.c === carta);
}

const SRV = {
  fila: [],           /* [{user, pts}] */
  duelos: [],
  prox: 1,
  prazoMs: 22000,     /* igual ao banco */
  bloqueio: {},       /* user -> erro que match_find deve devolver */
  log: [],
  perfis: {
    A: { user: 'A', nome: 'GladiadorA', elem: 'fogo', pts: 500, deck: DECK_A },
    B: { user: 'B', nome: 'GladiadorB', elem: 'nat', pts: 540, deck: DECK_B }
  },

  minha(user) {
    for (let i = this.duelos.length - 1; i >= 0; i--) {
      const v = this.duelos[i];
      if (v.p1 === user || v.p2 === user) {
        if (v.estado === 'ativo' || (v.fim_em && Date.now() - v.fim_em < 90000)) return v;
      }
    }
    return null;
  },
  view(v, slot) {
    const um = slot === 1;
    return {
      ok: true, estado: v.estado === 'ativo' ? 'duelo' : v.estado, id: v.id, eu: slot,
      nome: um ? v.nome2 : v.nome1, elem: um ? v.elem2 : v.elem1,
      pts: um ? v.pts2 : v.pts1, liga: 'Prata',
      meus_pts: um ? v.pts1 : v.pts2, minha_liga: 'Prata',
      meu_deck: um ? v.deck1 : v.deck2, deck_dele: um ? v.deck2 : v.deck1,
      starter: v.starter, rodada: v.rodada, fase: v.fase,
      resta: v.prazo == null ? null : Math.max(0, Math.ceil((v.prazo - Date.now()) / 1000)),
      jogadas: v.jogadas.map(j => Object.assign({}, j)),
      motivo: v.motivo, vencedor: v.vencedor,
      venci: v.vencedor == null ? null : v.vencedor === slot,
      delta: um ? v.delta1 : v.delta2, ouro: um ? v.ouro1 : v.ouro2
    };
  },
  paga(v, venc, motivo) {
    if (v.estado !== 'ativo') return;
    v.estado = motivo === 'wo' ? 'wo' : 'fim';
    v.motivo = motivo; v.vencedor = venc; v.prazo = null; v.fim_em = Date.now();
    if (venc === 1) { v.delta1 = 30; v.ouro1 = 60; v.delta2 = -12; v.ouro2 = 15; }
    else if (venc === 2) { v.delta2 = 30; v.ouro2 = 60; v.delta1 = -12; v.ouro1 = 15; }
    else { v.delta1 = 0; v.delta2 = 0; v.ouro1 = 20; v.ouro2 = 20; }
  },
  disputa(v) {
    v.estado = 'disputa'; v.motivo = 'disputa'; v.vencedor = null;
    v.prazo = null; v.fim_em = Date.now();
    v.delta1 = 0; v.delta2 = 0; v.ouro1 = 0; v.ouro2 = 0;
  },
  avanca(v) {
    if (v.estado === 'ativo' && v.rep1 && v.rep2) {
      if (v.rep1[0] === v.rep2[0] && v.rep1[1] === v.rep2[1]) {
        this.paga(v, v.rep1[0] > v.rep1[1] ? 1 : v.rep1[0] < v.rep1[1] ? 2 : 0, 'placar');
      } else this.disputa(v);
      return v;
    }
    let n = 0;
    while (v.estado === 'ativo' && v.prazo != null && Date.now() > v.prazo && n < 24) {
      n++;
      const slot = turno(v.starter, v.rodada, v.fase);
      const c = auto(v.jogadas, v.rodada, slot);
      if (c == null) { v.prazo = null; break; }
      if (slot === 1 && !v.rep1) v.faltas1++;
      if (slot === 2 && !v.rep2) v.faltas2++;
      v.jogadas.push({ r: v.rodada, f: v.fase, s: slot, c: c, auto: true });
      if (v.fase === 'atk') v.fase = 'def'; else { v.fase = 'atk'; v.rodada++; }
      v.prazo = Date.now() + this.prazoMs;
      if (v.rodada > 7) v.prazo = null;
      if (v.faltas1 >= 2 || v.faltas2 >= 2) { v.prazo = null; this.paga(v, v.faltas1 >= 2 ? 2 : 1, 'wo'); return v; }
    }
    return v;
  },

  rpc(user, nome, args) {
    this.log.push([user, nome, args || null]);
    args = args || {};
    if (nome === 'match_find') {
      if (this.bloqueio[user]) return { error: this.bloqueio[user] };
      let v = this.minha(user);
      if (v && v.estado === 'ativo') return this.view(this.avanca(v), v.p1 === user ? 1 : 2);
      const me = this.perfis[user];
      const iOp = this.fila.findIndex(q => q.user !== user);
      if (iOp < 0) {
        if (!this.fila.some(q => q.user === user)) this.fila.push({ user, entrou: Date.now() });
        return { ok: true, estado: 'fila', meus_pts: me.pts, minha_liga: 'Prata' };
      }
      const op = this.perfis[this.fila[iOp].user];
      this.fila.splice(iOp, 1);
      this.fila = this.fila.filter(q => q.user !== user);
      v = {
        id: this.prox++, p1: op.user, p2: me.user, estado: 'ativo',
        nome1: op.nome, nome2: me.nome, elem1: op.elem, elem2: me.elem,
        pts1: op.pts, pts2: me.pts, deck1: op.deck.slice(), deck2: me.deck.slice(),
        starter: 1, rodada: 0, fase: 'atk', jogadas: [], faltas1: 0, faltas2: 0,
        rep1: null, rep2: null, prazo: Date.now() + 30000,
        motivo: null, vencedor: null, delta1: 0, delta2: 0, ouro1: 0, ouro2: 0, fim_em: null
      };
      this.duelos.push(v);
      return this.view(v, 2);
    }
    if (nome === 'match_state') {
      const q = this.fila.find(x => x.user === user);
      if (q) return { ok: true, estado: 'fila', espera: Math.floor((Date.now() - q.entrou) / 1000) };
      const v = this.minha(user);
      if (!v) return { ok: true, estado: 'nada' };
      if (v.estado === 'ativo') this.avanca(v);
      return this.view(v, v.p1 === user ? 1 : 2);
    }
    if (nome === 'match_play') {
      const v = this.minha(user);
      if (!v) return { error: 'sem_partida' };
      const slot = v.p1 === user ? 1 : 2;
      if (v.estado === 'ativo') this.avanca(v);
      if (v.estado !== 'ativo') return this.view(v, slot);
      if (v.rodada !== args.p_rodada || v.fase !== args.p_fase)
        return { error: 'fora_de_hora', estado_atual: this.view(v, slot) };
      if (turno(v.starter, v.rodada, v.fase) !== slot)
        return { error: 'nao_e_sua_vez', estado_atual: this.view(v, slot) };
      if (!livre(v.jogadas, v.rodada, slot, args.p_carta)) return { error: 'carta_invalida' };
      v.jogadas.push({ r: v.rodada, f: v.fase, s: slot, c: args.p_carta });
      const eraAtk = v.fase === 'atk';
      v.fase = eraAtk ? 'def' : 'atk';
      if (!eraAtk) v.rodada++;
      if (slot === 1) v.faltas1 = 0; else v.faltas2 = 0;
      v.prazo = (!eraAtk && v.rodada - 1 >= 7) ? null : Date.now() + this.prazoMs;
      return this.view(v, slot);
    }
    if (nome === 'match_report') {
      const v = this.minha(user);
      if (!v) return { error: 'sem_partida' };
      const slot = v.p1 === user ? 1 : 2;
      if (v.estado !== 'ativo') return this.view(v, slot);
      if (v.jogadas.length < 4) return { error: 'cedo_demais' };
      const par = slot === 1 ? [args.p_minha, args.p_dele] : [args.p_dele, args.p_minha];
      if (slot === 1) v.rep1 = par; else v.rep2 = par;
      this.avanca(v);
      return this.view(v, slot);
    }
    if (nome === 'match_leave') {
      this.fila = this.fila.filter(q => q.user !== user);
      const v = this.minha(user);
      if (v && v.estado === 'ativo') {
        const slot = v.p1 === user ? 1 : 2;
        this.paga(v, 3 - slot, 'wo');
        return this.view(v, slot);
      }
      return { ok: true, estado: 'nada' };
    }
    if (nome === 'state_get') return { perfil: { username: this.perfis[user].nome, ouro: 999, gemas: 5, essencia: 3, nivel: 4, rank_pts: this.perfis[user].pts, liga: 'Prata', vitorias: 4, derrotas: 2 } };
    if (nome === 'missions_get') return { ok: true, renova_em: 3600, missoes: [], bonus: { pago: false, pronto: false } };
    if (nome === 'arena_find') return { ok: true, bot: true, nome: 'Corvo', elem: 'raio', pts: 90, liga: 'Bronze', cartas: null, meus_pts: this.perfis[user].pts, minha_liga: 'Prata' };
    return { error: 'nada' };
  }
};

/* ===================== paginas ======================================== */
async function abrePagina(b, who, errs) {
  const p = await b.newPage({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
  p.on('console', m => { if (m.type() === 'error' && !/googleapis|fonts\.g|ERR_|Failed to load resource/.test(m.text())) errs.push(who + ' CON:' + m.text()); });
  p.on('pageerror', e => errs.push(who + ' PAGE:' + String(e)));
  await p.exposeFunction('srvRpc', (nome, args) => SRV.rpc(who, nome, args));
  await p.goto('file://' + DIR + '/index.html');
  await p.waitForTimeout(800);
  await p.evaluate(nome => {
    window.EU = nome;
    window.wait = ms => new Promise(r => setTimeout(r, ms));
    sb = {
      rpc: (n, a) => window.srvRpc(n, a || null).then(d => ({ data: d })),
      from: () => ({ select: () => ({ order: () => ({ limit: () => Promise.resolve({ data: [] }) }) }) })
    };
    online = true;
    ownedSet = new Set(DECKI.map(c => slug(c.nm)));
    profile = { username: nome, ouro: 300, gemas: 4, essencia: 2, nivel: 3, rank_pts: 500, liga: 'Prata', vitorias: 1, derrotas: 0 };
    applyProfile();
  }, SRV.perfis[who].nome);
  return p;
}
const estado = p => p.evaluate(() => ({
  tela: document.querySelector('.screen.active').id,
  temDuelo: !!(typeof duel !== 'undefined' && duel),
  live: !!(typeof duel !== 'undefined' && duel && duel.live),
  waiting: (typeof duel !== 'undefined' && duel) ? duel.waiting : null,
  aberta: !!(typeof duel !== 'undefined' && duel && duel.live && duel.live.aberta),
  enviando: !!(typeof duel !== 'undefined' && duel && duel.live && duel.live.enviando),
  acabou: !!(typeof duel !== 'undefined' && duel && duel.live && duel.live.acabou),
  round: (typeof duel !== 'undefined' && duel) ? duel.round : null,
  fase: (typeof duel !== 'undefined' && duel) ? duel.phase : null,
  you: (typeof duel !== 'undefined' && duel) ? duel.you : null,
  foe: (typeof duel !== 'undefined' && duel) ? duel.foe : null,
  mao: (typeof duel !== 'undefined' && duel) ? duel.handI.slice() : null,
  maoDele: (typeof duel !== 'undefined' && duel) ? duel.foeHandI.slice() : null
}));
/* espera os dois cairem no duelo E o sorteio de quem comeca terminar
   (1250+1450ms de animacao) — sem isso o teste mexe no duelo antes da hora */
async function esperaDuelo(pgs, limiteMs) {
  const t0 = Date.now();
  while (Date.now() - t0 < (limiteMs || 15000)) {
    const ss = [];
    for (const p of pgs) ss.push(await estado(p));
    if (ss.every(s => s.live && s.waiting)) return ss;
    await wait(150);
  }
  return null;
}
/* deixa os dois clientes jogarem sozinhos ate acabar (ou estourar o tempo) */
async function jogaAte(pgs, fim, limiteMs) {
  const t0 = Date.now();
  while (Date.now() - t0 < limiteMs) {
    for (const p of pgs) {
      const s = await estado(p);
      if (s.live && s.waiting === 'you' && s.aberta && !s.enviando) await p.evaluate(() => playCard(0));
    }
    const ss = [];
    for (const p of pgs) ss.push(await estado(p));
    if (fim(ss)) return ss;
    await wait(160);
  }
  return null;
}

(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const errs = [];
  const pa = await abrePagina(b, 'A', errs);
  const pb = await abrePagina(b, 'B', errs);

  /* ---- 1. fila e pareamento ------------------------------------------ */
  await pa.evaluate(() => go('arena')); await wait(350);
  await pa.evaluate(() => vivoFind()); await wait(300);
  const f1 = await pa.evaluate(() => ({ fila: vivo.fila, box: document.getElementById('vivoBox').textContent.replace(/\s+/g, ' ').trim() }));
  t('fila: A entra na fila', f1.fila === true, f1);
  t('fila: painel mostra procura', /Procurando adversário/.test(f1.box), f1.box);
  t('fila: painel tem botao de sair', /Sair da fila/.test(f1.box), f1.box);

  await pb.evaluate(() => go('arena')); await wait(350);
  await pb.evaluate(() => vivoFind());
  await wait(2600);   /* A precisa de um poll pra saber que pareou */
  const s1a = await estado(pa), s1b = await estado(pb);
  t('pareamento: B cai direto no duelo', s1b.tela === 's-duel' && s1b.live, s1b);
  t('pareamento: A e puxado pro duelo pelo poll', s1a.tela === 's-duel' && s1a.live, s1a);
  t('pareamento: fila esvaziou no servidor', SRV.fila.length === 0, SRV.fila);

  /* ---- 2. os dois veem o mesmo duelo --------------------------------- */
  const d2 = await Promise.all([pa, pb].map(p => p.evaluate(() => ({
    eu: duel.live.eu, id: duel.live.id, starter: duel.starter,
    minha: duel.hand.concat(duel.myRest).map(c => slug(c.nm)),
    dele: duel.foeHand.concat(duel.foeRest).map(c => slug(c.nm)),
    foeName: document.getElementById('foeName').textContent,
    maoAberta: document.getElementById('foeHandBox').style.display !== 'none',
    lbl: document.getElementById('foeHandLbl').textContent
  }))));
  t('duelo: slots opostos', d2[0].eu !== d2[1].eu && d2[0].id === d2[1].id, d2.map(x => x.eu));
  t('duelo: o meu deck de um e o deck-dele do outro', JSON.stringify(d2[0].minha) === JSON.stringify(d2[1].dele), d2[0].minha);
  t('duelo: e vice-versa', JSON.stringify(d2[1].minha) === JSON.stringify(d2[0].dele), d2[1].minha);
  t('duelo: quem comeca e o mesmo pros dois', d2[0].starter !== d2[1].starter, d2.map(x => x.starter));
  t('duelo: nome do adversario no HUD', d2[0].foeName === 'GladiadorB' && d2[1].foeName === 'GladiadorA', d2.map(x => x.foeName));
  t('duelo: mao do adversario aberta', d2[0].maoAberta && /MÃO DO ADVERSÁRIO/.test(d2[0].lbl), d2[0]);

  /* ---- 3. a vez bate com a regra do servidor -------------------------- */
  t('sorteio: os dois saem da animacao e a rodada abre', !!(await esperaDuelo([pa, pb])), null);
  const v3 = await Promise.all([pa, pb].map(p => p.evaluate(() => ({ eu: duel.live.eu, waiting: duel.waiting, round: duel.round, fase: duel.phase }))));
  const slotDaVez = turno(1, 0, 'atk');
  t('vez: so um dos dois pode jogar', (v3[0].waiting === 'you') !== (v3[1].waiting === 'you'), v3);
  t('vez: e o slot que o live_turno manda', v3.find(x => x.waiting === 'you').eu === slotDaVez, { v3, slotDaVez });

  /* ---- 4. duelo inteiro, carta por carta ------------------------------ */
  SRV.log.length = 0;
  const fim = await jogaAte([pa, pb], ss => ss.every(s => s.acabou), 90000);
  t('duelo: os dois chegaram ao fim', !!fim, fim);
  const jog = SRV.duelos[0].jogadas;
  t('duelo: 8 jogadas registradas', jog.length === 8, jog.length);
  t('duelo: nenhuma jogada automatica', !jog.some(j => j.auto), jog);
  t('duelo: cartas por indice absoluto 0..3', jog.every(j => j.c >= 0 && j.c <= 3), jog);
  t('duelo: cada lado gastou as 4 cartas', [1, 2].every(s => new Set(jog.filter(j => j.s === s).map(j => j.c)).size === 4), jog);
  t('duelo: ordem atk/def alternada', jog.every((j, i) => j.f === (i % 2 === 0 ? 'atk' : 'def')), jog.map(j => j.f));
  t('duelo: cada jogada veio de quem era a vez', jog.every(j => j.s === turno(1, j.r, j.f)), jog);
  const playCalls = SRV.log.filter(l => l[1] === 'match_play');
  t('duelo: 8 match_play, 4 de cada lado', playCalls.length === 8 && playCalls.filter(l => l[0] === 'A').length === 4, playCalls.length);

  /* ---- 5. placares cruzados e pagamento ------------------------------- */
  if (fim) {
    t('placar: os dois lados chegaram na mesma vida', fim[0].you === fim[1].foe && fim[0].foe === fim[1].you, fim.map(s => [s.you, s.foe]));
  }
  await wait(1800);
  const r5 = await Promise.all([pa, pb].map(p => p.evaluate(() => ({
    ov: document.getElementById('resultOv').textContent.replace(/\s+/g, ' ').trim(),
    pts: document.getElementById('ovPts').textContent,
    pago: duel && duel.live ? duel.live.pago : null,
    ouro: document.getElementById('ouro').textContent
  }))));
  const dFim = SRV.duelos[0];
  t('placar: servidor fechou a partida', dFim.estado === 'fim', dFim.estado);
  t('placar: sem disputa', dFim.motivo === 'placar', dFim.motivo);
  t('placar: um venceu e o outro perdeu', [1, 2, 0].includes(dFim.vencedor), dFim.vencedor);
  t('placar: os dois viram o resultado', r5.every(x => x.pago === true), r5.map(x => x.pago));
  t('placar: overlay traz pontos e ouro', r5.every(x => /pts · \+\d+ Ouro/.test(x.pts)), r5.map(x => x.pts));
  const venc = r5.find(x => /VITÓRIA/.test(x.ov)), perd = r5.find(x => /DERROTA/.test(x.ov));
  t('placar: um VITORIA e um DERROTA', (!!venc && !!perd) || r5.every(x => /EMPATE/.test(x.ov)), r5.map(x => x.ov.slice(0, 40)));
  t('placar: overlay oferece outro duelo', r5.every(x => /Outro duelo ao vivo/.test(x.ov)), r5[0].ov);
  t('placar: ouro do topo veio do state_get', r5.every(x => x.ouro === '999'), r5.map(x => x.ouro));
  t('placar: um match_report de cada lado', SRV.log.filter(l => l[1] === 'match_report').length === 2, SRV.log.filter(l => l[1] === 'match_report'));

  /* ---- 6. disputa: placares diferentes ------------------------------- */
  SRV.duelos.length = 0; SRV.fila.length = 0; SRV.log.length = 0;
  await pa.evaluate(() => go('arena')); await pb.evaluate(() => go('arena')); await wait(400);
  await pa.evaluate(() => vivoFind()); await wait(250);
  await pb.evaluate(() => vivoFind());
  t('disputa: duelo aberto', !!(await esperaDuelo([pa, pb])), null);
  const d6 = SRV.duelos[0];
  /* enche 4 jogadas na marra pro match_report passar do "cedo_demais".
     rodada 9 nao existe: assim o cliente recebe as jogadas no poll e nao
     acha nenhuma pra aplicar, que e o que queremos aqui */
  d6.jogadas = [0, 1, 2, 3].map(i => ({ r: 9, f: 'atk', s: 1, c: i }));
  await Promise.all([
    pa.evaluate(() => { duel.you = 11; duel.foe = 4; endDuel(); }),
    pb.evaluate(() => { duel.you = 9; duel.foe = 6; endDuel(); })
  ]);
  await wait(3000);
  const r6 = await Promise.all([pa, pb].map(p => p.evaluate(() => ({
    ov: document.getElementById('resultOv').textContent.replace(/\s+/g, ' ').trim(),
    pts: document.getElementById('ovPts').textContent
  }))));
  t('disputa: servidor marcou disputa', d6.estado === 'disputa', d6.estado);
  t('disputa: os dois veem SEM PLACAR', r6.every(x => /SEM PLACAR/.test(x.ov)), r6.map(x => x.ov.slice(0, 40)));
  t('disputa: explica que ninguem pontua', r6.every(x => /ninguém pontua/.test(x.ov)), r6[0].ov);
  t('disputa: nao mostra pontos', r6.every(x => x.pts === ''), r6.map(x => x.pts));

  /* ---- 7. desistir no meio = W.O. ------------------------------------ */
  SRV.duelos.length = 0; SRV.fila.length = 0; SRV.log.length = 0;
  await pa.evaluate(() => go('arena')); await pb.evaluate(() => go('arena')); await wait(400);
  await pa.evaluate(() => vivoFind()); await wait(250);
  await pb.evaluate(() => vivoFind());
  t('wo: duelo aberto', !!(await esperaDuelo([pa, pb])), null);
  const conf = await pa.evaluate(() => { sairDuelo(); return document.getElementById('resultOv').textContent.replace(/\s+/g, ' ').trim(); });
  t('sair: pede confirmacao na propria tela', /Desistir\?/.test(conf) && /conta como derrota/.test(conf), conf);
  await pa.evaluate(() => voltarDuelo());
  const volta = await pa.evaluate(() => ({ tela: document.querySelector('.screen.active').id, ov: document.getElementById('resultOv').classList.contains('show') }));
  t('sair: "continuar duelando" fecha o aviso', volta.tela === 's-duel' && volta.ov === false, volta);
  await pa.evaluate(() => { sairDuelo(); desistirDuelo(); });
  await wait(2600);
  const dWo = SRV.duelos[0];
  const r7 = await Promise.all([pa, pb].map(p => p.evaluate(() => ({
    tela: document.querySelector('.screen.active').id,
    ov: document.getElementById('resultOv').textContent.replace(/\s+/g, ' ').trim()
  }))));
  t('wo: servidor deu W.O.', dWo.estado === 'wo' && dWo.motivo === 'wo', { e: dWo.estado, m: dWo.motivo });
  t('wo: quem saiu voltou pra Arena', r7[0].tela === 's-arena', r7[0].tela);
  t('wo: quem ficou ganhou por abandono', /VITÓRIA/.test(r7[1].ov) && /abandonou/.test(r7[1].ov), r7[1].ov.slice(0, 60));

  /* ---- 8. carta invalida ---------------------------------------------- */
  SRV.duelos.length = 0; SRV.fila.length = 0; SRV.log.length = 0;
  await pa.evaluate(() => go('arena')); await pb.evaluate(() => go('arena')); await wait(400);
  await pa.evaluate(() => vivoFind()); await wait(250);
  await pb.evaluate(() => vivoFind());
  t('invalida: duelo aberto', !!(await esperaDuelo([pa, pb])), null);
  const quem = (await estado(pa)).waiting === 'you' ? pa : pb;
  const inval = await quem.evaluate(async () => {
    duel.handI[0] = 9;                       /* indice que o servidor recusa */
    playCard(0);
    await wait(700);
    const tt = document.getElementById('toast');
    return { toast: tt ? tt.textContent : '', aberta: duel.live.aberta, mao: duel.hand.length };
  });
  t('invalida: servidor recusa e o cliente avisa', /não vale nesta rodada/.test(inval.toast), inval.toast);
  t('invalida: a mao continua aberta', inval.aberta === true && inval.mao === 4, inval);

  /* ---- 9. retomada depois de um F5 ------------------------------------ */
  /* 5 jogadas: as rodadas 1 e 2 fechadas e o ataque da 3a ja na mesa.
     turno(1,2,'atk') = slot 1 = eu, entao quem falta defender e o outro. */
  const ret = await pa.evaluate(async ([dA, dB]) => {
    const lv = {
      id: 999, eu: 1, starter: 1, nome: 'GladiadorB', resta: 20,
      meu_deck: dA, deck_dele: dB,
      jogadas: [{ r: 0, f: 'atk', s: 1, c: 2 }, { r: 0, f: 'def', s: 2, c: 3 },
                { r: 1, f: 'atk', s: 2, c: 0 }, { r: 1, f: 'def', s: 1, c: 1 },
                { r: 2, f: 'atk', s: 1, c: 0 }]
    };
    liveParar(); duel = null;
    startLive(lv);
    await wait(500);
    return {
      round: duel.round, fase: duel.phase, sudden: duel.sudden,
      mao: duel.handI.slice(), maoDele: duel.foeHandI.slice(),
      atk: duel.atkCard ? duel.atkCard.side : null,
      waiting: duel.waiting, vidas: [duel.you, duel.foe],
      msg: document.getElementById('duelMsg').textContent.replace(/\s+/g, ' ').trim()
    };
  }, [DECK_A, DECK_B]);
  t('f5: voltou na rodada 3, fase de defesa', ret.round === 2 && ret.fase === 'def', ret);
  t('f5: sobrei com a carta que nao joguei', JSON.stringify(ret.mao) === '[3]', ret.mao);
  t('f5: a mao dele bate com o que ele jogou', JSON.stringify(ret.maoDele) === '[1,2]', ret.maoDele);
  t('f5: o ataque na mesa e o do slot certo', ret.atk === 'you', ret.atk);
  t('f5: vida ja descontada das 2 rodadas', ret.vidas[0] <= 20 && ret.vidas[1] <= 20 && ret.vidas[0] + ret.vidas[1] < 40, ret.vidas);
  t('f5: e a vez dele defender', ret.waiting === 'foe' && /defende/.test(ret.msg), { w: ret.waiting, m: ret.msg });

  /* ---- 10. morte subita: indice absoluto = numero da rodada ----------- */
  /* computeClash sai de cena: aqui so interessa o alinhamento dos indices,
     e um dano real nas 4 rodadas poderia zerar a vida antes da SD */
  const sd = await pa.evaluate(async ([dA, dB]) => {
    const orig = computeClash;
    computeClash = () => ({ dmgAtk: 0, dmgDef: 0, healA: 0, healD: 0 });
    const base = [];
    for (let r = 0; r < 4; r++) {
      const atk = r % 2 === 0 ? 1 : 2;
      base.push({ r: r, f: 'atk', s: atk, c: r });
      base.push({ r: r, f: 'def', s: 3 - atk, c: r });
    }
    base.push({ r: 4, f: 'atk', s: 2, c: 4 });   /* na 1a morte subita quem comecou defende */
    const lv = {
      id: 1000, eu: 1, starter: 1, nome: 'GladiadorB', resta: 20,
      meu_deck: dA, deck_dele: dB, jogadas: base
    };
    liveParar(); duel = null;
    startLive(lv);
    await wait(500);
    const out = { round: duel.round, fase: duel.phase, sudden: duel.sudden, sdN: duel.sdN,
      mao: duel.handI.slice(), maoDele: duel.foeHandI.slice(),
      resto: duel.myRestI.slice(), atacante: duel.attacker, waiting: duel.waiting,
      track: document.getElementById('roundTrack').textContent };
    computeClash = orig;
    return out;
  }, [DECK_A, DECK_B]);
  t('sd: entrou em morte subita', sd.sudden === true && sd.sdN === 1, sd);
  t('sd: a rodada da SD e a 5a', sd.round === 4 && sd.fase === 'def', sd);
  t('sd: minha carta da SD e o indice 4', JSON.stringify(sd.mao) === '[4]', sd.mao);
  t('sd: a dele saiu da mao pro ataque', JSON.stringify(sd.maoDele) === '[]', sd.maoDele);
  t('sd: reserva alinhada em 5,6,7', JSON.stringify(sd.resto) === '[5,6,7]', sd.resto);
  t('sd: quem comecou defende na primeira', sd.atacante === 'foe' && sd.waiting === 'you', sd);
  t('sd: trilha marca SD', /SD/.test(sd.track), sd.track);
  /* a regra do cliente e a do banco tem que dar o mesmo slot em todas as rodadas */
  const bate = await pa.evaluate(() => {
    const r = [];
    for (let st = 1; st <= 2; st++) for (let rr = 0; rr <= 7; rr++) {
      const starter = st === 1 ? 'you' : 'foe';
      const atacante = rr <= 3 ? (rr % 2 === 0 ? starter : other(starter))
                               : ((rr - 3) % 2 === 1 ? other(starter) : starter);
      r.push([st, rr, atacante === 'you' ? 1 : 2]);
    }
    return r;
  });
  t('turno: cliente e servidor concordam nas 16 rodadas',
    bate.every(([st, rr, slot]) => turno(st, rr, 'atk') === slot), bate.filter(([st, rr, slot]) => turno(st, rr, 'atk') !== slot));

  /* ---- 11. recusas da fila -------------------------------------------- */
  await pa.evaluate(() => { liveParar(); duel = null; });
  const recusas = {};
  for (const e of ['sem_deck', 'limite_diario', 'disputas', 'sem_perfil']) {
    SRV.bloqueio.A = e;
    await pa.evaluate(() => go('arena')); await wait(300);
    await pa.evaluate(() => vivoFind()); await wait(300);
    recusas[e] = await pa.evaluate(() => ({ box: document.getElementById('vivoBox').textContent.replace(/\s+/g, ' ').trim(), fila: vivo.fila }));
  }
  delete SRV.bloqueio.A;
  t('recusa: sem deck', /deck de 8 cartas/.test(recusas.sem_deck.box), recusas.sem_deck.box);
  t('recusa: teto diario', /100 partidas hoje/.test(recusas.limite_diario.box), recusas.limite_diario.box);
  t('recusa: tres disputas', /placares divergentes/.test(recusas.disputas.box), recusas.disputas.box);
  t('recusa: sem apelido', /apelido no Perfil/.test(recusas.sem_perfil.box), recusas.sem_perfil.box);
  t('recusa: nao deixa a fila ligada', Object.values(recusas).every(x => x.fila === false), recusas);

  /* ---- 12. sair da fila e painel de convidado ------------------------- */
  await pa.evaluate(() => { vivoOk(); go('arena'); }); await wait(300);
  await pa.evaluate(() => vivoFind()); await wait(300);
  await pa.evaluate(() => vivoSai()); await wait(300);
  const s12 = await pa.evaluate(() => ({ fila: vivo.fila, box: document.getElementById('vivoBox').textContent.replace(/\s+/g, ' ').trim() }));
  t('fila: sair volta pro botao', s12.fila === false && /Procurar duelo ao vivo/.test(s12.box), s12);
  t('fila: servidor tirou da fila', !SRV.fila.some(q => q.user === 'A'), SRV.fila);

  const g12 = await pa.evaluate(async () => { online = false; go('arena'); await wait(300); return document.getElementById('vivoBox').textContent.replace(/\s+/g, ' ').trim(); });
  t('convidado: painel pede conta', /entre contas reais/i.test(g12) && /Entrar na conta/.test(g12), g12);

  /* ---- fotos ----------------------------------------------------------- */
  await pa.evaluate(() => { online = true; go('arena'); vivoFind(); });
  await wait(600);
  await pa.screenshot({ path: DIR + '/v10-fila.png' });
  await pb.evaluate(() => go('arena')); await wait(300);
  await pb.evaluate(() => vivoFind()); await wait(3400);
  await pb.screenshot({ path: DIR + '/v10-duelo.png' });
  await pa.screenshot({ path: DIR + '/v10-duelo2.png' });

  console.log('PASSOU: ' + ok.length + '/' + (ok.length + bad.length));
  if (bad.length) console.log('FALHOU:\n - ' + bad.join('\n - '));
  console.log('ERROS DE PAGINA: ' + (errs.length ? errs.join(' | ') : 'NENHUM'));
  await b.close();
  process.exit(bad.length || errs.length ? 1 : 0);
})();
