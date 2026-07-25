-- =====================================================================
-- v0.7 — recompensa do duelo em uma chamada so (aplicada: 20260725015955)
--
-- O cliente disparava duel_reward e career_claim em paralelo, entao o
-- limite de ritmo criava uma corrida entre as duas. Agora e uma chamada
-- so: o fim do duelo paga o ouro e, se for Carreira vencida, entrega o
-- estagio no mesmo passo, sob o mesmo limite de ritmo.
-- =====================================================================

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

  return json_build_object('ok', true, 'ganho', v_ganho, 'ouro', v_ouro,
                           'slug', v_slug, 'estagio', v_estagio);
end $$;

-- a versao antiga de 1 argumento sai de cena
drop function if exists public.duel_reward(boolean);

-- career_claim deixa de ser chamavel de fora: era o caminho para destravar
-- as 44 cartas da Carreira sem jogar duelo nenhum
revoke execute on function public.career_claim(text) from anon, authenticated;

revoke execute on function public.duel_reward(boolean, text) from anon;
