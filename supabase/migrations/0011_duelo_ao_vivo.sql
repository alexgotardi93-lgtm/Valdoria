-- =====================================================================
-- 0011 — DUELO AO VIVO (PvP em tempo real)
--
-- Dois jogadores de verdade, na mesma partida, ao mesmo tempo.
--
-- Quem manda na partida e o servidor: ele sorteia os decks (ja embaralhados),
-- sorteia quem comeca, e guarda a LINHA DO TEMPO das jogadas com um prazo
-- para cada uma. O cliente nao decide nada do fluxo: ele so pergunta o
-- estado, aplica as jogadas que faltam e manda a sua quando e a vez dele.
--
-- Isso fecha a fuga no meio do duelo que a Arena da v0.8 tinha: sumir da tela
-- nao "cancela" nada, porque o relogio continua correndo no banco. Duas faltas
-- seguidas e W.O. — derrota registrada.
--
-- O resultado do confronto (o computeClash, com os 28 especiais) continua
-- sendo calculado no JavaScript, porque e deterministico e os dois lados tem
-- exatamente a mesma entrada. Por isso o placar final e CONFERIDO NOS DOIS
-- LADOS: cada um reporta as duas vidas e so paga se as duas versoes baterem.
-- Divergiu, ninguem ganha ponto e os dois levam uma marca de disputa; quem
-- junta 3 marcas no dia fica fora do Duelo ao Vivo ate a virada.
--
-- Como o deck dos dois precisa estar na mao dos dois clientes para o calculo
-- bater, o Duelo ao Vivo e ABERTO de proposito: os dois veem a mao um do
-- outro. Simetrico, entao ninguem leva vantagem lendo a rede.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Colunas novas no perfil: controle de disputa do dia
-- ---------------------------------------------------------------------
alter table public.profiles
  add column if not exists live_disputas smallint not null default 0,
  add column if not exists live_dia      date;

-- ---------------------------------------------------------------------
-- 2) Fila de espera
-- ---------------------------------------------------------------------
create table if not exists public.live_queue (
  user_id   uuid primary key references auth.users(id) on delete cascade,
  nome      text not null,
  pts       int  not null default 0,
  elem      text,
  cartas    text[] not null,
  entrou_em timestamptz not null default now()
);
create index if not exists live_queue_pts_idx on public.live_queue(pts, entrou_em);

alter table public.live_queue enable row level security;
revoke all on public.live_queue from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3) Partidas ao vivo
--
--    jogadas: [{"r":rodada,"f":"atk"|"def","s":1|2,"c":indice 0..7}]
--    rodada 0..3 = as quatro rodadas normais; 4..7 = morte subita 1..4.
--    Na morte subita a carta e obrigatoriamente a de indice = rodada
--    (reserva sacada na ordem), entao os dois lados sacam a mesma coisa.
-- ---------------------------------------------------------------------
create table if not exists public.live_duels (
  id        bigserial primary key,
  p1        uuid not null references auth.users(id) on delete cascade,
  p2        uuid not null references auth.users(id) on delete cascade,
  nome1     text not null,
  nome2     text not null,
  pts1      int  not null,
  pts2      int  not null,
  elem1     text,
  elem2     text,
  deck1     text[] not null,
  deck2     text[] not null,
  starter   smallint not null,
  rodada    smallint not null default 0,
  fase      text     not null default 'atk',
  prazo     timestamptz,
  jogadas   jsonb    not null default '[]'::jsonb,
  faltas1   smallint not null default 0,
  faltas2   smallint not null default 0,
  rep1      smallint[],
  rep2      smallint[],
  rep1_em   timestamptz,
  rep2_em   timestamptz,
  estado    text not null default 'ativo',   -- ativo | fim | wo | disputa
  motivo    text,                            -- placar | wo | ausente | disputa
  vencedor  smallint,                        -- 1, 2 ou 0 (empate)
  vida1     smallint,
  vida2     smallint,
  delta1    int, delta2 int,
  ouro1     int, ouro2 int,
  criado_em timestamptz not null default now(),
  fim_em    timestamptz,
  constraint live_duels_dois check (p1 <> p2),
  constraint live_duels_slot check (starter in (1,2))
);
create index if not exists live_duels_p1_idx on public.live_duels(p1) where estado = 'ativo';
create index if not exists live_duels_p2_idx on public.live_duels(p2) where estado = 'ativo';

