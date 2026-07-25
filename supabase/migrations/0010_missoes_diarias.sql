-- =====================================================================
-- v0.9 — Missoes Diarias
--
-- Tres missoes por dia, sorteadas pelo servidor (1 do grupo "base" e
-- 2 do grupo "extra"), com um bonus por completar as tres. O sorteio e
-- deterministico a partir de (usuario, dia): nao existe re-roll, nao
-- adianta recarregar a tela.
--
-- O progresso NAO e reportado pelo cliente. Ele e contado dentro das
-- quatro funcoes que ja sao os pontos de estrangulamento do jogo —
-- duel_reward, arena_result, shop_buy e forge_card — logo apos o
-- UPDATE que ja paga o ouro. Se a funcao sair por erro antes disso,
-- nada conta.
--
-- O dia das missoes vira a meia-noite de Brasilia (dia_jogo()), e nao
-- em UTC como o teto diario de duelos. Missoes sao um subsistema
-- fechado — usam so a propria coluna `dia` — entao nao ha conflito.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Catalogo das missoes
-- ---------------------------------------------------------------------
create table if not exists public.mission_defs (
  slug     text primary key,
  grupo    text not null check (grupo in ('base','extra')),
  titulo   text not null,
  descr    text not null,
  tipo     text not null,
  alvo     int  not null check (alvo > 0),
  ouro     int  not null default 0,
  gemas    int  not null default 0,
  essencia int  not null default 0
);

alter table public.mission_defs enable row level security;
-- sem policy: so funcoes SECURITY DEFINER encostam (mesmo padrao de arena_pending)

insert into public.mission_defs (slug, grupo, titulo, descr, tipo, alvo, ouro, gemas, essencia) values
  ('areia',     'base',  'Poeira da Areia',   'Termine 3 duelos',                'duelo',      3,  60, 0,  0),
  ('sangue',    'base',  'Sede de Vitória',   'Vença 2 duelos',                  'vitoria',    2,  80, 0,  0),
  ('honra',     'base',  'Honra na Arena',    'Vença 1 duelo na Arena',          'arena_vit',  1,  90, 0,  0),
  ('escalada',  'extra', 'Escalada',          'Vença 3 duelos na Arena',         'arena_vit',  3, 160, 1,  0),
  ('veterano',  'extra', 'Veterano da Areia', 'Dispute 5 duelos na Arena',       'arena',      5, 120, 0, 20),
  ('conquista', 'extra', 'Conquista',         'Vença 2 duelos na Carreira',      'carreira_vit',2, 90, 0,  0),
  ('feira',     'extra', 'Dia de Feira',      'Compre 1 carta na loja',          'compra',     1,  50, 0, 25),
  ('bigorna',   'extra', 'Bigorna Quente',    'Forje 1 carta',                   'forja',      1, 120, 1,  0),
  ('brasa',     'extra', 'Brasa Viva',        'Vença 1 duelo em Chamalar',       'carr_fogo',  1,  70, 0,  0),
  ('mare',      'extra', 'Maré Alta',         'Vença 1 duelo em Nereida',        'carr_agua',  1,  70, 0,  0),
  ('raiz',      'extra', 'Raiz Profunda',     'Vença 1 duelo em Selvaria',       'carr_nat',   1,  70, 0,  0),
  ('trovao',    'extra', 'Eco do Trovão',     'Vença 1 duelo em Tormenália',     'carr_raio',  1,  70, 0,  0)
on conflict (slug) do update set
  grupo = excluded.grupo, titulo = excluded.titulo, descr = excluded.descr,
  tipo = excluded.tipo, alvo = excluded.alvo,
  ouro = excluded.ouro, gemas = excluded.gemas, essencia = excluded.essencia;

-- ---------------------------------------------------------------------
-- 2) Missoes do jogador (uma linha por conta, reciclada todo dia)
-- ---------------------------------------------------------------------
create table if not exists public.missions (
  user_id uuid primary key references auth.users(id) on delete cascade,
  dia     date      not null,
  slugs   text[]    not null,
  prog    int[]     not null default '{0,0,0}',
  pego    boolean[] not null default '{false,false,false}',
  bonus   boolean   not null default false
);

alter table public.missions enable row level security;
-- sem policy, de novo: o cliente nunca le nem escreve esta tabela direto

