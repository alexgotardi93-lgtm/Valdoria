-- =====================================================================
-- v0.8 — regra do apelido + faxina nos GRANTs de tabela
--
-- Duas frestas que a Arena abriu:
--
-- 1. O apelido deixou de ser coisa sua. Agora ele aparece na Arena, no
--    Ranking e no historico de duelo dos OUTROS jogadores, e a coluna e
--    gravavel pelo dono. Sem regra nenhuma dava pra por 5000 caracteres,
--    HTML, ou copiar o apelido de outra pessoa. O cliente ja escapa o
--    HTML; aqui o banco passa a impor formato e unicidade.
--
-- 2. Varias tabelas ainda carregavam GRANTs que o jogo nunca usa. O RLS
--    segurava quase tudo, mas TRUNCATE **nao passa** pelo RLS: quem
--    tivesse o papel authenticated poderia esvaziar profiles. Aqui fica
--    so o que o jogo realmente chama.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. apelido: formato, unicidade e um gerador que nunca quebra o cadastro
-- ---------------------------------------------------------------------

-- tira o que nao for letra, numero ou sublinhado e encaixa em 3..16
create or replace function public.apelido_limpo(p_base text)
returns text
language sql
immutable
set search_path to 'public'
as $$
  select case
           when length(x) >= 3 then left(x, 16)
           else left(x || 'gladiador', 16)
         end
  from (select regexp_replace(coalesce(p_base, ''), '[^A-Za-z0-9_]', '', 'g') as x) t;
$$;

-- limpa e, se ja existir, vai somando sufixo ate achar um livre
create or replace function public.apelido_livre(p_base text)
returns text
language plpgsql
set search_path to 'public'
as $$
declare v_base text := apelido_limpo(p_base);
        v_try  text := v_base;
        v_n    int  := 1;
begin
  while exists (select 1 from profiles where lower(username) = lower(v_try)) loop
    v_n   := v_n + 1;
    v_try := left(v_base, 16 - length(v_n::text)) || v_n::text;
    if v_n > 9999 then
      -- desistiu de ser criativo: pega um sufixo aleatorio
      v_try := left(v_base, 10) || floor(random() * 900000 + 100000)::text;
      exit;
    end if;
  end loop;
  return v_try;
end $$;

-- normaliza quem ja esta no banco antes de ligar a trava
update public.profiles
   set username = public.apelido_livre(username)
 where username is null
    or username !~ '^[A-Za-z0-9_]{3,16}$';

-- e desempata quem por acaso repetiu
do $$
declare r record;
begin
  for r in
    select id, username from public.profiles p
     where exists (select 1 from public.profiles q
                    where lower(q.username) = lower(p.username)
                      and q.created_at < p.created_at)
  loop
    update public.profiles set username = public.apelido_livre(r.username) where id = r.id;
  end loop;
end $$;

alter table public.profiles drop constraint if exists profiles_username_ok;
alter table public.profiles add  constraint profiles_username_ok
  check (username is null or username ~ '^[A-Za-z0-9_]{3,16}$');

drop index if exists public.profiles_username_uniq;
create unique index profiles_username_uniq on public.profiles (lower(username));

-- o cadastro tirava o apelido do e-mail cru: "joao.silva+spam@x.com" virava
-- "joao.silva+spam", e dois "joao@" de provedores diferentes colidiriam.
-- Agora passa pelo apelido_livre, entao cadastro nenhum falha por isso.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare starter text[];
begin
  insert into public.profiles (id, username)
  values (new.id, public.apelido_livre(
            coalesce(new.raw_user_meta_data->>'username', split_part(new.email,'@',1))));

  insert into public.collection(user_id, card_slug, qtd)
  select new.id, s.slug, 1 from (
    select distinct on (elemento) slug from public.cards where raridade = 'comum' order by elemento, random()
  ) s;
  insert into public.collection(user_id, card_slug, qtd)
  select new.id, slug, 1 from public.cards
   where raridade = 'comum' and slug not in (select card_slug from public.collection where user_id = new.id)
   order by random() limit 1;
  insert into public.collection(user_id, card_slug, qtd)
  select new.id, s.slug, 1 from (
    select distinct on (elemento) slug from public.cards where raridade = 'incomum' order by elemento, random()
  ) s;
  insert into public.collection(user_id, card_slug, qtd)
  select new.id, slug, 1 from public.cards where raridade = 'rara' order by random() limit 1;

  select array_agg(slug) into starter from (
    select c.card_slug as slug from public.collection c join public.cards ca on ca.slug = c.card_slug
    where c.user_id = new.id order by ca.custo asc, random() limit 8
  ) x;
  insert into public.decks(user_id, nome, cartas, ativo)
  values (new.id, 'Deck Inicial', coalesce(starter, '{}'), true);
  return new;
end $$;

revoke execute on function public.apelido_limpo(text) from public, anon, authenticated;
revoke execute on function public.apelido_livre(text) from public, anon, authenticated;
revoke execute on function public.handle_new_user()   from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. GRANTs de tabela: so o que o cliente realmente usa
--
-- Atencao ao TRUNCATE: ele NAO respeita RLS. Enquanto authenticated
-- tivesse TRUNCATE em profiles, uma unica chamada esvaziaria a tabela
-- inteira por cima de todas as policies.
-- ---------------------------------------------------------------------

revoke all on public.cards           from anon, authenticated;
revoke all on public.profiles        from anon, authenticated;
revoke all on public.collection      from anon, authenticated;
revoke all on public.career_progress from anon, authenticated;
revoke all on public.daily_shop      from anon, authenticated;
revoke all on public.decks           from anon, authenticated;
revoke all on public.matches         from anon, authenticated;
revoke all on public.arena_pending   from anon, authenticated;

-- catalogo das 52 cartas: leitura aberta, e so
grant select on public.cards to anon, authenticated;

-- o resto e do dono, e o RLS ja filtra por auth.uid()
grant select                 on public.profiles        to authenticated;
grant update (username)      on public.profiles        to authenticated;
grant select                 on public.collection      to authenticated;
grant select                 on public.career_progress to authenticated;
grant select                 on public.daily_shop      to authenticated;
grant select                 on public.matches         to authenticated;

-- deck e a unica tabela que o cliente escreve direto, e o gatilho
-- trg_valida_deck confere 8 cartas, ate 20 estrelas e posse de todas
grant select, insert, update on public.decks to authenticated;

-- arena_pending nao tem policy nenhuma de proposito: so as funcoes
-- SECURITY DEFINER encostam nela

-- ---------------------------------------------------------------------
-- 3. mesa limpa: a tabela de saida dos testes vai embora
-- ---------------------------------------------------------------------
drop table if exists public._teste_out;
