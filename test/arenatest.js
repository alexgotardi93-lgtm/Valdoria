/* Testa a Arena, o Ranking e o Perfil do cliente com um Supabase de mentira.
   Nao toca no banco de verdade: so exercita os caminhos do JavaScript. */
const { chromium } = require('playwright');
const DIR = '/home/claude/valdoria-jogo';
const ok = [], bad = [];
function t(nome, cond, extra) { (cond ? ok : bad).push(nome + (cond ? '' : ' -> ' + JSON.stringify(extra))); }

(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
  const errs = [];
  p.on('console', m => { if (m.type() === 'error' && !/googleapis|fonts\.g|ERR_|Failed to load resource/.test(m.text())) errs.push('CON:' + m.text()); });
  p.on('pageerror', e => errs.push('PAGE:' + String(e)));
  await p.goto('file://' + DIR + '/index.html');
  await p.waitForTimeout(900);

  /* ---- instala o Supabase de mentira ---------------------------------- */
  await p.evaluate(() => {
    window.CALLS = [];
    const cartas = [0, 1, 10, 15, 26, 32, 39, 45].map(i => slug(DECKI[i].nm));
    window.FAKE = {
      arena_find: { ok: true, bot: false, nome: 'ArenaBeta <script>', elem: 'agua', pts: 340, liga: 'Prata', cartas, meus_pts: 120, minha_liga: 'Bronze' },
      arena_result: { ok: true, pts: 27, ouro: 512, ganho: 40, rank_pts: 147, liga: 'Bronze', vitorias: 3, derrotas: 1, foe: 'ArenaBeta' },
      ranking_top: {
        top: [{ pos: 1, nome: 'ArenaBeta', pts: 340, liga: 'Prata', vitorias: 5 },
              { pos: 2, nome: 'Eu', pts: 147, liga: 'Bronze', vitorias: 1 }],
        eu: { pos: 2, nome: 'Eu', pts: 147, liga: 'Bronze', vitorias: 1, derrotas: 1 }
      }
    };
    sb = {
      rpc: (nome, args) => { CALLS.push([nome, args || null]); return Promise.resolve({ data: FAKE[nome] || { error: 'nada' } }); },
      from: () => ({
        select: () => ({ order: () => ({ limit: () => Promise.resolve({ data: [
          { foe_nome: 'ArenaBeta', foe_elem: 'agua', venceu: true, pts: 27, criado_em: '2026-07-25T00:00:00Z' },
          { foe_nome: 'Corvo <b>', foe_elem: 'fogo', venceu: false, pts: -15, criado_em: '2026-07-24T00:00:00Z' }] }) }) })
      })
    };
    online = true;
    ownedSet = new Set(DECKI.map(c => slug(c.nm)));
    profile = { username: 'Eu', ouro: 472, gemas: 12, essencia: 4, nivel: 3, rank_pts: 120, liga: 'Bronze', vitorias: 2, derrotas: 1 };
    applyProfile();
  });

  await p.evaluate(() => {
    window.wait = ms => new Promise(r => setTimeout(r, ms));
    /* o sorteio de quem comeca reescreve o resultOv em 1250ms e 2700ms */
    window.duelarArena = async () => { arenaDuel(); await wait(2900); };
  });

  /* ---- 1. tela da Arena, logado ---------------------------------------- */
  await p.evaluate(() => go('arena'));
  await p.waitForTimeout(400);
  const a1 = await p.evaluate(() => ({
    tela: document.querySelector('.screen.active').id,
    box: document.getElementById('arBox').textContent.replace(/\s+/g, ' ').trim(),
    html: document.getElementById('arBox').innerHTML,
    liga: document.getElementById('arMinhaLiga').textContent,
    pts: document.getElementById('arMeusPts').textContent,
    nav: !document.getElementById('bottomnav').classList.contains('hidden'),
    chamadas: CALLS.map(c => c[0])
  }));
  t('arena: tela ativa', a1.tela === 's-arena', a1.tela);
  t('arena: chamou arena_find', a1.chamadas.includes('arena_find'), a1.chamadas);
  t('arena: mostra nome do oponente', /ArenaBeta/.test(a1.box), a1.box);
  t('arena: escapa HTML do nome', !/<script>/.test(a1.html) && /&lt;script&gt;/.test(a1.html), a1.html.slice(0, 300));
  t('arena: mostra liga e pontos do oponente', /Prata/.test(a1.box) && /340 pts/.test(a1.box), a1.box);
  t('arena: sem chip de guilda para jogador real', !/guilda/.test(a1.box), a1.box);
  t('arena: cabecalho com meus pontos do servidor', a1.pts === '120' && a1.liga === 'Bronze', a1);
  t('arena: barra de baixo visivel', a1.nav === true, a1.nav);

  /* ---- 2. duelo espelhado --------------------------------------------- */
  const a2 = await p.evaluate(async () => {
    await duelarArena();
    const nomes = duel.foeHand.concat(duel.foeRest).map(c => slug(c.nm)).sort();
    return {
      tela: document.querySelector('.screen.active').id,
      foeName: document.getElementById('foeName').textContent,
      temArena: !!duel.arena,
      deckIgual: JSON.stringify(nomes) === JSON.stringify([0, 1, 10, 15, 26, 32, 39, 45].map(i => slug(DECKI[i].nm)).sort()),
      qtd: duel.foeHand.length + duel.foeRest.length
    };
  });
  t('duelo: entrou na tela', a2.tela === 's-duel', a2.tela);
  t('duelo: nome do adversario no HUD', a2.foeName === 'ArenaBeta <script>', a2.foeName);
  t('duelo: duel.arena preenchido', a2.temArena === true);
  t('duelo: deck do adversario e o espelho salvo', a2.deckIgual && a2.qtd === 8, a2);

  /* ---- 3. fim do duelo paga pela Arena --------------------------------- */
  const a3 = await p.evaluate(async () => {
    CALLS.length = 0;
    duel.you = 14; duel.foe = 0; duel.round = 4;
    endDuel();
    await new Promise(r => setTimeout(r, 300));
    return {
      chamadas: CALLS,
      ov: document.getElementById('resultOv').textContent.replace(/\s+/g, ' ').trim(),
      pts: document.getElementById('ovPts').textContent,
      ouro: document.getElementById('ouro').textContent,
      perfil: { pts: profile.rank_pts, v: profile.vitorias, d: profile.derrotas },
      arenaLimpa: arena === null
    };
  });
  t('fim: chamou arena_result com vitoria', JSON.stringify(a3.chamadas) === JSON.stringify([['arena_result', { p_win: true }]]), a3.chamadas);
  t('fim: nao chamou duel_reward', !JSON.stringify(a3.chamadas).includes('duel_reward'), a3.chamadas);
  t('fim: overlay mostra pontos e ouro', a3.pts === '+27 pts · +40 Ouro', a3.pts);
  t('fim: overlay volta para a Arena', /Voltar à Arena/.test(a3.ov), a3.ov);
  t('fim: ouro do topo atualizado', a3.ouro === '512', a3.ouro);
  t('fim: perfil local atualizado', a3.perfil.pts === 147 && a3.perfil.v === 3 && a3.perfil.d === 1, a3.perfil);
  t('fim: pareamento zerado', a3.arenaLimpa === true);

  /* ---- 4. derrota e empate -------------------------------------------- */
  const a4 = await p.evaluate(async () => {
    go('arena'); await wait(300);
    await duelarArena(); CALLS.length = 0;
    duel.you = 3; duel.foe = 11; endDuel();
    await wait(250);
    const derrota = CALLS.slice();
    go('arena'); await wait(300);
    await duelarArena(); CALLS.length = 0;
    duel.you = 7; duel.foe = 7; endDuel();
    await wait(250);
    return { derrota, empate: CALLS.slice(), ovEmpate: document.getElementById('ovPts').textContent };
  });
  t('derrota: arena_result com p_win false', JSON.stringify(a4.derrota) === JSON.stringify([['arena_result', { p_win: false }]]), a4.derrota);
  t('empate: nao gasta chamada', a4.empate.length === 0, a4.empate);
  t('empate: avisa que nao trocou pontos', /nenhum ponto/.test(a4.ovEmpate), a4.ovEmpate);

  /* ---- 5. erro do servidor -------------------------------------------- */
  const a5 = await p.evaluate(async () => {
    FAKE.arena_result = { error: 'muito_rapido' };
    go('arena'); await wait(300);
    await duelarArena();
    duel.you = 20; duel.foe = 0; endDuel();
    await wait(300);
    const tt = document.getElementById('toast');
    return { pts: document.getElementById('ovPts').textContent, toast: tt ? tt.textContent : null };
  });
  t('erro: overlay nao inventa premio', a5.pts === '', a5.pts);
  t('erro: avisa muito rapido', /rápido demais/.test(a5.toast || ''), a5.toast);

  /* ---- 6. oponente da guilda (PNJ, sem deck) --------------------------- */
  const a6 = await p.evaluate(async () => {
    FAKE.arena_find = { ok: true, bot: true, nome: 'Corvo de Bronze', elem: 'raio', pts: 90, liga: 'Bronze', cartas: null, meus_pts: 147, minha_liga: 'Bronze' };
    arena = null; go('arena'); await wait(300);
    const box = document.getElementById('arBox').textContent.replace(/\s+/g, ' ');
    await duelarArena();
    const els = duel.foeHand.concat(duel.foeRest).map(c => c.el);
    const st = duel.foeHand.concat(duel.foeRest).reduce((a, c) => a + c.st, 0);
    return { box, n: els.length, soRaio: els.every(e => e === 'raio'), estrelas: st };
  });
  t('pnj: chip de guilda aparece', /guilda/.test(a6.box), a6.box);
  t('pnj: deck montado com 8 cartas', a6.n === 8, a6.n);
  t('pnj: deck do elemento do PNJ', a6.soRaio === true, a6);
  t('pnj: deck respeita 20 estrelas', a6.estrelas <= 20, a6.estrelas);

  /* ---- 7. ranking real ------------------------------------------------- */
  const a7 = await p.evaluate(async () => {
    go('ranking'); await new Promise(r => setTimeout(r, 350));
    return {
      me: document.getElementById('rankMe').textContent.replace(/\s+/g, ' ').trim(),
      lista: document.getElementById('rankList').textContent.replace(/\s+/g, ' ').trim(),
      linhas: document.getElementById('rankList').querySelectorAll('.row-item').length,
      falso: /NéreoAzul|DragãoRubro|1\.020/.test(document.getElementById('s-ranking').textContent)
    };
  });
  t('ranking: minha linha com posicao real', /#2/.test(a7.me) && /\(você\)/.test(a7.me), a7.me);
  t('ranking: lista com 2 gladiadores', a7.linhas === 2, a7.linhas);
  t('ranking: ArenaBeta em primeiro', /#1\s*ArenaBeta/.test(a7.lista.replace(/\s+/g, ' ')), a7.lista);
  t('ranking: nomes falsos sumiram', a7.falso === false);

  /* ---- 8. perfil real -------------------------------------------------- */
  const a8 = await p.evaluate(async () => {
    profile.vitorias = 3; profile.derrotas = 1; profile.rank_pts = 147; profile.liga = 'Bronze'; profile.nivel = 3;
    go('perfil'); await new Promise(r => setTimeout(r, 350));
    const s = document.getElementById('s-perfil');
    return {
      nome: document.getElementById('perfNome').textContent,
      sub: document.getElementById('perfSub').textContent,
      vit: document.getElementById('perfVit').textContent,
      wr: document.getElementById('perfWr').textContent,
      cartas: document.getElementById('perfCartas').textContent,
      hist: document.getElementById('history').textContent.replace(/\s+/g, ' ').trim(),
      histHtml: document.getElementById('history').innerHTML,
      apagados: Array.from(s.querySelectorAll('.badge2')).map(b => b.style.opacity),
      nav: !document.getElementById('bottomnav').classList.contains('hidden')
    };
  });
  t('perfil: nome real', a8.nome === 'Eu', a8.nome);
  t('perfil: liga, nivel e pontos', /Bronze · Nível 3 · 147 pts/.test(a8.sub), a8.sub);
  t('perfil: vitorias e winrate calculados', a8.vit === '3' && a8.wr === '75%', a8);
  t('perfil: contagem de cartas real', a8.cartas === '52', a8.cartas);
  t('perfil: conquista nao ganha fica apagada', a8.apagados[3] === '0.3' && a8.apagados[0] === '1', a8.apagados);
  t('perfil: historico do banco', /ArenaBeta/.test(a8.hist) && /\+27/.test(a8.hist) && /-15/.test(a8.hist), a8.hist);
  t('perfil: escapa HTML do historico', !/<b>/.test(a8.histHtml.replace(/<b style/g, '')), a8.histHtml.slice(0, 200));
  t('perfil: barra de baixo visivel', a8.nav === true);

  /* ---- 9. convidado ---------------------------------------------------- */
  const a9 = await p.evaluate(async () => {
    online = false; profile = null; ownedSet = null; arena = null;
    go('arena'); await new Promise(r => setTimeout(r, 250));
    const box = document.getElementById('arBox').textContent.replace(/\s+/g, ' ');
    CALLS.length = 0;
    arenaGuest(); await wait(2900);
    const nome = document.getElementById('foeName').textContent;
    duel.you = 12; duel.foe = 0; endDuel();
    await wait(250);
    go('ranking'); await new Promise(r => setTimeout(r, 250));
    const rk = document.getElementById('rankMe').textContent;
    go('perfil'); await new Promise(r => setTimeout(r, 250));
    return { box, nome, chamadas: CALLS.slice(), rk,
             perfNome: document.getElementById('perfNome').textContent,
             hist: document.getElementById('history').textContent };
  });
  t('convidado: oferece treino com a guilda', /guilda/.test(a9.box), a9.box);
  t('convidado: duelo local comeca', a9.nome.length > 3, a9.nome);
  t('convidado: nao chama o servidor', a9.chamadas.length === 0, a9.chamadas);
  t('convidado: ranking pede login', /Entre na sua conta/.test(a9.rk), a9.rk);
  t('convidado: perfil mostra convidado', a9.perfNome === 'Convidado', a9.perfNome);
  t('convidado: historico pede login', /Entre na sua conta/.test(a9.hist), a9.hist);

  /* ---- 10. barra de baixo nas telas com has-nav ------------------------ */
  const a10 = await p.evaluate(async () => {
    const r = {};
    for (const id of ['home', 'map', 'collection', 'shop', 'ranking', 'arena', 'carreira', 'torre', 'clan', 'perfil', 'deck', 'config']) {
      go(id); await new Promise(x => setTimeout(x, 60));
      r[id] = !document.getElementById('bottomnav').classList.contains('hidden');
    }
    return r;
  });
  const devem = ['home', 'map', 'collection', 'shop', 'ranking', 'arena', 'carreira', 'torre', 'clan', 'perfil'];
  t('nav: aparece nas 10 telas principais', devem.every(k => a10[k] === true), a10);
  t('nav: some no deck e nas configuracoes', a10.deck === false && a10.config === false, a10);

  /* ---- fotos ----------------------------------------------------------- */
  await p.evaluate(() => {
    online = true;
    ownedSet = new Set(DECKI.map(c => slug(c.nm)));
    profile = { username: 'Gladiador', ouro: 512, gemas: 12, essencia: 4, nivel: 3, rank_pts: 147, liga: 'Bronze', vitorias: 3, derrotas: 1 };
    FAKE.arena_find = { ok: true, bot: false, nome: 'ArenaBeta', elem: 'agua', pts: 340, liga: 'Prata',
      cartas: [0, 1, 10, 15, 26, 32, 39, 45].map(i => slug(DECKI[i].nm)), meus_pts: 147, minha_liga: 'Bronze' };
    arena = null; applyProfile();
  });
  for (const [id, f] of [['arena', 'v08-arena'], ['ranking', 'v08-ranking'], ['perfil', 'v08-perfil']]) {
    await p.evaluate(x => go(x), id);
    await p.waitForTimeout(600);
    await p.screenshot({ path: DIR + '/' + f + '.png' });
  }

  console.log('PASSOU: ' + ok.length + '/' + (ok.length + bad.length));
  if (bad.length) console.log('FALHOU:\n - ' + bad.join('\n - '));
  console.log('ERROS DE PAGINA: ' + (errs.length ? errs.join(' | ') : 'NENHUM'));
  await b.close();
  process.exit(bad.length || errs.length ? 1 : 0);
})();