-- ---------------------------------------------------------------------
-- 3) dia_jogo — o "hoje" das missoes, no fuso de Brasilia
-- ---------------------------------------------------------------------
create or replace function public.dia_jogo()
returns date
language sql
stable
set search_path = public
as $$ select ((now() at time zone 'America/Sao_Paulo')::date) $$;

-- ---------------------------------------------------------------------
-- 4) missoes_do_dia — sorteio deterministico (usuario + dia + slug)
--    1 do grupo base, 2 do grupo extra. Recarregar a tela nao muda nada.
-- ---------------------------------------------------------------------
create or replace function public.missoes_do_dia(p_user uuid)
returns text[]
language sql
stable
set search_path = public
as $$
  select array(
    select s.slug from (
      (select 1 as o, d.slug from public.mission_defs d where d.grupo = 'base'
        order by md5(p_user::text || public.dia_jogo()::text || d.slug) limit 1)
      union all
      (select 2 as o, d.slug from public.mission_defs d where d.grupo = 'extra'
        order by md5(p_user::text || public.dia_jogo()::text || d.slug) limit 2)
    ) s order by s.o, s.slug
  )
$$;

-- ---------------------------------------------------------------------
-- 5) missoes_hoje — devolve a linha do dia, criando ou reciclando.
--    Interna: nao e SECURITY DEFINER, herda o direito de quem chama.
--    Trava a linha (for update) para serializar coleta e progresso.
-- ---------------------------------------------------------------------
create or replace function public.missoes_hoje(p_user uuid)
returns public.missions
language plpgsql
set search_path = public
as $$
declare v_row public.missions%rowtype; v_dia date := public.dia_jogo();
begin
  select * into v_row from public.missions where user_id = p_user for update;

  if not found then
    insert into public.missions(user_id, dia, slugs)
      values (p_user, v_dia, public.missoes_do_dia(p_user))
      on conflict (user_id) do nothing;
    select * into v_row from public.missions where user_id = p_user for update;
  end if;

  if v_row.dia is distinct from v_dia then
    update public.missions
       set dia   = v_dia,
           slugs = public.missoes_do_dia(p_user),
           prog  = '{0,0,0}',
           pego  = '{false,false,false}',
           bonus = false
     where user_id = p_user
     returning * into v_row;
  end if;

  return v_row;
end $$;

-- ---------------------------------------------------------------------
-- 6) missao_prog — soma progresso do tipo pedido. Interna.
--    O array inteiro e reescrito a partir de uma variavel local: subscrito
--    com variavel plpgsql dentro do UPDATE nao se comporta como parece.
-- ---------------------------------------------------------------------
create or replace function public.missao_prog(p_user uuid, p_tipo text, p_qtd int default 1)
returns void
language plpgsql
set search_path = public
as $$
declare v_row public.missions%rowtype; v_prog int[]; v_alvo int; v_tipo text; i int;
begin
  if p_user is null or p_tipo is null then return; end if;

  v_row  := public.missoes_hoje(p_user);
  v_prog := v_row.prog;

  for i in 1..3 loop
    select d.tipo, d.alvo into v_tipo, v_alvo
      from public.mission_defs d where d.slug = v_row.slugs[i];
    if v_tipo = p_tipo and coalesce(v_prog[i],0) < v_alvo then
      v_prog[i] := least(v_alvo, coalesce(v_prog[i],0) + coalesce(p_qtd,1));
    end if;
  end loop;

  if v_prog is distinct from v_row.prog then
    update public.missions set prog = v_prog where user_id = p_user;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 7) missions_get — o que a tela inicial desenha
-- ---------------------------------------------------------------------
create or replace function public.missions_get()
returns json
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_user uuid := auth.uid(); v_row public.missions%rowtype;
        v_arr json; v_prontas int; v_renova int;
