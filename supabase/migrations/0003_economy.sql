-- Valdória — economia v2: essência, loja diária, carreira, forja, recompensa diária
-- Tudo via RPC SECURITY DEFINER sobre auth.uid(); cliente nunca escreve moeda/coleção direto.

-- ============ profiles: essência + recompensa diária ============
alter table public.profiles add column if not exists essencia     int  not null default 0;
alter table public.profiles add column if not exists daily_last    date;
alter table public.profiles add column if not exists daily_streak  int  not null default 0;

-- ============ loja diária ============
create table if not exists public.daily_shop (
  user_id   uuid primary key references auth.users(id) on delete cascade,
  gerado_em timestamptz not null default now(),
  cartas    text[] not null,
  comprados text[] not null default '{}'
);
alter table public.daily_shop enable row level security;
create policy "shop_owner_read" on public.daily_shop for select using (auth.uid() = user_id);

-- ============ progresso de carreira ============
create table if not exists public.career_progress (
  user_id  uuid not null references auth.users(id) on delete cascade,
  elemento text not null check (elemento in ('fogo','agua','nat','raio')),
  estagios int  not null default 0,
  primary key (user_id, elemento)
);
alter table public.career_progress enable row level security;
create policy "career_owner_read" on public.career_progress for select using (auth.uid() = user_id);

-- ============ constantes (preços/custos) ============
create or replace function public.preco_loja(r text) returns int language sql immutable as
$$ select case r when 'comum' then 40 when 'incomum' then 120 when 'rara' then 350 when 'epica' then 900 else 999999 end $$;
create or replace function public.valor_essencia(r text) returns int language sql immutable as
$$ select case r when 'comum' then 5 when 'incomum' then 15 when 'rara' then 50 when 'epica' then 150 else 0 end $$;
create or replace function public.custo_forja(r text) returns int language sql immutable as
$$ select case r when 'comum' then 40 when 'incomum' then 120 when 'rara' then 400 when 'epica' then 1000 else 999999 end $$;

-- ============ grant_card: dá a carta; se já possui, vira Essência ============
create or replace function public.grant_card(p_user uuid, p_slug text)
returns text language plpgsql security definer set search_path = public as $$
declare v_rar text; v_has boolean;
begin
  select raridade into v_rar from cards where slug = p_slug;
  if v_rar is null then return 'invalid'; end if;
  select exists(select 1 from collection where user_id = p_user and card_slug = p_slug) into v_has;
  if v_has then
    update collection set qtd = qtd + 1 where user_id = p_user and card_slug = p_slug;
    update profiles set essencia = essencia + valor_essencia(v_rar) where id = p_user;
    return 'dup';
  else
    insert into collection(user_id, card_slug, qtd) values (p_user, p_slug, 1);
    return 'new';
  end if;
end $$;
revoke execute on function public.grant_card(uuid, text) from public, anon, authenticated;

-- ============ state_get: hidrata o cliente (perfil + coleção + deck + carreira) ============
create or replace function public.state_get()
returns json language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null then return json_build_object('error','auth'); end if;
  return json_build_object(
    'perfil',  (select row_to_json(p) from (select username, ouro, gemas, essencia, nivel, rank_pts from profiles where id = v_user) p),
    'colecao', (select coalesce(json_agg(json_build_object('slug', card_slug, 'qtd', qtd)), '[]'::json) from collection where user_id = v_user),
    'deck',    (select cartas from decks where user_id = v_user and ativo order by updated_at desc limit 1),
    'carreira',(select coalesce(json_object_agg(elemento, estagios), '{}'::json) from career_progress where user_id = v_user)
  );
end $$;

-- ============ loja: get (gera se >24h) ============
create or replace function public.shop_get()
returns json language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); v_row public.daily_shop%rowtype; v_new text[];
begin
  if v_user is null then return json_build_object('error','auth'); end if;
  select * into v_row from daily_shop where user_id = v_user;
  if v_row.user_id is null or (now() - v_row.gerado_em) >= interval '24 hours' then
    select array_agg(slug) into v_new from (
      select slug from cards
      order by (case when slug in (select card_slug from collection where user_id = v_user) then 1 else 0 end), random()
      limit 6
    ) s;
    insert into daily_shop(user_id, gerado_em, cartas, comprados) values (v_user, now(), v_new, '{}')
      on conflict (user_id) do update set gerado_em = now(), cartas = v_new, comprados = '{}';
    select * into v_row from daily_shop where user_id = v_user;
  end if;
  return json_build_object(
    'cartas', (select json_agg(json_build_object(
       'slug', c.slug, 'nome', c.nome, 'elemento', c.elemento, 'raridade', c.raridade,
       'custo', c.custo, 'atk', c.atk, 'def', c.def,
       'preco', preco_loja(c.raridade), 'comprado', c.slug = any(v_row.comprados)
     ) order by array_position(v_row.cartas, c.slug)) from cards c where c.slug = any(v_row.cartas)),
    'renova_em', greatest(0, 86400 - floor(extract(epoch from (now() - v_row.gerado_em)))::int)
  );
