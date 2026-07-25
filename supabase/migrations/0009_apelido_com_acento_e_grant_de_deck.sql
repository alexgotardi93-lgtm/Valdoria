-- =====================================================================
-- v0.8 — conserto de duas coisas que a 0008 deixou torta
--         (aplicada: 20260725024506)
--
-- 1. O limpador de apelido jogava fora qualquer letra acentuada, entao
--    "Jose Alvaro" com acento virava "Joslvaro". Num jogo brasileiro
--    isso e bug, nao seguranca. Agora o acento vira a letra sem acento.
--
-- 2. O GRANT de UPDATE em decks pegava a tabela inteira, inclusive id e
--    user_id. O RLS impedia roubar o deck de outro, mas nao ha motivo
--    pra essas duas colunas estarem abertas. Fica so o que o jogo grava.
-- =====================================================================

create or replace function public.apelido_limpo(p_base text)
returns text
language sql
immutable
set search_path to 'public'
as $$
  select case when length(x) >= 3 then left(x, 16) else left(x || 'gladiador', 16) end
  from (
    select regexp_replace(
             translate(coalesce(p_base, ''),
               'áàâãäéèêëíìîïóòôõöúùûüçñÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ',
               'aaaaaeeeeiiiiooooouuuucnAAAAAEEEEIIIIOOOOOUUUUCN'),
             '[^A-Za-z0-9_]', '', 'g') as x
  ) t;
$$;

revoke execute on function public.apelido_limpo(text) from public, anon, authenticated;

revoke update on public.decks from authenticated;
grant  update (nome, cartas, ativo, updated_at) on public.decks to authenticated;

-- Conferido depois de aplicar:
--   'José Álvaro'    -> JoseAlvaro
--   'Ação Ç'         -> AcaoC
--   'joao.silva+spam'-> joaosilvaspam
--   'ab'             -> abgladiador
--   ''               -> gladiador
--   '<script>...'    -> scriptalert1scri
