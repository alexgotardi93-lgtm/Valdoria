-- =====================================================================
-- v0.8 — ARENA ASSINCRONA, RANKING REAL E HISTORICO
--
-- A Arena nao usa socket: voce enfrenta o deck salvo de outro jogador
-- (um "espelho"), controlado pela mesma IA do duelo. Quando ainda nao ha
-- ninguem na sua faixa de pontos, entra um gladiador da guilda (PNJ).
--
-- Regra anti-trapaca: quem escolhe o adversario e o SERVIDOR. O
-- arena_find grava a partida pendente (quem e, quantos pontos vale) e o
-- arena_result so paga em cima dessa linha. O cliente nao consegue
-- inventar oponente, nem inflar os pontos, nem pedir premio sem procurar.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Estatisticas do gladiador
-- ---------------------------------------------------------------------
alter table public.profiles
  add column if not exists vitorias int not null default 0,
  add column if not exists derrotas int not null default 0;

-- ---------------------------------------------------------------------
-- 2) Ligas por pontos
-- ---------------------------------------------------------------------
create or replace function public.liga(p int)
returns text language sql immutable set search_path to 'public' as $$
  select case
    when p >= 2500 then 'Lenda'
    when p >= 1800 then 'Diamante'
    when p >= 1200 then 'Platina'
    when p >=  700 then 'Ouro'
    when p >=  300 then 'Prata'
    else                'Bronze'
  end;
$$;

-- ---------------------------------------------------------------------
-- 3) Historico de duelos (aparece no Perfil)
-- ---------------------------------------------------------------------
create table if not exists public.matches (
  id        bigint generated always as identity primary key,
  user_id   uuid not null references auth.users(id) on delete cascade,
  foe_nome  text not null,
  foe_elem  text,
  venceu    boolean not null,
  pts       int not null default 0,
  criado_em timestamptz not null default now()
);
create index if not exists matches_user_idx on public.matches(user_id, criado_em desc);

alter table public.matches enable row level security;
drop policy if exists matches_owner_read on public.matches;
create policy matches_owner_read on public.matches
  for select using (auth.uid() = user_id);

revoke all on public.matches from anon, authenticated;
grant select on public.matches to authenticated;

-- ---------------------------------------------------------------------
-- 4) Partida pendente: o servidor lembra contra quem voce foi pareado
-- ---------------------------------------------------------------------
create table if not exists public.arena_pending (
  user_id   uuid primary key references auth.users(id) on delete cascade,
  foe_id    uuid,
  foe_nome  text not null,
  foe_elem  text,
  foe_pts   int not null default 0,
  criado_em timestamptz not null default now()
);
alter table public.arena_pending enable row level security;
-- sem policy nenhuma: ninguem le nem escreve pelo REST, so as funcoes abaixo
revoke all on public.arena_pending from anon, authenticated;

-- ---------------------------------------------------------------------
-- 5) arena_find — o servidor escolhe o adversario
-- ---------------------------------------------------------------------
create or replace function public.arena_find()
returns json
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_user uuid := auth.uid();
  v_my   int;
  v_id   uuid; v_nome text; v_pts int; v_cartas text[]; v_elem text;
  v_bot  boolean := false;
  NOMES  text[] := array[
    'Brasa Errante','Vigília de Ferro','Marechal Grisalho','Oráculo de Sal',
    'Punho de Basalto','Vento Rachado','Lâmina Cinzenta','Guardião do Vau',
    'Corvo de Bronze','Serpente de Névoa','Filho da Tempestade','Raiz Antiga',
    'Cinza Silente','Maré Torta','Trovão Mudo','Espinho do Norte',
    'Chama Cega','Onda Rasa','Sábio das Dunas','Berro do Vale',
    'Ferrão Dourado','Casco Partido','Musgo Velho','Faísca Perdida'];
  ELEMS  text[] := array['fogo','agua','nat','raio'];
begin
  if v_user is null then return json_build_object('error','auth'); end if;
  select rank_pts into v_my from profiles where id = v_user;
  if v_my is null then return json_build_object('error','sem_perfil'); end if;

  -- recorta os 12 jogadores de pontuacao mais proxima com deck valido
  -- e sorteia um deles, para nao cair sempre no mesmo adversario
  select y.id, y.username, y.rank_pts, y.cartas
    into v_id, v_nome, v_pts, v_cartas
  from (
    select w.* from (
      select p.id, p.username, p.rank_pts,
             (select d.cartas from decks d
               where d.user_id = p.id and d.ativo
               order by d.updated_at desc limit 1) as cartas
        from profiles p
       where p.id <> v_user and p.username is not null
    ) w
    where w.cartas is not null and array_length(w.cartas, 1) = 8
    order by abs(w.rank_pts - v_my) asc
    limit 12
  ) y
  order by random() limit 1;

  if v_id is null then
    -- ninguem na arena ainda: entra um gladiador da guilda
    v_bot  := true;
    v_nome := NOMES[1 + floor(random() * array_length(NOMES,1))::int];
    v_elem := ELEMS[1 + floor(random() * 4)::int];
    v_pts  := greatest(0, v_my + (random() * 240)::int - 120);
    v_cartas := null;
  else
    select c.elemento into v_elem
      from cards c where c.slug = any(v_cartas)
     group by c.elemento order by count(*) desc, c.elemento limit 1;
  end if;

  insert into arena_pending(user_id, foe_id, foe_nome, foe_elem, foe_pts, criado_em)
       values (v_user, v_id, v_nome, v_elem, v_pts, now())
  on conflict (user_id) do update
     set foe_id = excluded.foe_id, foe_nome = excluded.foe_nome,
         foe_elem = excluded.foe_elem, foe_pts = excluded.foe_pts,
         criado_em = excluded.criado_em;

  return json_build_object('ok', true, 'bot', v_bot, 'nome', v_nome,
                           'elem', v_elem, 'pts', v_pts, 'liga', liga(v_pts),
                           'cartas', v_cartas, 'meus_pts', v_my, 'minha_liga', liga(v_my));