alter table public.live_duels enable row level security;
revoke all on public.live_duels from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4) live_turno — de quem e a vez. Copia exata da regra do cliente.
--
--    rodadas 0..3: ataca quem comecou nas pares, o outro nas impares.
--    morte subita (4..7): alterna, e na primeira quem comecou DEFENDE.
-- ---------------------------------------------------------------------
create or replace function public.live_turno(p_starter smallint, p_rodada smallint, p_fase text)
returns smallint
language sql
immutable
set search_path = public
as $$
  select case when p_fase = 'atk' then t.atacante else (3 - t.atacante)::smallint end
  from (
    select case
      when p_rodada <= 3 then
        case when p_rodada % 2 = 0 then p_starter else (3 - p_starter)::smallint end
      else
        case when (p_rodada - 3) % 2 = 1 then (3 - p_starter)::smallint else p_starter end
    end as atacante
  ) t;
$$;

-- ---------------------------------------------------------------------
-- 5) live_auto — carta que o servidor joga por quem sumiu.
--    Regra fixa (a menor disponivel) para os dois clientes concordarem.
-- ---------------------------------------------------------------------
create or replace function public.live_auto(p_jogadas jsonb, p_rodada smallint, p_slot smallint)
returns smallint
language sql
stable
set search_path = public
as $$
  select case when p_rodada >= 4 then p_rodada else (
    select min(i)::smallint from generate_series(0, 3) i
     where not exists (
       select 1 from jsonb_array_elements(p_jogadas) j
        where (j->>'s')::int = p_slot and (j->>'c')::int = i)
  ) end;
$$;

-- ---------------------------------------------------------------------
-- 6) live_livre — a carta pedida ainda esta na mao daquele jogador?
-- ---------------------------------------------------------------------
create or replace function public.live_livre(p_jogadas jsonb, p_rodada smallint, p_slot smallint, p_carta smallint)
returns boolean
language sql
stable
set search_path = public
as $$
  select case
    when p_carta is null or p_carta < 0 or p_carta > 7 then false
    when p_rodada >= 4 then p_carta = p_rodada
    when p_carta > 3   then false
    else not exists (
      select 1 from jsonb_array_elements(p_jogadas) j
       where (j->>'s')::int = p_slot and (j->>'c')::int = p_carta)
  end;
$$;

