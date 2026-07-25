-- ---------------------------------------------------------------------
-- 0012 — Duelo ao Vivo: dois acertos encontrados no teste da 0011
--
-- 1) match_state olhava a partida antes da fila.
--    live_minha() devolve tambem a partida encerrada ha menos de 90s
--    (e o que faz a tela de resultado sobreviver a um F5). So que, se o
--    jogador clicasse "jogar de novo" nesses 90 segundos, match_find o
--    colocava na fila e o match_state seguinte continuava devolvendo o
--    duelo velho — o cliente ficava presa na tela de resultado ate o
--    minuto e meio passar. Como entrar na fila e estar em partida sao
--    estados que nunca coexistem (o pareamento apaga as duas linhas da
--    fila na mesma transacao em que cria o duelo), basta perguntar pela
--    fila primeiro.
--
-- 2) live_paga gravava em ouro1/ouro2 o SALDO de ouro depois do
--    pagamento, enquanto delta1/delta2 guardam a VARIACAO de pontos.
--    A tela de resultado mostra os dois lado a lado, entao os dois
--    precisam ser da mesma natureza. Agora ouro1/ouro2 e o quanto o
--    jogador ganhou naquela partida; o saldo o cliente pega no
--    state_get, como ja faz depois de qualquer duelo.
-- ---------------------------------------------------------------------

create or replace function public.live_paga(p_id bigint, p_venc smallint, p_motivo text)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v      live_duels%rowtype;
  v_diff int;
  v_d1 int := 0; v_d2 int := 0;
  v_g1 int := 0; v_g2 int := 0;
begin
  select * into v from live_duels where id = p_id for update;
  if not found or v.estado <> 'ativo' then return; end if;

  -- pontos proporcionais a diferenca, como na Arena, so que pagando mais
  v_diff := greatest(-400, least(400, v.pts2 - v.pts1));
  if p_venc = 1 then
    v_d1 := 30 + (v_diff / 35);    v_g1 := 60;
    v_d2 := -(12 + (v_diff / 55)); v_g2 := 15;
  elsif p_venc = 2 then
    v_d2 := 30 - (v_diff / 35);    v_g2 := 60;
    v_d1 := -(12 - (v_diff / 55)); v_g1 := 15;
  else
    v_g1 := 20; v_g2 := 20;      -- empate: so o ouro de consolacao
  end if;

  -- trava sempre na mesma ordem para nao criar deadlock entre duas partidas
  perform 1 from profiles
   where id in (v.p1, v.p2)
   order by id
     for update;

  update profiles
     set rank_pts  = greatest(0, rank_pts + v_d1),
         ouro      = ouro + v_g1,
         vitorias  = vitorias + case when p_venc = 1 then 1 else 0 end,
         derrotas  = derrotas + case when p_venc = 2 then 1 else 0 end,
         duel_last = now(),
         duel_dia  = current_date,
         duel_qtd  = case when duel_dia = current_date then duel_qtd + 1 else 1 end
   where id = v.p1;

  update profiles
     set rank_pts  = greatest(0, rank_pts + v_d2),
         ouro      = ouro + v_g2,
         vitorias  = vitorias + case when p_venc = 2 then 1 else 0 end,
         derrotas  = derrotas + case when p_venc = 1 then 1 else 0 end,
         duel_last = now(),
         duel_dia  = current_date,
         duel_qtd  = case when duel_dia = current_date then duel_qtd + 1 else 1 end
   where id = v.p2;

  insert into matches(user_id, foe_nome, foe_elem, venceu, pts)
       values (v.p1, v.nome2, v.elem2, p_venc = 1, v_d1),
              (v.p2, v.nome1, v.elem1, p_venc = 2, v_d2);

  update live_duels
     set estado   = case when p_motivo = 'wo' then 'wo' else 'fim' end,
         motivo   = p_motivo,
         vencedor = p_venc,
         delta1   = v_d1, delta2 = v_d2,
         ouro1    = v_g1, ouro2  = v_g2,   -- ganho da partida, nao o saldo
         prazo    = null,
         fim_em   = now()
   where id = p_id;

  -- missoes do dia (profiles ja travado acima: a ordem do jogo e mantida)
  perform missao_prog(v.p1, 'duelo');
  perform missao_prog(v.p2, 'duelo');
  perform missao_prog(v.p1, 'arena');
  perform missao_prog(v.p2, 'arena');
  perform missao_prog(v.p1, 'vivo');
  perform missao_prog(v.p2, 'vivo');
  if p_venc = 1 then
    perform missao_prog(v.p1, 'vitoria');
    perform missao_prog(v.p1, 'arena_vit');
    perform missao_prog(v.p1, 'vivo_vit');
  elsif p_venc = 2 then
    perform missao_prog(v.p2, 'vitoria');
    perform missao_prog(v.p2, 'arena_vit');
    perform missao_prog(v.p2, 'vivo_vit');
  end if;
end $fn$;

create or replace function public.match_state()
returns json
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_user uuid := auth.uid();
  v      live_duels%rowtype;
  v_q    record;
begin
  if v_user is null then return json_build_object('error','auth'); end if;

  -- a fila vem antes: quem pediu outra partida nao pode voltar a ver
  -- o resultado da anterior (os dois estados nunca coexistem)
  select * into v_q from live_queue where user_id = v_user;
  if v_q.user_id is not null then
    return json_build_object('ok', true, 'estado', 'fila',
                             'espera', extract(epoch from (now() - v_q.entrou_em))::int);
  end if;

  v := live_minha(v_user);
  if v.id is not null then
    if v.estado = 'ativo' then v := live_avanca(v.id); end if;
    return live_view(v, case when v.p1 = v_user then 1::smallint else 2::smallint end);
  end if;

  return json_build_object('ok', true, 'estado', 'nada');
end $fn$;

revoke execute on function public.live_paga(bigint, smallint, text) from public, anon, authenticated;
revoke execute on function public.match_state()                     from public, anon, authenticated;
grant  execute on function public.match_state()                     to authenticated;
