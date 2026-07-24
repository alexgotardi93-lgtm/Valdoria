const { chromium } = require('playwright');
const DIR='/home/claude/valdoria-jogo';
(async () => {
  const b = await chromium.launch();
  const ctx = await b.newContext({ viewport:{width:390,height:844}, deviceScaleFactor:2 });
  const p = await ctx.newPage();
  const errs=[]; p.on('console',m=>{if(m.type()==='error'&&!/googleapis|ERR_TUNNEL|Failed to load resource/.test(m.text()))errs.push('CON:'+m.text())}); p.on('pageerror',e=>errs.push('PAGE:'+String(e)));
  await p.goto('file://'+DIR+'/index.html'); await p.waitForTimeout(1200);
  await p.screenshot({path:DIR+'/b-splash.png'});                                  // splash w/ coliseu bg
  await p.evaluate(()=>enter()); await p.waitForTimeout(700);
  await p.screenshot({path:DIR+'/b-home.png'});                                    // home w/ ilha hero
  await p.evaluate(()=>go('map')); await p.waitForTimeout(700);
  await p.screenshot({path:DIR+'/b-map.png'});                                     // map w/ mapa bg
  await p.evaluate(()=>{go('collection');}); await p.waitForTimeout(400);
  await p.screenshot({path:DIR+'/b-collection.png'});
  await p.evaluate(()=>{startDuel();}); await p.waitForTimeout(800);
  await p.screenshot({path:DIR+'/b-duel.png'});                                    // duel w/ arena bg
  await p.evaluate(()=>{ if(typeof duel!=='undefined'&&duel&&duel.hand.length) playCard(0); }); await p.waitForTimeout(800);
  await p.screenshot({path:DIR+'/b-duel2.png'});
  console.log('ERRORS:', errs.length? errs.join(' || '):'NONE');
  await b.close();
})().catch(e=>{console.error('FATAL',e.message);process.exit(1)});
