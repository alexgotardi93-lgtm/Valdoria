const {chromium}=require('playwright');
(async()=>{
const b=await chromium.launch({executablePath:'/opt/pw-browsers/chromium'});
const p=await b.newPage({viewport:{width:390,height:844},deviceScaleFactor:2});
const errs=[];
p.on('console',m=>{if(m.type()==='error'&&!/fonts.g|supabase.co|net::ERR/.test(m.text()))errs.push(m.text());});
p.on('pageerror',e=>errs.push('PAGEERROR: '+e.message));
await p.goto('file:///home/claude/valdoria-jogo/index.html');
await p.waitForTimeout(1200);

const out=await p.evaluate(()=>{
  const R=[];
  const byName={}; DECKI.forEach(c=>byName[slug(c.nm)]=c);
  const g=s=>byName[s];
  const dummy=(el,atk,def)=>({nm:'Dummy',el:el||'fogo',rar:'comum',st:1,atk:atk,def:def,sp:''});
  const T=(label,got,exp)=>R.push({label,got,exp,ok:JSON.stringify(got)===JSON.stringify(exp)});
  const cc=(a,d,ah,dh,ahp,dhp)=>computeClash(a,d,ah||[],dh||[],ahp===undefined?20:ahp,dhp===undefined?20:dhp);

  // ---- base sem especial (neutro): 3 atk vs 2 def = 1 de dano
  let r=cc(dummy('fogo',3,1),dummy('agua',2,2));
  T('base 3atk vs 2def (sem elem)',[r.result,r.dmgDef,r.dmgAtk],[1,1,0]);
  // ---- vantagem elemental agua>fogo: atacante agua contra fogo => +2
  r=cc(dummy('agua',3,1),dummy('fogo',2,2));
  T('vantagem elemental +2',[r.bonus,r.result],[2,3]);

  // FOGO
  r=cc(g('gladiadora-ember'),dummy('agua',1,2),[],[],20,10);
  T('Ember (foe<=10): 3+2-2',[r.A,r.result],[5,3]);
  r=cc(g('gladiadora-ember'),dummy('agua',1,2),[],[],20,11);
  T('Ember (foe 11): sem bonus',[r.A,r.result],[3,1]);
  r=cc(g('berserker-cinzas'),dummy('agua',1,2));
  T('Berserker: +3 ATQ e -1 vida',[r.A,r.result,r.dmgAtk],[6,4,1]);
  r=cc(dummy('agua',5,1),g('salamandra-de-guerra'));
  T('Salamandra def +2 (3+2=5, +2 elem)',[r.Deff,r.result],[5,2]);
  r=cc(g('ignarok-o-incandescente'),dummy('agua',1,4));
  T('Ignarok fura 2 (4-2=2)',[r.Deff,r.result],[2,2]);
  r=cc(g('vulkanor-senhor-das-forjas'),dummy('agua',1,9));
  T('Vulkanor ignora toda DEF',[r.Deff,r.result],[0,5]);
  r=cc(g('fenix-de-chamalar'),dummy('agua',1,1));
  T('Fenix atacando e vencendo +3 vida',[r.result,r.healA],[3,3]);
  r=cc(dummy('agua',1,1),g('fenix-de-chamalar'));
  T('Fenix defendendo e vencendo +3 vida',[r.result,r.healD],[-1,3]);
  r=cc(dummy('agua',9,1),g('piromante-vingativa'));
  T('Piromante def: leva dano e devolve 1',[r.dmgDef,r.dmgAtk],[8,1]);

  // AGUA
  r=cc(g('sanguessuga-abissal'),dummy('nat',1,1));
  T('Sanguessuga: dano + 1 de cura',[r.dmgDef,r.healA],[2,1]);
  r=cc(dummy('agua',4,1),g('corsaria-das-brumas'));  // agua > fogo? corsaria e agua; atacante agua vs agua: sem vantagem
  T('Corsaria: DEF 2, sem vantagem',[r.Deff,r.result],[2,2]);
  r=cc(dummy('raio',4,1),g('corsaria-das-brumas'));  // raio > agua => teria +2, mas nevoa anula
  T('Corsaria anula bonus elemental',[r.bonus,r.result],[0,2]);
  r=cc(g('curandeira-da-mare'),dummy('nat',1,9));
  T('Curandeira sempre +1 vida',[r.healA],[1]);
  r=cc(dummy('nat',6,1),g('guardia-do-recife'));
  T('Guardia do Recife +3 DEF (5+3=8)',[r.Deff,r.result],[8,-2]);
  r=cc(dummy('nat',1,1),g('almirante-neritide'));
  T('Almirante: ataque falhou => +2 vida',[r.healD],[2]);
  r=cc(g('leviata-das-profundezas'),dummy('nat',1,5));
  T('Leviata fura 3 (5-3=2)',[r.Deff,r.result],[2,3]);
  r=cc(dummy('nat',3,1),g('thalassa-rainha-das-mares'));
  T('Thalassa +2 DEF e +3 vida se falhar',[r.Deff,r.healD],[7,3]);

  // NATUREZA
  const nat3=[g('broto-voraz'),g('filhote-de-lobo'),g('casca-grossa')];
  r=cc(g('alcateia-unida'),dummy('agua',1,1),nat3);
  T('Matilha +3 ATQ (3 nat na mao)',[r.A],[5]);
  r=cc(g('alcateia-unida'),dummy('agua',1,1),[]);
  T('Matilha sem nat na mao',[r.A],[2]);
  const mix=[g('recruta-da-forja'),g('grumete-das-mares'),g('fagulha-eletrica')];
  r=cc(g('guardiao-do-arco-iris'),dummy('agua',1,1),mix);
  T('Biodiversidade 4 elementos: +2 ATQ',[r.A],[5]);
  r=cc(g('guardiao-do-arco-iris'),dummy('agua',1,1),[g('recruta-da-forja')]);
  T('Biodiversidade so 2 elementos: sem bonus',[r.A],[3]);
  r=cc(g('urso-espirito'),dummy('agua',1,1));
  T('Urso atacando +1 ATQ',[r.A],[5]);
  r=cc(dummy('agua',9,1),g('urso-espirito'));
  T('Urso defendendo +1 DEF',[r.Deff],[4]);
  r=cc(dummy('agua',9,1),g('ent-anciao'));
  T('Ent +3 DEF (4+3=7)',[r.Deff],[7]);
  r=cc(dummy('agua',1,1),g('colosso-de-carvalho'));
  T('Colosso dobra o recuo (1-4=-3 => 6)',[r.result,r.dmgAtk],[-3,6]);
  r=cc(g('matriarca-da-floresta'),dummy('agua',1,1),nat3);
  T('Matriarca +3 ATQ',[r.A],[6]);
  r=cc(dummy('agua',9,1),g('matriarca-da-floresta'),[],nat3);
  T('Matriarca +3 DEF',[r.Deff],[8]);
  r=cc(g('filhote-de-lobo'),dummy('agua',1,1),[g('gaia-a-mae-bosque')]);
  T('Gaia na mao: +1 ATQ em carta nat',[r.A],[3]);
  r=cc(dummy('agua',9,1),g('casca-grossa'),[],[g('gaia-a-mae-bosque')]);
  T('Gaia na mao: +1 DEF em carta nat',[r.Deff],[5]);

  // RAIO
  r=cc(g('aguia-trovejante'),dummy('agua',1,3));
  T('Aguia fura 1 (3-1=2, +2 elem)',[r.Deff,r.result],[2,3]);
  r=cc(g('condutor-temerario'),dummy('agua',1,2));
  T('Condutor +3 ATQ (4+3=7, +2 elem)',[r.A,r.result],[7,7]);
  r=cc(g('condutor-temerario'),dummy('agua',1,9));
  T('Condutor falhou: recuo +1 extra',[r.result,r.dmgAtk],[0,1]);
  r=cc(g('cavaleira-do-trovao'),dummy('agua',1,1));
  T('Cavaleira: dano 5 +1 = 6',[r.result,r.dmgDef],[5,6]);
  r=cc(g('cavaleira-do-trovao'),dummy('agua',1,9));
  T('Cavaleira sem vencer: sem +1',[r.dmgDef,r.dmgAtk],[0,3]);
  r=cc(g('xama-das-tempestades'),dummy('agua',1,1)); // raio > agua
  T('Xama: bonus elemental vira +4',[r.bonus,r.result],[4,6]);
  r=cc(g('xama-das-tempestades'),dummy('nat',1,1)); // sem vantagem
  T('Xama sem vantagem: bonus 0',[r.bonus,r.result],[0,2]);
  r=cc(dummy('nat',9,1),g('senhor-dos-ventos'));
  T('Senhor dos Ventos reduz 2 do dano',[r.result,r.dmgDef],[8,6]);
  r=cc(g('tempestade-viva'),dummy('nat',1,5));
  T('Tempestade +2 ATQ e fura 2',[r.A,r.Deff,r.result],[6,3,3]);
  r=cc(g('zephyros-furia-do-ceu'),dummy('nat',1,20));
  T('Zephyros nunca sofre recuo',[r.result,r.dmgAtk],[-12,0]);

  // combos
  r=cc(g('vulkanor-senhor-das-forjas'),g('thalassa-rainha-das-mares'));
  T('Vulkanor x Thalassa: fura tudo',[r.Deff,r.dmgDef],[0,5]);
  r=cc(g('cavaleira-do-trovao'),g('senhor-dos-ventos')); // 4 atk vs 3 def = 1; -2 => 0 ; cavaleira so soma se dmg>0
  T('Cavaleira x Senhor dos Ventos',[r.result,r.dmgDef],[1,0]);

  const ok=R.filter(x=>x.ok).length;
  return {total:R.length,ok:ok,fails:R.filter(x=>!x.ok)};
});
console.log('TESTES:',out.ok+'/'+out.total);
if(out.fails.length)console.log(JSON.stringify(out.fails,null,1));
console.log('ERRORS:',errs.length?errs.join('\n'):'NONE');
await b.close();
process.exit(out.fails.length?1:0);
})();
