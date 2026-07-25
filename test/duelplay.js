const {chromium}=require('playwright');
(async()=>{
const b=await chromium.launch({executablePath:'/opt/pw-browsers/chromium'});
const p=await b.newPage({viewport:{width:390,height:844},deviceScaleFactor:2});
const errs=[];
p.on('console',m=>{if(m.type()==='error'&&!/fonts.g|supabase.co|net::ERR/.test(m.text()))errs.push(m.text());});
p.on('pageerror',e=>errs.push('PAGEERROR: '+e.message));
await p.goto('file://' + require('path').join(__dirname, '..') + '/index.html');
await p.waitForTimeout(1400);

// deck fixo com cartas de especial forte, para garantir chips na resolucao
await p.evaluate(()=>{
  const want=['Vulkanor, Senhor das Forjas','Cavaleira do Trovão','Fênix de Chamalar','Piromante Vingativa',
              'Berserker Cinzas','Alcateia Unida','Curandeira da Maré','Águia Trovejante'];
  deck=want.map(n=>DECKI.findIndex(c=>c.nm===n)).filter(i=>i>=0);
  startDuel();
});
await p.waitForTimeout(3200);

const S=()=>p.evaluate(()=>duel?{r:duel.round,ph:duel.phase,at:duel.attacker,you:duel.you,foe:duel.foe,sd:!!duel.sudden,n:duel.hand.length}:null);
const msg=()=>p.evaluate(()=>{const d=document.querySelector('.duel-msg');return d?d.innerText.replace(/\n+/g,' | '):'';});
const shots=[];let got={};
for(let i=0;i<140;i++){
  const st=await S();
  if(!st)break;
  const m=await msg();
  if(!got.res&&/Acertou|Recuo|segurou|Empate no confronto|conectou/.test(m)){
    got.res=m;await p.screenshot({path:require('path').join(__dirname,'..') + '/shot_R_resolucao.png'});
    got.over=await p.evaluate(()=>{const s=document.getElementById('s-duel');return s.scrollHeight-s.clientHeight;});
  }
  await p.evaluate(()=>{
    if(!duel)return;
    if(duel.phase==='atk'&&duel.attacker==='you'&&!duel.atkCard)playCard(bestAtkIdx(duel.hand,duel.you,duel.foe));
    else if(duel.phase==='def'&&duel.attacker==='foe'&&!duel.defCard&&duel.atkCard)
      playCard(bestDefIdx(duel.hand,duel.atkCard.card,duel.foeHand,duel.you,duel.foe));
  });
  await p.waitForTimeout(350);
  const done=await p.evaluate(()=>document.getElementById('resultOv').classList.contains('show')&&/VIT|DERR|EMPATE/.test(document.getElementById('resultOv').innerText));
  if(done)break;
}
await p.waitForTimeout(600);
await p.screenshot({path:require('path').join(__dirname,'..') + '/shot_F_fim.png'});
const fim=await p.evaluate(()=>document.getElementById('resultOv').innerText.replace(/\n+/g,' | '));
console.log(JSON.stringify({resolucao:got.res,overflow:got.over,fim},null,1));
console.log('ERRORS:',errs.length?errs.join('\n'):'NONE');
await b.close();
})();