end $$;

-- ============ loja: comprar ============
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
  select ouro, essencia into v_ouro, v_ess from profiles where id = v_user;
  return json_build_object('ok', true, 'slug', p_slug, 'ouro', v_ouro, 'essencia', v_ess);
end $$;

-- ============ forja: gastar Essência para criar carta que falta ============
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
  select essencia into v_ess from profiles where id = v_user;
  return json_build_object('ok', true, 'slug', p_slug, 'essencia', v_ess);
end $$;

-- ============ carreira: vencer estágio -> carta específica + ouro ============
-- Ordem por elemento: 0..5 comuns, 6..9 incomuns, 10 = 1ª rara (chefe). 11 estágios por continente.
create or replace function public.career_claim(p_elem text)
returns json language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); v_st int; v_slug text; v_ouro int;
begin
  if v_user is null then return json_build_object('error','auth'); end if;
  if p_elem not in ('fogo','agua','nat','raio') then return json_build_object('error','elem'); end if;
  insert into career_progress(user_id, elemento, estagios) values (v_user, p_elem, 0)
    on conflict (user_id, elemento) do nothing;
  select estagios into v_st from career_progress where user_id = v_user and elemento = p_elem;
  if v_st >= 11 then return json_build_object('error','completo'); end if;
  -- carta do estágio v_st (0-based) na ordem do elemento
  select slug into v_slug from (
    select slug, row_number() over (order by ordem) - 1 as idx
    from cards where elemento = p_elem
  ) x where x.idx = v_st;
  perform grant_card(v_user, v_slug);
  update career_progress set estagios = estagios + 1 where user_id = v_user and elemento = p_elem;
  update profiles set ouro = ouro + 25 where id = v_user;
  select ouro into v_ouro from profiles where id = v_user;
  return json_build_object('ok', true, 'slug', v_slug, 'estagio', v_st + 1, 'ouro', v_ouro);
end $$;

-- ============ recompensa diária (crescente) ============
create or replace function public.daily_claim()
returns json language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); v_last date; v_streak int; v_ganho int; v_ouro int;
begin
  if v_user is null then return json_build_object('error','auth'); end if;
  select daily_last, daily_streak into v_last, v_streak from profiles where id = v_user;
  if v_last = current_date then return json_build_object('error','ja_coletou'); end if;
  if v_last = current_date - 1 then v_streak := v_streak + 1; else v_streak := 1; end if;
  v_ganho := least(50 + (v_streak - 1) * 10, 150);
  update profiles set ouro = ouro + v_ganho, daily_last = current_date, daily_streak = v_streak where id = v_user;
  select ouro into v_ouro from profiles where id = v_user;
  return json_build_object('ok', true, 'ganho', v_ganho, 'streak', v_streak, 'ouro', v_ouro);
end $$;

-- ============ recompensa de duelo ============
create or replace function public.duel_reward(p_win boolean)
returns json language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); v_ganho int; v_ouro int;
begin
  if v_user is null then return json_build_object('error','auth'); end if;
  v_ganho := case when p_win then 30 else 10 end;
  update profiles set ouro = ouro + v_ganho where id = v_user;
  select ouro into v_ouro from profiles where id = v_user;
  return json_build_object('ok', true, 'ganho', v_ganho, 'ouro', v_ouro);
end $$;

-- ============ trigger de cadastro: PACK DE INTRODUÇÃO (1R + 4I + 5C, >=1 por elemento) ============
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare starter text[];
begin
  insert into public.profiles (id, username)
  values (new.id, coalesce(new.raw_user_meta_data->>'username', split_part(new.email,'@',1)));

  -- 4 comuns (uma de cada elemento)
  insert into public.collection(user_id, card_slug, qtd)
  select new.id, s.slug, 1 from (
    select distinct on (elemento) slug from public.cards where raridade = 'comum' order by elemento, random()
  ) s;
  -- +1 comum extra
  insert into public.collection(user_id, card_slug, qtd)
  select new.id, slug, 1 from public.cards
   where raridade = 'comum' and slug not in (select card_slug from public.collection where user_id = new.id)
   order by random() limit 1;
  -- 4 incomuns (uma de cada elemento)
  insert into public.collection(user_id, card_slug, qtd)
  select new.id, s.slug, 1 from (
    select distinct on (elemento) slug from public.cards where raridade = 'incomum' order by elemento, random()
  ) s;
  -- 1 rara
  insert into public.collection(user_id, card_slug, qtd)
  select new.id, slug, 1 from public.cards where raridade = 'rara' order by random() limit 1;

  -- deck inicial: 8 de menor custo entre as 10 do pack
  select array_agg(slug) into starter from (
    select c.card_slug as slug from public.collection c join public.cards ca on ca.slug = c.card_slug
    where c.user_id = new.id order by ca.custo asc, random() limit 8
  ) x;
  insert into public.decks(user_id, nome, cartas, ativo)
  values (new.id, 'Deck Inicial', coalesce(starter, '{}'), true);

  return new;
end $$;
revoke execute on function public.handle_new_user() from public, anon, authenticated;