-- ---------------------------------------------------------------------
-- 7) live_paga — fecha a partida e paga os dois de uma vez.
--
--    Trava os dois perfis em ordem crescente de uuid: se duas partidas
--    fecharem no mesmo instante com os mesmos jogadores, ninguem enrosca.
--    Depois de profiles vem missions — a mesma ordem do resto do jogo.
-- ---------------------------------------------------------------------
create or replace function public.live_paga(p_id bigint, p_venc smallint, p_motivo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v      live_duels%rowtype;
  v_diff int;
  v_d1 int := 0; v_d2 int := 0;
  v_g1 int := 0; v_g2 int := 0;
  v_o1 int; v_o2 int;
begin
  select * into v from live_duels where id = p_id for update;
  if not found or v.estado <> 'ativo' then return; end if;

  -- pontos proporcionais a diferenca, como na Arena, so que pagando mais
  v_diff := greatest(-400, least(400, v.pts2 - v.pts1));
  if p_venc = 1 then
    v_d1 := 30 + (v_diff / 35);  v_g1 := 60;
    v_d2 := -(12 + (v_diff / 55)); v_g2 := 15;
  elsif p_venc = 2 then
    v_d2 := 30 - (v_diff / 35);  v_g2 := 60;
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
   where id = v.p1
   returning ouro into v_o1;

  update profiles
     set rank_pts  = greatest(0, rank_pts + v_d2),
         ouro      = ouro + v_g2,
         vitorias  = vitorias + case when p_venc = 2 then 1 else 0 end,
         derrotas  = derrotas + case when p_venc = 1 then 1 else 0 end,
         duel_last = now(),
         duel_dia  = current_date,
         duel_qtd  = case when duel_dia = current_date then duel_qtd + 1 else 1 end
   where id = v.p2
   returning ouro into v_o2;

  insert into matches(user_id, foe_nome, foe_elem, venceu, pts)
       values (v.p1, v.nome2, v.elem2, p_venc = 1, v_d1),
              (v.p2, v.nome1, v.elem1, p_venc = 2, v_d2);

  update live_duels
     set estado   = case when p_motivo = 'wo' then 'wo' else 'fim' end,
         motivo   = p_motivo,
         vencedor = p_venc,
         delta1   = v_d1, delta2 = v_d2,
         ouro1    = v_o1, ouro2  = v_o2,
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
end $$;

-- ---------------------------------------------------------------------
-- 8) live_disputa — ninguem ganha ponto e os dois levam uma marca
-- ---------------------------------------------------------------------
create or replace function public.live_disputa(p_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v live_duels%rowtype;
begin
  select * into v from live_duels where id = p_id for update;
  if not found or v.estado <> 'ativo' then return; end if;

  perform 1 from profiles where id in (v.p1, v.p2) order by id for update;

  update profiles
     set live_disputas = case when live_dia = current_date then live_disputas + 1 else 1 end,
         live_dia      = current_date
   where id in (v.p1, v.p2);

  update live_duels
     set estado = 'disputa', motivo = 'disputa', prazo = null, fim_em = now()
   where id = p_id;
end $$;

-- ---------------------------------------------------------------------
-- 9) live_avanca — o relogio.
--
--    Roda antes de qualquer leitura. Enquanto o prazo estiver vencido:
--    joga a carta automatica de quem devia jogar e marca falta. Duas faltas
--    seguidas: W.O. Quem ja reportou o placar nao leva falta (esta esperando
--    o outro), mas tambem nao segura o jogo: a carta automatica entra igual.
-- ---------------------------------------------------------------------
create or replace function public.live_avanca(p_id bigint)
returns live_duels
language plpgsql
security definer
set search_path = public
as $$
declare
  v      live_duels%rowtype;
  v_slot smallint;
  v_c    smallint;
  v_n    int := 0;
  v_venc smallint;
  v_r    smallint[];
