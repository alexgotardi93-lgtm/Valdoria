/* v0.9 — painel Missoes do Dia: modo convidado (offline) e modo online (RPC dublado) */
const { chromium } = require('playwright');
const DIR = require('path').join(__dirname, '..');  /* raiz do repo */

const FAKE = {
  ok: true,
  missoes: [
    { i:1, slug:'areia',    titulo:'Poeira da Areia', descr:'Termine 3 duelos',
      alvo:3, prog:2, ouro:60,  gemas:0, essencia:0,  pego:false, pronta:false },
    { i:2, slug:'bigorna',  titulo:'Bigorna Quente',  descr:'Forje 1 carta',
      alvo:1, prog:1, ouro:120, gemas:1, essencia:0,  pego:false, pronta:true  },
    { i:3, slug:'feira',    titulo:'Dia de Feira',    descr:'Compre 1 carta na loja',
      alvo:1, prog:1, ouro:50,  gemas:0, essencia:25, pego:true,  pronta:false }
  ],
  prontas:1, bonus_pego:false, bonus_pronto:false,
  bonus_ouro:100, bonus_gemas:2, renova_em:19860
};

(async () => {
  const b = await chromium.launch();
  const ctx = await b.newContext({ viewport:{width:390,height:844}, deviceScaleFactor:2 });
  const p = await ctx.newPage();
  const errs = [];
  p.on('console', m => { if (m.type()==='error' && !/googleapis|ERR_TUNNEL|Failed to load resource/.test(m.text())) errs.push('CON:'+m.text()); });
  p.on('pageerror', e => errs.push('PAGE:'+String(e)));

  const out = [];
  const chk = (nome, cond, det) => out.push((cond?'ok  ':'FALHOU  ') + nome + (det?'  ['+det+']':''));

  await p.goto('file://' + DIR + '/index.html');
  await p.waitForTimeout(1200);

  /* ---------- 1) modo convidado ---------- */
  await p.evaluate(() => enter());
  await p.waitForTimeout(800);
  const g = await p.evaluate(() => ({
    txt: document.getElementById('missList').textContent,
    dot: document.querySelector('.navb[data-scr="home"]').classList.contains('has-dot'),
    hora: document.getElementById('missTime').textContent
  }));
  chk('convidado ve o convite pra entrar',
      /Só para quem tem conta/.test(g.txt) && /três missões novas todo dia/i.test(g.txt),
      g.txt.slice(0,40));
  chk('convidado nao ganha ponto no nav', g.dot === false);
  chk('convidado nao ve contador', g.hora === '');
  await p.screenshot({ path: DIR+'/m-home-convidado.png' });

  /* ---------- 2) modo online, com a RPC dublada ---------- */
  await p.evaluate((fake) => {
    window.chamadas = [];
    window.__sb = {
      rpc: async (nome, args) => {
        window.chamadas.push([nome, args]);
        if (nome === 'missions_get') return { data: window.__miss };
        if (nome === 'missions_claim') {
          const i = args.p_idx;
          if (i === 4) { window.__miss.bonus_pego = true; window.__miss.bonus_pronto = false; }
          else {
            const m = window.__miss.missoes.find(x => x.i === i);
            m.pego = true; m.pronta = false; window.__miss.prontas--;
            if (window.__miss.missoes.every(x => x.pego)) window.__miss.bonus_pronto = true;
          }
          return { data: { ok:true, idx:i, ganho_ouro:120, ganho_gemas:1, ganho_essencia:0,
                           ouro:999, gemas:13, essencia:25 } };
        }
        return { data: {} };
      }
    };
    window.__miss = JSON.parse(JSON.stringify(fake));
    /* online/sb/profile sao bindings lexicais do script: so um eval global alcanca */
    window.eval("online = true; sb = window.__sb; profile = { username:'Teste', ouro:365, gemas:12, essencia:0, liga:'Bronze', nivel:1 };");
  }, FAKE);

  await p.evaluate(() => go('home'));
  await p.waitForTimeout(600);

  const o = await p.evaluate(() => {
    const rows = [...document.querySelectorAll('#missList .miss')];
    return {
      n: rows.length,
      dot: document.querySelector('.navb[data-scr="home"]').classList.contains('has-dot'),
      hora: document.getElementById('missTime').textContent,
      barra1: rows[0].querySelector('.mbar u').style.width,
      sub1: rows[0].querySelector('.mtx i').textContent,
      bt1: rows[0].querySelector('button') ? rows[0].querySelector('button').disabled : null,
      bt2: rows[1].querySelector('button') ? rows[1].querySelector('button').disabled : null,
      tick3: !!rows[2].querySelector('.tick'),
      pay2: rows[1].querySelector('.pay').textContent.trim(),
      pay3: rows[2].querySelector('.pay').textContent.trim(),
      bonusTit: rows[3].querySelector('b').textContent,
      bonusSub: rows[3].querySelector('.mtx i').textContent,
      btB: rows[3].querySelector('button') ? rows[3].querySelector('button').disabled : null,
      chamou: window.chamadas.map(c => c[0])
    };
  });
  chk('desenha 3 missoes + a linha do bonus', o.n === 4, o.n);
  chk('chamou missions_get', o.chamou.indexOf('missions_get') >= 0, o.chamou.join(','));
  chk('barra da 1a em 67% (2 de 3)', o.barra1 === '67%', o.barra1);
  chk('subtitulo mostra o progresso', /2\/3/.test(o.sub1), o.sub1);
  chk('missao incompleta com botao travado', o.bt1 === true);
  chk('missao pronta com botao liberado', o.bt2 === false);
  chk('missao ja coletada vira visto', o.tick3 === true);
  chk('pagamento em gema aparece', /1 gema/.test(o.pay2), o.pay2);
  chk('pagamento em essencia aparece', /25 ess/.test(o.pay3), o.pay3);
  chk('bonus e a ultima linha', /B/.test(o.bonusTit) && /nus/.test(o.bonusTit), o.bonusTit);
  chk('bonus conta 1 de 3', /1\/3/.test(o.bonusSub), o.bonusSub);
  chk('bonus travado antes da hora', o.btB === true);
  chk('ponto dourado aceso com missao pronta', o.dot === true);
  chk('contador de renovacao em 5h', /5h/.test(o.hora), o.hora);
  await p.screenshot({ path: DIR+'/m-home-missoes.png' });

  /* ---------- 3) coletar ---------- */
  await p.evaluate(() => {
    const rows = [...document.querySelectorAll('#missList .miss')];
    rows[1].querySelector('button').click();
  });
  await p.waitForTimeout(700);
  const c = await p.evaluate(() => ({
    ouro: document.getElementById('ouro').textContent,
    gemas: document.getElementById('ess').textContent,
    toast: (document.getElementById('toast')||{}).textContent,
    tick2: !!document.querySelectorAll('#missList .miss')[1].querySelector('.tick'),
    dot: document.querySelector('.navb[data-scr="home"]').classList.contains('has-dot'),
    chamou: window.chamadas.map(c => c[0] + (c[1] ? ':' + JSON.stringify(c[1]) : ''))
  }));
  chk('coletar chama missions_claim com o indice', c.chamou.indexOf('missions_claim:{"p_idx":2}') >= 0, c.chamou.join(' '));
  chk('topbar recebe o ouro novo', c.ouro === '999', c.ouro);
  chk('topbar recebe as gemas novas', c.gemas === '13', c.gemas);
  chk('avisa o ganho', /120 Ouro/.test(c.toast||''), c.toast);
  chk('a linha coletada vira visto', c.tick2 === true);
  chk('ponto apaga quando nada esta pronto', c.dot === false);

  /* ---------- 4) completar tudo e pegar o bonus ---------- */
  await p.evaluate(() => {
    window.__miss.missoes[0].pego = true; window.__miss.missoes[0].pronta = false;
    window.__miss.bonus_pronto = true; window.__miss.prontas = 0;
    renderMissions();
  });
  await p.waitForTimeout(500);
  const bb = await p.evaluate(() => {
    const r = [...document.querySelectorAll('#missList .miss')][3];
    return { travado: r.querySelector('button').disabled,
             sub: r.querySelector('.mtx i').textContent,
             largura: r.querySelector('.mbar u').style.width,
             dot: document.querySelector('.navb[data-scr="home"]').classList.contains('has-dot') };
  });
  chk('bonus libera com as tres feitas', bb.travado === false);
  chk('bonus conta 3 de 3', /3\/3/.test(bb.sub), bb.sub);
  chk('barra do bonus cheia', bb.largura === '100%', bb.largura);
  chk('ponto acende pelo bonus', bb.dot === true);
  await p.screenshot({ path: DIR+'/m-home-bonus.png' });

  await p.evaluate(() => [...document.querySelectorAll('#missList .miss')][3].querySelector('button').click());
  await p.waitForTimeout(700);
  const fim = await p.evaluate(() => ({
    tick: !!([...document.querySelectorAll('#missList .miss')][3].querySelector('.tick')),
    dot: document.querySelector('.navb[data-scr="home"]').classList.contains('has-dot')
  }));
  chk('bonus coletado vira visto', fim.tick === true);
  chk('ponto apaga com tudo coletado', fim.dot === false);
  await p.screenshot({ path: DIR+'/m-home-fim.png' });

  console.log(out.join('\n'));
  console.log('ERROS DE JS:', errs.length ? errs.join(' || ') : 'NENHUM');
  console.log(out.some(l => l.indexOf('FALHOU') === 0) || errs.length ? 'RESULTADO: FALHOU' : 'RESULTADO: TUDO CERTO');
  await b.close();
})().catch(e => { console.error('FATAL', e.message); process.exit(1); });
