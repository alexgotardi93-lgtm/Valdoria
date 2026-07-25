const {chromium}=require('playwright');
(async()=>{
const b=await chromium.launch({executablePath:'/opt/pw-browsers/chromium'});
const p=await b.newPage({viewport:{width:390,height:844}});
const errs=[];p.on('pageerror',e=>errs.push(e.message));
await p.goto('file:///home/claude/valdoria-jogo/index.html');
await p.waitForTimeout(900);

const out=await p.evaluate(()=>{
  const cap=v=>Math.min(20,v);
  function legalDeck(){ // 8 cartas, <=20 estrelas (mesma regra do jogador)
    for(let t=0;t<200;t++){
      const d=DECKI.slice().sort(()=>Math.random()-.5).slice(0,8);
      if(d.reduce((a,c)=>a+c.st,0)<=20)return d;
    }
    return DECKI.slice().sort((a,b)=>a.st-b.st).slice(0,8);
  }
  function clash(aC,dC,aH,dH,aHp,dHp){return computeClash(aC,dC,aH,dH,aHp,dHp);}
  function sim(){
    const dA=legalDeck().sort(()=>Math.random()-.5), dB=legalDeck().sort(()=>Math.random()-.5);
    const hA=dA.slice(0,4),hB=dB.slice(0,4),rA=dA.slice(4),rB=dB.slice(4);
    let hpA=20,hpB=20,starter=Math.random()<.5?'A':'B',sd=false;
    function play(atkS){
      const aH=atkS==='A'?hA:hB, dH=atkS==='A'?hB:hA;
      const aHp=atkS==='A'?hpA:hpB, dHp=atkS==='A'?hpB:hpA;
      if(!aH.length||!dH.length)return;
      const ai=bestAtkIdx(aH,aHp,dHp);const aC=aH.splice(ai,1)[0];
      const di=bestDefIdx(dH,aC,aH,dHp,aHp);const dC=dH.splice(di,1)[0];
      const R=clash(aC,dC,aH,dH,aHp,dHp);
      if(atkS==='A'){hpA=cap(hpA+R.healA-R.dmgAtk);hpB=cap(hpB+R.healD-R.dmgDef);}
      else{hpB=cap(hpB+R.healA-R.dmgAtk);hpA=cap(hpA+R.healD-R.dmgDef);}
    }
    for(let r=0;r<4;r++){
      play((r%2===0)?starter:(starter==='A'?'B':'A'));
      if(hpA<=0||hpB<=0)return {hpA,hpB,starter,sd};
    }
    let n=0;
    while(hpA===hpB&&rA.length&&rB.length){ // morte subita (repete enquanto houver reserva)
      sd=true;n++;
      hA.length=0;hB.length=0;hA.push(rA.shift());hB.push(rB.shift());
      play(n%2===1?(starter==='A'?'B':'A'):starter);
      if(hpA<=0||hpB<=0)break;
    }
    return {hpA,hpB,starter,sd};
  }
  let A=0,B=0,E=0,ko=0,sHp=0,sSum=0,n=4000,startWin=0,sdN=0,sdE=0;
  for(let i=0;i<n;i++){const s=sim();
    if(s.hpA<=0||s.hpB<=0)ko++;
    if(s.sd)sdN++;
    if(s.hpA>s.hpB){A++;if(s.starter==='A')startWin++;}
    else if(s.hpB>s.hpA){B++;if(s.starter==='B')startWin++;}
    else {E++;if(s.sd)sdE++;}
    sHp+=Math.max(0,s.hpA)+Math.max(0,s.hpB);sSum+=Math.abs(s.hpA-s.hpB);
  }
  return {n,A,B,E,ko,mediaVidaFinal:(sHp/(2*n)).toFixed(2),margemMedia:(sSum/n).toFixed(2),
    vitoriaDeQuemComeca:((startWin/(A+B))*100).toFixed(1)+'%',empates:((E/n)*100).toFixed(1)+'%',
    idaAMorteSubita:((sdN/n)*100).toFixed(1)+'%',empateAposMorteSubita:((sdE/n)*100).toFixed(1)+'%'};
});
console.log(JSON.stringify(out,null,1));
console.log('ERRORS:',errs.length?errs.join('\n'):'NONE');
await b.close();
})();