begin
  select * into v from live_duels where id = p_id for update;
  if not found then return null; end if;

  -- os dois ja reportaram? decide agora
  if v.estado = 'ativo' and v.rep1 is not null and v.rep2 is not null then
    if v.rep1[1] = v.rep2[1] and v.rep1[2] = v.rep2[2] then
      v_venc := case when v.rep1[1] > v.rep1[2] then 1
                     when v.rep1[1] < v.rep1[2] then 2 else 0 end;
      update live_duels set vida1 = v.rep1[1], vida2 = v.rep1[2] where id = p_id;
      perform live_paga(p_id, v_venc, 'placar');
    else
      perform live_disputa(p_id);
    end if;
    select * into v from live_duels where id = p_id;
    return v;
  end if;

  -- so um reportou e o outro sumiu ha mais de 60s: vale a versao de quem falou
  if v.estado = 'ativo' and (v.rep1 is null) <> (v.rep2 is null) then
    if coalesce(v.rep1_em, v.rep2_em) < now() - interval '60 seconds' then
      v_r := coalesce(v.rep1, v.rep2);
      v_venc := case when v_r[1] > v_r[2] then 1 when v_r[1] < v_r[2] then 2 else 0 end;
      update live_duels set vida1 = v_r[1], vida2 = v_r[2] where id = p_id;
      perform live_paga(p_id, v_venc, 'ausente');
      select * into v from live_duels where id = p_id;
      return v;
    end if;
  end if;

  while v.estado = 'ativo' and v.prazo is not null and now() > v.prazo and v_n < 24 loop
    v_n    := v_n + 1;
    v_slot := live_turno(v.starter, v.rodada, v.fase);
    v_c    := live_auto(v.jogadas, v.rodada, v_slot);
    if v_c is null then
      v.prazo := null;                      -- nao ha mais carta: para o relogio
      exit;
    end if;

    -- quem ja reportou esta esperando o outro, entao nao leva falta
    if v_slot = 1 and v.rep1 is null then v.faltas1 := (v.faltas1 + 1)::smallint;
    elsif v_slot = 2 and v.rep2 is null then v.faltas2 := (v.faltas2 + 1)::smallint;
    end if;

    v.jogadas := v.jogadas || jsonb_build_object('r', v.rodada, 'f', v.fase, 's', v_slot, 'c', v_c, 'auto', true);

    if v.fase = 'atk' then
      v.fase := 'def';
    else
      v.fase   := 'atk';
      v.rodada := (v.rodada + 1)::smallint;
    end if;
    v.prazo := now() + interval '22 seconds';
    if v.rodada > 7 then v.prazo := null; end if;

    if v.faltas1 >= 2 or v.faltas2 >= 2 then
      update live_duels
         set jogadas = v.jogadas, rodada = v.rodada, fase = v.fase,
             faltas1 = v.faltas1, faltas2 = v.faltas2, prazo = null
       where id = p_id;
      perform live_paga(p_id, case when v.faltas1 >= 2 then 2::smallint else 1::smallint end, 'wo');
      select * into v from live_duels where id = p_id;
      return v;
    end if;
  end loop;

  update live_duels
     set jogadas = v.jogadas, rodada = v.rodada, fase = v.fase,
         faltas1 = v.faltas1, faltas2 = v.faltas2, prazo = v.prazo
   where id = p_id
   returning * into v;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- 10) live_view — o que o cliente pode ver.
--     Nunca sai o uuid do adversario, so nome, elemento, pontos e liga.
-- ---------------------------------------------------------------------
create or replace function public.live_view(v live_duels, p_slot smallint)
returns json
language sql
stable
set search_path = public
as $$
  select json_build_object(
    'ok', true,
    'estado', case when v.estado = 'ativo' then 'duelo' else v.estado end,
    'id', v.id,
    'eu', p_slot,
    'nome',  case when p_slot = 1 then v.nome2 else v.nome1 end,
    'elem',  case when p_slot = 1 then v.elem2 else v.elem1 end,
    'pts',   case when p_slot = 1 then v.pts2  else v.pts1  end,
    'liga',  liga(case when p_slot = 1 then v.pts2 else v.pts1 end),
    'meus_pts',   case when p_slot = 1 then v.pts1 else v.pts2 end,
    'minha_liga', liga(case when p_slot = 1 then v.pts1 else v.pts2 end),
    'meu_deck',   case when p_slot = 1 then v.deck1 else v.deck2 end,
    'deck_dele',  case when p_slot = 1 then v.deck2 else v.deck1 end,
    'starter', v.starter,
    'rodada',  v.rodada,
    'fase',    v.fase,
    'resta',   case when v.prazo is null then null
                    else greatest(0, ceil(extract(epoch from (v.prazo - now())))::int) end,
    'jogadas', v.jogadas,
    'motivo',   v.motivo,
    'vencedor', v.vencedor,
    'venci',    case when v.vencedor is null then null else v.vencedor = p_slot end,
    'delta',    case when p_slot = 1 then v.delta1 else v.delta2 end,
    'ouro',     case when p_slot = 1 then v.ouro1  else v.ouro2  end
  );
$$;