begin
  if v_user is null then return json_build_object('error','auth'); end if;

  v_row := missoes_hoje(v_user);

  select json_agg(json_build_object(
           'i',        t.i,
           'slug',     d.slug,
           'titulo',   d.titulo,
           'descr',    d.descr,
           'alvo',     d.alvo,
           'prog',     least(d.alvo, coalesce(v_row.prog[t.i],0)),
           'ouro',     d.ouro,
           'gemas',    d.gemas,
           'essencia', d.essencia,
           'pego',     coalesce(v_row.pego[t.i], false),
           'pronta',   (coalesce(v_row.prog[t.i],0) >= d.alvo and not coalesce(v_row.pego[t.i],false))
         ) order by t.i),
         count(*) filter (where coalesce(v_row.prog[t.i],0) >= d.alvo and not coalesce(v_row.pego[t.i],false))
    into v_arr, v_prontas
    from generate_series(1,3) as t(i)
    join mission_defs d on d.slug = v_row.slugs[t.i];

  v_renova := greatest(0, extract(epoch from
                (((dia_jogo() + 1)::timestamp at time zone 'America/Sao_Paulo') - now()))::int);

  return json_build_object(
    'ok', true,
    'missoes', coalesce(v_arr, '[]'::json),
    'prontas', coalesce(v_prontas, 0),
    'bonus_pego', v_row.bonus,
    'bonus_pronto', (v_row.pego[1] and v_row.pego[2] and v_row.pego[3] and not v_row.bonus),
    'bonus_ouro', 100,
    'bonus_gemas', 2,
    'renova_em', v_renova
  );
end $$;

-- ---------------------------------------------------------------------
-- 8) missions_claim — 1..3 paga a missao, 4 paga o bonus das tres.
--    Trava profiles antes de missions: mesma ordem de travas das outras
--    funcoes (profiles -> missions), senao daria para travar em cruz.
-- ---------------------------------------------------------------------
create or replace function public.missions_claim(p_idx int)
returns json
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_user uuid := auth.uid(); v_row public.missions%rowtype;
        v_d public.mission_defs%rowtype; v_pego boolean[];
        v_g_ouro int; v_g_gemas int; v_g_ess int;
        v_ouro int; v_gemas int; v_ess int;
begin
  if v_user is null then return json_build_object('error','auth'); end if;
  if p_idx is null or p_idx < 1 or p_idx > 4 then return json_build_object('error','indice'); end if;

  perform 1 from profiles where id = v_user for update;
  v_row := missoes_hoje(v_user);

  if p_idx = 4 then
    if v_row.bonus then return json_build_object('error','ja_pego'); end if;
    if not (coalesce(v_row.pego[1],false) and coalesce(v_row.pego[2],false)
            and coalesce(v_row.pego[3],false)) then
      return json_build_object('error','incompleto');
    end if;
    v_g_ouro := 100; v_g_gemas := 2; v_g_ess := 0;
    update missions set bonus = true where user_id = v_user;
  else
    if coalesce(v_row.pego[p_idx], false) then return json_build_object('error','ja_pego'); end if;
    select * into v_d from mission_defs where slug = v_row.slugs[p_idx];
    if v_d.slug is null then return json_build_object('error','indice'); end if;
    if coalesce(v_row.prog[p_idx],0) < v_d.alvo then return json_build_object('error','incompleta'); end if;
    v_g_ouro := v_d.ouro; v_g_gemas := v_d.gemas; v_g_ess := v_d.essencia;
    v_pego := v_row.pego; v_pego[p_idx] := true;
    update missions set pego = v_pego where user_id = v_user;
  end if;

  update profiles
     set ouro     = ouro     + v_g_ouro,
         gemas    = gemas    + v_g_gemas,
         essencia = essencia + v_g_ess
   where id = v_user
   returning ouro, gemas, essencia into v_ouro, v_gemas, v_ess;

  return json_build_object('ok', true, 'idx', p_idx,
    'ganho_ouro', v_g_ouro, 'ganho_gemas', v_g_gemas, 'ganho_essencia', v_g_ess,
    'ouro', v_ouro, 'gemas', v_gemas, 'essencia', v_ess);
end $$;

-- =====================================================================
-- 9) Os quatro ganchos. Cada funcao e reescrita inteira, com o corpo
--    de antes intacto e as chamadas de missao logo depois do UPDATE
--    que paga — nunca antes, para nada contar em caminho de erro.
-- =====================================================================

-- ---- duelo (Carreira, Torre, treino) --------------------------------
create or replace function public.duel_reward(p_win boolean, p_elem text default null)
returns json
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_user uuid := auth.uid(); v_ganho int; v_ouro int;
        v_last timestamptz; v_dia date; v_qtd int;
        v_st int; v_slug text; v_estagio int;
