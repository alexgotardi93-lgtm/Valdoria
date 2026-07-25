const { chromium } = require('playwright');
const DIR = require('path').join(__dirname, '..');  /* raiz do repo */
(async () => {
  const b = await chromium.launch();
  const p = await (await b.newContext({ viewport:{width:390,height:844}, deviceScaleFactor:2 })).newPage();
  const errs=[]; p.on('console',m=>{if(m.type()==='error'&&!/googleapis|ERR_TUNNEL|Failed to load resource/.test(m.text()))errs.push('CON:'+m.text())}); p.on('pageerror',e=>errs.push('PAGE:'+String(e)));
  await p.goto('file://'+DIR+'/index.html'); await p.waitForTimeout(1000);
  await p.evaluate(()=>{enter();startDuel();});
  await p.waitForTimeout(900); await p.screenshot({path:DIR+'/d-coin.png'});   // coin flip
  await p.waitForTimeout(2600); await p.screenshot({path:DIR+'/d-r1.png'});     // round 1 prompt
  let shots=0, ended=false;
  for(let i=0;i<60;i++){
    const st = await p.evaluate(()=>{
      const ov=document.getElementById('resultOv');
      const over = ov.classList.contains('show') && /VIT|DERR|EMPATE/.test(ov.textContent);
      if(over) return {over:true};
      if(typeof duel!=='undefined'&&duel&&duel.waiting==='you'&&duel.hand.length){ playCard(0); return {acted:true,round:duel.round,phase:duel.phase}; }
      return {waiting:(typeof duel!=='undefined'&&duel)?duel.waiting:null, round:(typeof duel!=='undefined'&&duel)?duel.round:null};
    });
    if(st.over){ended=true;break;}
    if(st.acted && shots<3){ await p.waitForTimeout(500); await p.screenshot({path:DIR+'/d-play'+shots+'.png'}); shots++; }
    await p.waitForTimeout(650);
  }
  await p.waitForTimeout(500); await p.screenshot({path:DIR+'/d-end.png'});
  console.log('ENDED:', ended, '| ERRORS:', errs.length? errs.join(' || '):'NONE');
  await b.close();
})().catch(e=>{console.error('FATAL',e.message);process.exit(1)});