-- ---------------------------------------------------------------------
-- 11) live_minha — a partida ativa (ou a recem-encerrada) deste jogador
-- ---------------------------------------------------------------------
create or replace function public.live_minha(p_user uuid)
returns live_duels
language sql
stable
set search_path = public
as $$
  select * from live_duels
   where (p1 = p_user or p2 = p_user)
     and (estado = 'ativo' or fim_em > now() - interval '90 seconds')
   order by id desc limit 1;
$$;

-- ---------------------------------------------------------------------
-- 12) match_find — entra na fila ou pareia na hora
-- ---------------------------------------------------------------------
create or replace function public.match_find()
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user   uuid := auth.uid();
  v_me     record;
  v_cartas text[];
  v_elem   text;
  v_op     record;
  v_id     bigint;
  v        live_duels%rowtype;
  v_faixa  int;
begin
  if v_user is null then return json_build_object('error','auth'); end if;

  -- ja estou em partida? devolve ela (recarregar a pagina volta pro duelo)
  v := live_minha(v_user);
  if v.id is not null and v.estado = 'ativo' then
    v := live_avanca(v.id);
    return live_view(v, case when v.p1 = v_user then 1::smallint else 2::smallint end);
  end if;

  select id, username, rank_pts, duel_dia, duel_qtd, live_dia, live_disputas
    into v_me from profiles where id = v_user;
  if v_me.id is null or v_me.username is null then
    return json_build_object('error','sem_perfil');
  end if;
  if v_me.duel_dia = current_date and v_me.duel_qtd >= 100 then
    return json_build_object('error','limite_diario');
  end if;
  if v_me.live_dia = current_date and v_me.live_disputas >= 3 then
    return json_build_object('error','disputas');
  end if;

  select d.cartas into v_cartas from decks d
   where d.user_id = v_user and d.ativo order by d.updated_at desc limit 1;
  if v_cartas is null or array_length(v_cartas, 1) <> 8 then
    return json_build_object('error','sem_deck');
  end if;
  select c.elemento into v_elem from cards c
   where c.slug = any(v_cartas) group by c.elemento
   order by count(*) desc, c.elemento limit 1;

  -- um pareamento por vez: sem isso dois jogadores se pegam ao mesmo tempo
  perform pg_advisory_xact_lock(hashtext('valdoria_live_match'));

  delete from live_queue where entrou_em < now() - interval '3 minutes';

  -- faixa de pontos abre com o tempo de espera de quem ja esta na fila
  select q.* into v_op from live_queue q
   where q.user_id <> v_user
     and abs(q.pts - v_me.rank_pts) <= greatest(120, extract(epoch from (now() - q.entrou_em))::int * 40)
     and not exists (select 1 from live_duels d
                      where d.estado = 'ativo' and (d.p1 = q.user_id or d.p2 = q.user_id))
   order by q.entrou_em asc
   limit 1
   for update skip locked;

  if v_op.user_id is null then
    insert into live_queue(user_id, nome, pts, elem, cartas, entrou_em)
         values (v_user, v_me.username, v_me.rank_pts, v_elem, v_cartas, now())
    on conflict (user_id) do update
       set nome = excluded.nome, pts = excluded.pts, elem = excluded.elem,
           cartas = excluded.cartas;
    return json_build_object('ok', true, 'estado', 'fila',
                             'meus_pts', v_me.rank_pts, 'minha_liga', liga(v_me.rank_pts));
  end if;

  delete from live_queue where user_id in (v_user, v_op.user_id);

  insert into live_duels(p1, p2, nome1, nome2, pts1, pts2, elem1, elem2,
                         deck1, deck2, starter, prazo)
       values (v_op.user_id, v_user, v_op.nome, v_me.username, v_op.pts, v_me.rank_pts,
               v_op.elem, v_elem,
               (select array(select unnest(v_op.cartas) order by random())),
               (select array(select unnest(v_cartas)   order by random())),
               (1 + floor(random() * 2))::smallint,
               now() + interval '30 seconds')     -- folga do sorteio de quem comeca
    returning * into v;

  return live_view(v, 2::smallint);