begin
  if v_user is null then return json_build_object('error','auth'); end if;

  select duel_last, duel_dia, duel_qtd into v_last, v_dia, v_qtd
    from profiles where id = v_user for update;

  -- nenhum duelo de 4 rodadas termina em menos de 12 segundos
  if v_last is not null and now() - v_last < interval '12 seconds' then
    return json_build_object('error','muito_rapido');
  end if;

  if v_dia = current_date then
    if v_qtd >= 100 then return json_build_object('error','limite_diario'); end if;
    v_qtd := v_qtd + 1;
  else
    v_dia := current_date; v_qtd := 1;
  end if;

  v_ganho := case when p_win then 30 else 10 end;

  -- estagio da Carreira, quando o duelo vencido veio de um continente
  if p_win and p_elem in ('fogo','agua','nat','raio') then
    insert into career_progress(user_id, elemento, estagios) values (v_user, p_elem, 0)
      on conflict (user_id, elemento) do nothing;
    select estagios into v_st from career_progress where user_id = v_user and elemento = p_elem;
    if v_st < 11 then
      select slug into v_slug from (
        select slug, row_number() over (order by ordem) - 1 as idx
          from cards where elemento = p_elem
      ) x where x.idx = v_st;
      if v_slug is not null then
        perform grant_card(v_user, v_slug);
        update career_progress set estagios = estagios + 1
         where user_id = v_user and elemento = p_elem;
        v_estagio := v_st + 1;
        v_ganho := v_ganho + 25;
      end if;
    end if;
  end if;

  update profiles
     set ouro = ouro + v_ganho, duel_last = now(), duel_dia = v_dia, duel_qtd = v_qtd
   where id = v_user;
  select ouro into v_ouro from profiles where id = v_user;

  -- missoes do dia
  perform missao_prog(v_user, 'duelo');
  if p_win then
    perform missao_prog(v_user, 'vitoria');
    if p_elem in ('fogo','agua','nat','raio') then
      perform missao_prog(v_user, 'carreira_vit');
      perform missao_prog(v_user, 'carr_' || p_elem);
    end if;
  end if;

  return json_build_object('ok', true, 'ganho', v_ganho, 'ouro', v_ouro,
                           'slug', v_slug, 'estagio', v_estagio);
end $$;

-- ---- Arena ----------------------------------------------------------
create or replace function public.arena_result(p_win boolean)
returns json
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_user uuid := auth.uid();
  v_my int; v_dia date; v_qtd int; v_last timestamptz;
  v_foe_nome text; v_foe_elem text; v_foe_pts int; v_criado timestamptz;
  v_diff int; v_delta int; v_gold int;
  v_ouro int; v_v int; v_d int;
begin
  if v_user is null then return json_build_object('error','auth'); end if;

  select foe_nome, foe_elem, foe_pts, criado_em
    into v_foe_nome, v_foe_elem, v_foe_pts, v_criado
    from arena_pending where user_id = v_user for update;
  if not found then return json_build_object('error','sem_partida'); end if;

  -- nenhum duelo de 4 rodadas termina em menos de 12 segundos
  if now() - v_criado < interval '12 seconds' then
    return json_build_object('error','muito_rapido');
  end if;
  -- pareamento velho demais: obriga a procurar de novo
  if now() - v_criado > interval '30 minutes' then
    delete from arena_pending where user_id = v_user;
    return json_build_object('error','expirado');
  end if;

  select rank_pts, duel_dia, duel_qtd, duel_last
    into v_my, v_dia, v_qtd, v_last
    from profiles where id = v_user for update;

  if v_dia = current_date then
    if v_qtd >= 100 then return json_build_object('error','limite_diario'); end if;
    v_qtd := v_qtd + 1;
  else
    v_dia := current_date; v_qtd := 1;
  end if;

  -- ganha mais contra quem esta acima; perde menos contra quem esta acima
  v_diff := greatest(-400, least(400, v_foe_pts - v_my));
  if p_win then
    v_delta := 25 + (v_diff / 40);   -- 15 a 35
    v_gold  := 40;
  else
    v_delta := -(15 - (v_diff / 50)); -- -7 a -23
    v_gold  := 12;
  end if;

  update profiles
     set rank_pts  = greatest(0, rank_pts + v_delta),
         ouro      = ouro + v_gold,
         vitorias  = vitorias + case when p_win then 1 else 0 end,
         derrotas  = derrotas + case when p_win then 0 else 1 end,
         duel_last = now(), duel_dia = v_dia, duel_qtd = v_qtd
   where id = v_user;

  insert into matches(user_id, foe_nome, foe_elem, venceu, pts)
       values (v_user, v_foe_nome, v_foe_elem, p_win, v_delta);

  delete from arena_pending where user_id = v_user;

  -- missoes do dia
  perform missao_prog(v_user, 'duelo');
  perform missao_prog(v_user, 'arena');
  if p_win then
    perform missao_prog(v_user, 'vitoria');
    perform missao_prog(v_user, 'arena_vit');
  end if;

  select rank_pts, ouro, vitorias, derrotas into v_my, v_ouro, v_v, v_d
    from profiles where id = v_user;

  return json_build_object('ok', true, 'pts', v_delta, 'ouro', v_ouro,
                           'ganho', v_gold, 'rank_pts', v_my, 'liga', liga(v_my),
                           'vitorias', v_v, 'derrotas', v_d, 'foe', v_foe_nome);
