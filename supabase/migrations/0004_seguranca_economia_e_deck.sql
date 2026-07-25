-- =====================================================================
-- v0.7 — blindagem do servidor  (aplicada: 20260725015751)
-- O repositorio e publico e a chave publishable esta no cliente, entao
-- toda regra de economia precisa valer no banco, nao no JavaScript.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) PROFILES: o cliente so pode mudar o proprio username.
--    ouro / gemas / essencia / nivel / rank_pts / daily_* passam a ser
--    gravaveis apenas pelas funcoes SECURITY DEFINER (que rodam como owner).
-- ---------------------------------------------------------------------
revoke update on public.profiles from anon, authenticated;
grant  update (username) on public.profiles to authenticated;

-- ---------------------------------------------------------------------
-- 2) COLLECTION: leitura do dono; escrita so via grant_card/forge_card/shop_buy.
--    Antes um POST direto em /rest/v1/collection dava as 52 cartas de graca.
-- ---------------------------------------------------------------------
drop policy if exists collection_owner_all on public.collection;
create policy collection_owner_read on public.collection
  for select using (auth.uid() = user_id);
revoke insert, update, delete on public.collection from anon, authenticated;

-- ---------------------------------------------------------------------
-- 3) DECKS: a regra "8 cartas, ate 20 estrelas, todas possuidas" agora
--    vale no banco. Sem isso o PvP nunca seria justo.
-- ---------------------------------------------------------------------
create or replace function public.valida_deck()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare n int; n_unicas int; n_possui int; estrelas int;
begin
  n := coalesce(array_length(new.cartas, 1), 0);
  if n = 0 then return new; end if;           -- deck vazio (seed do cadastro)

  if n <> 8 then
    raise exception 'deck precisa de exatamente 8 cartas (recebeu %)', n
      using errcode = 'check_violation';
  end if;

  select count(distinct x) into n_unicas from unnest(new.cartas) x;
  if n_unicas <> 8 then
    raise exception 'deck nao pode repetir cartas'
      using errcode = 'check_violation';
  end if;

  select count(*) into n_possui
    from public.collection c
   where c.user_id = new.user_id and c.card_slug = any(new.cartas);
  if n_possui <> 8 then
    raise exception 'deck tem carta que voce nao possui'
      using errcode = 'check_violation';
  end if;

  select coalesce(sum(custo), 0) into estrelas
    from public.cards where slug = any(new.cartas);
  if estrelas > 20 then
    raise exception 'deck passou do limite de 20 estrelas (tem %)', estrelas
      using errcode = 'check_violation';
  end if;

  return new;
end $$;

drop trigger if exists trg_valida_deck on public.decks;
create trigger trg_valida_deck
  before insert or update on public.decks
  for each row execute function public.valida_deck();

-- ---------------------------------------------------------------------
-- 4) ANTI-FARM: duel_reward confia no cliente para dizer se venceu.
--    Nao da para provar o resultado sem servidor autoritativo, entao
--    limitamos o ritmo: um duelo real nao termina em menos de ~15 s.
-- ---------------------------------------------------------------------
alter table public.profiles
  add column if not exists duel_last  timestamptz,
  add column if not exists duel_dia    date,
  add column if not exists duel_qtd    int not null default 0;

create or replace function public.duel_reward(p_win boolean)
returns json
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_user uuid := auth.uid(); v_ganho int; v_ouro int;
        v_last timestamptz; v_dia date; v_qtd int;
begin
  if v_user is null then return json_build_object('error','auth'); end if;

  select duel_last, duel_dia, duel_qtd into v_last, v_dia, v_qtd
    from profiles where id = v_user for update;

  -- ritmo: nenhum duelo de 4 rodadas termina em menos de 12 segundos
  if v_last is not null and now() - v_last < interval '12 seconds' then
    return json_build_object('error','muito_rapido');
  end if;

  -- teto diario generoso: 100 duelos por dia
  if v_dia = current_date then
    if v_qtd >= 100 then return json_build_object('error','limite_diario'); end if;
    v_qtd := v_qtd + 1;
  else
    v_dia := current_date; v_qtd := 1;
  end if;

  v_ganho := case when p_win then 30 else 10 end;
  update profiles
     set ouro = ouro + v_ganho, duel_last = now(), duel_dia = v_dia, duel_qtd = v_qtd
   where id = v_user;
  select ouro into v_ouro from profiles where id = v_user;
  return json_build_object('ok', true, 'ganho', v_ganho, 'ouro', v_ouro);
end $$;

-- career_claim: mesmo raciocinio, um estagio exige um duelo vencido
create or replace function public.career_claim(p_elem text)
returns json
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_user uuid := auth.uid(); v_st int; v_slug text; v_ouro int; v_last timestamptz;
begin
  if v_user is null then return json_build_object('error','auth'); end if;
  if p_elem not in ('fogo','agua','nat','raio') then return json_build_object('error','elem'); end if;

  select duel_last into v_last from profiles where id = v_user for update;
  if v_last is not null and now() - v_last < interval '12 seconds' then
    return json_build_object('error','muito_rapido');
  end if;

  insert into career_progress(user_id, elemento, estagios) values (v_user, p_elem, 0)
    on conflict (user_id, elemento) do nothing;
  select estagios into v_st from career_progress where user_id = v_user and elemento = p_elem;
  if v_st >= 11 then return json_build_object('error','completo'); end if;

  select slug into v_slug from (
    select slug, row_number() over (order by ordem) - 1 as idx from cards where elemento = p_elem
  ) x where x.idx = v_st;

  perform grant_card(v_user, v_slug);
  update career_progress set estagios = estagios + 1 where user_id = v_user and elemento = p_elem;
  update profiles set ouro = ouro + 25, duel_last = now() where id = v_user;
  select ouro into v_ouro from profiles where id = v_user;
  return json_build_object('ok', true, 'slug', v_slug, 'estagio', v_st + 1, 'ouro', v_ouro);
end $$;

-- ---------------------------------------------------------------------
-- 5) Higiene: search_path fixo nas funcoes puras e nada de anon nas RPCs
-- ---------------------------------------------------------------------
alter function public.valor_essencia(text) set search_path to 'public';
alter function public.custo_forja(text)    set search_path to 'public';
alter function public.preco_loja(text)     set search_path to 'public';

revoke execute on function public.state_get()             from anon;
revoke execute on function public.daily_claim()           from anon;
revoke execute on function public.duel_reward(boolean)    from anon;
revoke execute on function public.career_claim(text)      from anon;
revoke execute on function public.shop_get()              from anon;
revoke execute on function public.shop_buy(text)          from anon;
revoke execute on function public.forge_card(text)        from anon;
revoke execute on function public.grant_card(uuid, text)  from anon, authenticated;
revoke execute on function public.valida_deck()           from anon, authenticated;
