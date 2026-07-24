-- Valdória — schema inicial (contas, catálogo, coleção, decks)
-- Milestone 1: contas + salvar coleção/deck

-- ============ CATÁLOGO DE CARTAS (público, leitura) ============
create table if not exists public.cards (
  slug       text primary key,
  nome       text not null,
  elemento   text not null check (elemento in ('fogo','agua','nat','raio')),
  raridade   text not null check (raridade in ('comum','incomum','rara','epica')),
  custo      int  not null,            -- estrelas (1..4)
  atk        int  not null,
  def        int  not null,
  especial   text,
  ordem      int                       -- posição no baralho (0..51)
);
alter table public.cards enable row level security;
create policy "cards_public_read" on public.cards for select using (true);
-- sem policy de escrita: catálogo só muda por migração/service_role

-- ============ PERFIL DO JOGADOR ============
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  username   text unique,
  ouro       int  not null default 250,
  gemas      int  not null default 12,
  rank_pts   int  not null default 0,
  nivel      int  not null default 1,
  created_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
create policy "profiles_owner_read"   on public.profiles for select using (auth.uid() = id);
create policy "profiles_owner_update" on public.profiles for update using (auth.uid() = id) with check (auth.uid() = id);
-- ranking público (só nome + pontos) fica para um passo futuro via view/policy dedicada

-- ============ COLEÇÃO DO JOGADOR ============
create table if not exists public.collection (
  user_id   uuid not null references auth.users(id) on delete cascade,
  card_slug text not null references public.cards(slug),
  qtd       int  not null default 1 check (qtd >= 0),
  primary key (user_id, card_slug)
);
alter table public.collection enable row level security;
create policy "collection_owner_all" on public.collection
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ============ DECKS DO JOGADOR ============
create table if not exists public.decks (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  nome       text not null default 'Meu Deck',
  cartas     text[] not null default '{}',   -- slugs (até 8)
  ativo      boolean not null default true,
  updated_at timestamptz not null default now()
);
alter table public.decks enable row level security;
create policy "decks_owner_all" on public.decks
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
create index if not exists decks_user_idx on public.decks(user_id);

-- ============ TRIGGER DE CADASTRO ============
-- Ao criar um usuário: cria profile, dá as cartas COMUNS de início e um deck padrão.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  starter text[];
begin
  insert into public.profiles (id, username)
  values (new.id, coalesce(new.raw_user_meta_data->>'username', split_part(new.email,'@',1)));

  -- coleção inicial: 1 cópia de cada carta comum
  insert into public.collection (user_id, card_slug, qtd)
  select new.id, slug, 1 from public.cards where raridade = 'comum';

  -- deck padrão: 8 comuns de menor custo, variando elemento quando possível
  select array_agg(slug) into starter from (
    select slug from public.cards where raridade = 'comum'
    order by custo asc, ordem asc limit 8
  ) s;

  insert into public.decks (user_id, nome, cartas, ativo)
  values (new.id, 'Deck Inicial', coalesce(starter, '{}'), true);

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
