-- =====================================================================
-- v0.7 — grants de EXECUTE explicitos (aplicada: 20260725020037)
--
-- O Postgres concede EXECUTE a PUBLIC por padrao, entao revogar de anon ou
-- authenticated nao adianta nada enquanto PUBLIC continuar com o privilegio.
-- Aqui fechamos tudo e liberamos so o que o jogo precisa, para authenticated.
-- =====================================================================

revoke execute on function public.state_get()                  from public, anon, authenticated;
revoke execute on function public.daily_claim()                from public, anon, authenticated;
revoke execute on function public.duel_reward(boolean, text)   from public, anon, authenticated;
revoke execute on function public.career_claim(text)           from public, anon, authenticated;
revoke execute on function public.shop_get()                   from public, anon, authenticated;
revoke execute on function public.shop_buy(text)               from public, anon, authenticated;
revoke execute on function public.forge_card(text)             from public, anon, authenticated;
revoke execute on function public.grant_card(uuid, text)       from public, anon, authenticated;
revoke execute on function public.valida_deck()                from public, anon, authenticated;
revoke execute on function public.handle_new_user()            from public, anon, authenticated;

-- so estas ficam abertas, e apenas para quem esta logado
grant execute on function public.state_get()                to authenticated;
grant execute on function public.daily_claim()              to authenticated;
grant execute on function public.duel_reward(boolean, text) to authenticated;
grant execute on function public.shop_get()                 to authenticated;
grant execute on function public.shop_buy(text)             to authenticated;
grant execute on function public.forge_card(text)           to authenticated;

-- career_claim, grant_card, valida_deck e handle_new_user passam a ser
-- internas: so as proprias funcoes SECURITY DEFINER as usam.