end $$;

-- ---------------------------------------------------------------------
-- 13) match_state — o cliente pergunta o estado (e o relogio corre)
-- ---------------------------------------------------------------------
create or replace function public.match_state()
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v      live_duels%rowtype;
  v_q    record;
begin
  if v_user is null then return json_build_object('error','auth'); end if;

  v := live_minha(v_user);
  if v.id is not null then
    if v.estado = 'ativo' then v := live_avanca(v.id); end if;
    return live_view(v, case when v.p1 = v_user then 1::smallint else 2::smallint end);
  end if;

  select * into v_q from live_queue where user_id = v_user;
  if v_q.user_id is not null then
    return json_build_object('ok', true, 'estado', 'fila',
                             'espera', extract(epoch from (now() - v_q.entrou_em))::int);
  end if;

  return json_build_object('ok', true, 'estado', 'nada');
end $$;

-- ---------------------------------------------------------------------
-- 14) match_play — registra a minha carta
-- ---------------------------------------------------------------------
create or replace function public.match_play(p_rodada smallint, p_fase text, p_carta smallint)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v      live_duels%rowtype;
  v_slot smallint;
begin
  if v_user is null then return json_build_object('error','auth'); end if;

  v := live_minha(v_user);
  if v.id is null then return json_build_object('error','sem_partida'); end if;
  v_slot := case when v.p1 = v_user then 1 else 2 end;

  if v.estado = 'ativo' then v := live_avanca(v.id); end if;
  if v.estado <> 'ativo' then return live_view(v, v_slot); end if;

  -- a jogada tem que ser da rodada e da fase que estao valendo agora
  if v.rodada <> p_rodada or v.fase <> p_fase then
    return json_build_object('error','fora_de_hora', 'estado_atual', live_view(v, v_slot));
  end if;
  if live_turno(v.starter, v.rodada, v.fase) <> v_slot then
    return json_build_object('error','nao_e_sua_vez', 'estado_atual', live_view(v, v_slot));
  end if;
  if not live_livre(v.jogadas, v.rodada, v_slot, p_carta) then
    return json_build_object('error','carta_invalida');
  end if;

  update live_duels
     set jogadas = jogadas || jsonb_build_object('r', v.rodada, 'f', v.fase, 's', v_slot, 'c', p_carta),
         fase    = case when v.fase = 'atk' then 'def' else 'atk' end,
         rodada  = case when v.fase = 'atk' then v.rodada else (v.rodada + 1)::smallint end,
         faltas1 = case when v_slot = 1 then 0::smallint else faltas1 end,
         faltas2 = case when v_slot = 2 then 0::smallint else faltas2 end,
         prazo   = case when v.fase = 'def' and v.rodada >= 7 then null
                        else now() + interval '22 seconds' end
   where id = v.id
   returning * into v;

  return live_view(v, v_slot);
end $$;

-- ---------------------------------------------------------------------
-- 15) match_report — placar final, conferido nos dois lados
-- ---------------------------------------------------------------------
create or replace function public.match_report(p_minha smallint, p_dele smallint)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v      live_duels%rowtype;
  v_slot smallint;
  v_v1   smallint; v_v2 smallint;
begin
  if v_user is null then return json_build_object('error','auth'); end if;
  if p_minha is null or p_dele is null
     or p_minha < 0 or p_minha > 20 or p_dele < 0 or p_dele > 20 then
    return json_build_object('error','placar_invalido');
  end if;

  v := live_minha(v_user);
  if v.id is null then return json_build_object('error','sem_partida'); end if;
  v_slot := case when v.p1 = v_user then 1 else 2 end;
  if v.estado <> 'ativo' then return live_view(v, v_slot); end if;

  -- duelo nenhum acaba antes de duas rodadas inteiras
  if jsonb_array_length(v.jogadas) < 4 then
    return json_build_object('error','cedo_demais');
  end if;

  if v_slot = 1 then v_v1 := p_minha; v_v2 := p_dele;
                else v_v1 := p_dele;  v_v2 := p_minha; end if;

  update live_duels
     set rep1 = case when v_slot = 1 then array[v_v1, v_v2] else rep1 end,
         rep2 = case when v_slot = 2 then array[v_v1, v_v2] else rep2 end,
         rep1_em = case when v_slot = 1 then now() else rep1_em end,
         rep2_em = case when v_slot = 2 then now() else rep2_em end
   where id = v.id;

  v := live_avanca(v.id);
  return live_view(v, v_slot);