end $$;

-- ---- loja -----------------------------------------------------------
create or replace function public.shop_buy(p_slug text)
returns json language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); v_row public.daily_shop%rowtype; v_rar text; v_preco int; v_ouro int; v_ess int;
begin
  if v_user is null then return json_build_object('error','auth'); end if;
  select * into v_row from daily_shop where user_id = v_user;
  if v_row.user_id is null or not (p_slug = any(v_row.cartas)) then return json_build_object('error','fora_da_loja'); end if;
  if p_slug = any(v_row.comprados) then return json_build_object('error','ja_comprado'); end if;
  select raridade into v_rar from cards where slug = p_slug;
  v_preco := preco_loja(v_rar);
  select ouro into v_ouro from profiles where id = v_user;
  if v_ouro < v_preco then return json_build_object('error','sem_ouro','preco',v_preco); end if;
  update profiles set ouro = ouro - v_preco where id = v_user;
  perform grant_card(v_user, p_slug);
  update daily_shop set comprados = array_append(comprados, p_slug) where user_id = v_user;
  perform missao_prog(v_user, 'compra');
  select ouro, essencia into v_ouro, v_ess from profiles where id = v_user;
  return json_build_object('ok', true, 'slug', p_slug, 'ouro', v_ouro, 'essencia', v_ess);
end $$;

-- ---- forja ----------------------------------------------------------
create or replace function public.forge_card(p_slug text)
returns json language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); v_rar text; v_custo int; v_ess int;
begin
  if v_user is null then return json_build_object('error','auth'); end if;
  select raridade into v_rar from cards where slug = p_slug;
  if v_rar is null then return json_build_object('error','invalida'); end if;
  if exists(select 1 from collection where user_id = v_user and card_slug = p_slug) then
    return json_build_object('error','ja_possui');
  end if;
  v_custo := custo_forja(v_rar);
  select essencia into v_ess from profiles where id = v_user;
  if v_ess < v_custo then return json_build_object('error','sem_essencia','custo',v_custo); end if;
  update profiles set essencia = essencia - v_custo where id = v_user;
  insert into collection(user_id, card_slug, qtd) values (v_user, p_slug, 1);
  perform missao_prog(v_user, 'forja');
  select essencia into v_ess from profiles where id = v_user;
  return json_build_object('ok', true, 'slug', p_slug, 'essencia', v_ess);
end $$;

-- =====================================================================
-- 10) Permissoes. Lembrando a pegadinha: EXECUTE ja vem concedido a
--     PUBLIC, entao revogar so de anon/authenticated nao adianta nada.
-- =====================================================================
revoke all on table public.missions     from public, anon, authenticated;
revoke all on table public.mission_defs from public, anon, authenticated;

revoke execute on function public.dia_jogo()                          from public, anon, authenticated;
revoke execute on function public.missoes_do_dia(uuid)                from public, anon, authenticated;
revoke execute on function public.missoes_hoje(uuid)                  from public, anon, authenticated;
revoke execute on function public.missao_prog(uuid, text, int)        from public, anon, authenticated;

revoke execute on function public.missions_get()      from public, anon, authenticated;
revoke execute on function public.missions_claim(int) from public, anon, authenticated;
grant  execute on function public.missions_get()      to authenticated;
grant  execute on function public.missions_claim(int) to authenticated;