end $$;

-- ---------------------------------------------------------------------
-- 6) arena_result — paga em cima da partida pendente
--    Mesmo limite de ritmo do duel_reward (colunas duel_last/dia/qtd),
--    entao nao da para alternar as duas RPCs para farmar em dobro.
-- ---------------------------------------------------------------------
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

  select rank_pts, ouro, vitorias, derrotas into v_my, v_ouro, v_v, v_d
    from profiles where id = v_user;

  return json_build_object('ok', true, 'pts', v_delta, 'ouro', v_ouro,
                           'ganho', v_gold, 'rank_pts', v_my, 'liga', liga(v_my),
                           'vitorias', v_v, 'derrotas', v_d, 'foe', v_foe_nome);
end $$;

-- ---------------------------------------------------------------------
-- 7) ranking_top — so nome, pontos e vitorias. Nada de e-mail nem ouro.
-- ---------------------------------------------------------------------
create or replace function public.ranking_top()
returns json
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_user uuid := auth.uid();
begin
  return json_build_object(
    'top', (
      select coalesce(json_agg(t order by t.pos), '[]'::json) from (
        select row_number() over (order by rank_pts desc, vitorias desc, username) as pos,
               username as nome, rank_pts as pts, liga(rank_pts) as liga, vitorias
          from profiles where username is not null
         order by rank_pts desc, vitorias desc, username
         limit 50) t),
    'eu', (
      select json_build_object('pos', z.pos, 'nome', z.nome, 'pts', z.pts,
                               'liga', z.liga, 'vitorias', z.vitorias, 'derrotas', z.derrotas)
        from (select row_number() over (order by rank_pts desc, vitorias desc, username) as pos,
                     id, username as nome, rank_pts as pts, liga(rank_pts) as liga,
                     vitorias, derrotas
                from profiles where username is not null) z
       where z.id = v_user)
  );
end $$;

-- ---------------------------------------------------------------------
-- 8) state_get passa a trazer vitorias, derrotas e liga
-- ---------------------------------------------------------------------
create or replace function public.state_get()
returns json
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null then return json_build_object('error','auth'); end if;
  return json_build_object(
    'perfil',  (select row_to_json(p) from (
                  select username, ouro, gemas, essencia, nivel, rank_pts,
                         vitorias, derrotas, liga(rank_pts) as liga
                    from profiles where id = v_user) p),
    'colecao', (select coalesce(json_agg(json_build_object('slug', card_slug, 'qtd', qtd)), '[]'::json)
                  from collection where user_id = v_user),
    'deck',    (select cartas from decks where user_id = v_user and ativo
                 order by updated_at desc limit 1),
    'carreira',(select coalesce(json_object_agg(elemento, estagios), '{}'::json)
                  from career_progress where user_id = v_user)
  );
end $$;

-- ---------------------------------------------------------------------
-- 9) Grants de EXECUTE explicitos (o Postgres da EXECUTE a PUBLIC sozinho)
-- ---------------------------------------------------------------------
revoke execute on function public.arena_find()          from public, anon, authenticated;
revoke execute on function public.arena_result(boolean) from public, anon, authenticated;
revoke execute on function public.ranking_top()         from public, anon, authenticated;
revoke execute on function public.liga(int)             from public, anon, authenticated;
revoke execute on function public.state_get()           from public, anon, authenticated;

grant execute on function public.arena_find()          to authenticated;
grant execute on function public.arena_result(boolean) to authenticated;
grant execute on function public.ranking_top()         to authenticated;
grant execute on function public.state_get()           to authenticated;
-- liga() fica interna: so as funcoes SECURITY DEFINER acima a usam

-- higiene: as funcoes puras de tabela de precos tambem eram chamaveis por
-- PUBLIC (heranca do padrao do Postgres). Nenhuma delas precisa ser publica.
revoke execute on function public.valor_essencia(text) from public, anon, authenticated;
revoke execute on function public.custo_forja(text)    from public, anon, authenticated;
revoke execute on function public.preco_loja(text)     from public, anon, authenticated;