end $$;

-- ---------------------------------------------------------------------
-- 16) match_leave — sai da fila, ou desiste da partida (derrota na hora)
-- ---------------------------------------------------------------------
create or replace function public.match_leave()
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v      live_duels%rowtype;
  v_slot smallint;
begin
  if v_user is null then return json_build_object('error','auth'); end if;

  delete from live_queue where user_id = v_user;

  v := live_minha(v_user);
  if v.id is not null and v.estado = 'ativo' then
    v_slot := case when v.p1 = v_user then 1 else 2 end;
    perform live_paga(v.id, (3 - v_slot)::smallint, 'wo');
    select * into v from live_duels where id = v.id;
    return live_view(v, v_slot);
  end if;

  return json_build_object('ok', true, 'estado', 'nada');
end $$;

-- ---------------------------------------------------------------------
-- 17) Missoes novas do Duelo ao Vivo
-- ---------------------------------------------------------------------
insert into public.mission_defs (slug, grupo, titulo, descr, tipo, alvo, ouro, gemas, essencia) values
  ('duelo-ao-vivo', 'extra', 'Cara a Cara',      'Dispute 2 Duelos ao Vivo',        'vivo',     2, 120, 1, 0),
  ('vivo-vitoria',  'extra', 'Melhor dos Dois',  'Vença 1 Duelo ao Vivo',           'vivo_vit', 1, 160, 1, 0)
on conflict (slug) do update
   set grupo = excluded.grupo, titulo = excluded.titulo, descr = excluded.descr,
       tipo  = excluded.tipo,  alvo   = excluded.alvo,
       ouro  = excluded.ouro,  gemas  = excluded.gemas, essencia = excluded.essencia;

-- ---------------------------------------------------------------------
-- 18) Permissoes
--     Internas: nao sao SECURITY DEFINER onde nao precisam ser, e
--     nenhuma delas tem EXECUTE para ninguem (nem para public).
-- ---------------------------------------------------------------------
revoke execute on function public.live_turno(smallint, smallint, text)      from public, anon, authenticated;
revoke execute on function public.live_auto(jsonb, smallint, smallint)      from public, anon, authenticated;
revoke execute on function public.live_livre(jsonb, smallint, smallint, smallint) from public, anon, authenticated;
revoke execute on function public.live_paga(bigint, smallint, text)         from public, anon, authenticated;
revoke execute on function public.live_disputa(bigint)                      from public, anon, authenticated;
revoke execute on function public.live_avanca(bigint)                       from public, anon, authenticated;
revoke execute on function public.live_view(live_duels, smallint)           from public, anon, authenticated;
revoke execute on function public.live_minha(uuid)                          from public, anon, authenticated;

revoke execute on function public.match_find()                              from public, anon, authenticated;
revoke execute on function public.match_state()                             from public, anon, authenticated;
revoke execute on function public.match_play(smallint, text, smallint)      from public, anon, authenticated;
revoke execute on function public.match_report(smallint, smallint)          from public, anon, authenticated;
revoke execute on function public.match_leave()                             from public, anon, authenticated;

grant execute on function public.match_find()                         to authenticated;
grant execute on function public.match_state()                        to authenticated;
grant execute on function public.match_play(smallint, text, smallint) to authenticated;
grant execute on function public.match_report(smallint, smallint)     to authenticated;
grant execute on function public.match_leave()                        to authenticated;
