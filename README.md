# Valdória ⚔️

MMORPG casual de navegador — jogo de cartas de gladiadores em mundo de fantasia medieval, com 4 elementos (Fogo, Água, Natureza, Raio), progressão, rankings e duelos entre jogadores. **Mobile-first / retrato (celular em pé).**

## Estado — v0.9

Jogo completo de ponta a ponta: conta real, coleção, deck, economia, Carreira, **Arena ranqueada com PvP assíncrono** e **missões diárias**. Tudo que vale ouro ou pontos é decidido no banco, não no JavaScript — o repositório é público de propósito e o cliente é tratado como não confiável.

O que dá pra fazer hoje: criar conta e receber um pacote de introdução com 10 cartas e um deck legal de 8, montar deck respeitando o limite de 20★, duelar na Carreira, comprar na loja diária, forjar cartas com essência, cumprir três missões novas por dia e subir de liga na Arena enfrentando o deck de outro jogador. Bronze → Prata → Ouro → Platina → Diamante → Lenda.

**Novidade da v0.9:** o painel *Missões do Dia* na tela inicial, com contagem regressiva para a virada e um ponto dourado no menu quando há recompensa esperando.

## Como rodar

Abra `index.html` no navegador — `supabase.js`, `imgdata.js` e `bgdata.js` precisam estar ao lado. Para uma versão de arquivo único (bom pra mandar por e-mail ou abrir offline), rode `python3 build/build_standalone.py`.

Os testes usam Playwright e rodam direto da raiz do repositório: `node test/misstest.js`, `node test/arenatest.js`, `node test/fxtest.js`.

## Estrutura

```
index.html              o jogo inteiro (HTML + CSS + JS num arquivo só)
supabase.js             SDK do Supabase vendorizado (sem CDN)
imgdata.js              52 cartas em base64 (320px JPEG)
bgdata.js               4 cenários em base64 (splash, home, mapa, duelo)
assets/bg-orig/         PNGs originais dos cenários (alta resolução)
build/                  gera imgdata.js / bgdata.js / o arquivo único
test/                   testes Playwright (telas, duelo, efeitos, Arena, missões)
supabase/migrations/    todo o schema, 0001 → 0010
```

## Regras do duelo

Vida **20**. Deck de **8 cartas**, somando no máximo **20★**. Quatro rodadas de ataque→defesa alternando, com **10 segundos** por jogada; se empatar em vida, entra morte súbita (rodadas extras até alguém abrir vantagem). Vantagem elemental: Fogo > Natureza > Água > Raio > Fogo.

## Arena — PvP assíncrono ("espelho de deck")

Não há socket nem partida ao vivo. O servidor sorteia **outro jogador de pontuação parecida** e devolve o deck salvo dele; esse deck é jogado pela mesma IA local. Se ninguém na faixa tiver deck válido, entra um gladiador da guilda (PNJ) e a partida vale menos.

O pareamento é escolhido **pelo servidor**, não pedido pelo cliente: `arena_find()` grava uma linha em `arena_pending`, e `arena_result(p_win)` só paga contra aquela linha — depois apaga. Sem isso, um jogador poderia inventar o adversário e a vitória. Vale também um piso de 12 segundos, validade de 30 minutos e o mesmo teto de 100 partidas/dia da Carreira.

Pontos por partida: vitória rende **+15 a +35**, derrota custa **−7 a −23**, sempre proporcional à diferença de pontuação entre os dois. Ganhar de alguém muito mais forte paga o teto; perder pra alguém muito mais fraco cobra o piso. A pontuação nunca fica negativa.

**Limitação conhecida:** dá pra fugir de uma derrota saindo da tela no meio do duelo — a linha pendente só expira. O teto diário e o piso de 12 segundos limitam o estrago; a correção de verdade exige o servidor saber que o duelo começou, e isso é o marco do PvP em tempo real.

## Missões do Dia

Três missões por dia — **uma do grupo base** (sempre alcançável só jogando) e **duas do grupo extra** —, mais um **bônus de 100 ouro e 2 gemas** por completar as três. Vira à meia-noite de Brasília.

O catálogo tem 12 missões em `mission_defs`: terminar duelos, vencer duelos, vencer ou disputar na Arena, vencer na Carreira, comprar na loja, forjar uma carta, e vencer em cada uma das quatro regiões (Chamalar, Nereida, Selvaria, Tormenália). Pagam entre 50 e 160 de ouro, e algumas somam gema ou essência.

**O sorteio é determinístico e não tem re-roll.** As três do dia saem de `md5(usuário ‖ dia ‖ slug)` — recarregar a página, sair e voltar, ou trocar de aparelho devolve exatamente as mesmas três. Ninguém pode ficar girando até tirar as missões mais fáceis.

**O progresso nunca é reportado pelo cliente.** Não existe RPC de "marcar progresso". A contagem acontece dentro de `duel_reward`, `arena_result`, `shop_buy` e `forge_card`, sempre **depois** do UPDATE que já cobrou ou pagou — então nada conta num caminho que deu erro no meio. O JavaScript só sabe desenhar a barrinha e pedir o pagamento.

Duas RPCs públicas: `missions_get()` devolve as três missões do dia com progresso, pagamento e quantos segundos faltam pra virada; `missions_claim(p_idx)` paga uma missão (índices 1–3) ou o bônus (índice 4), e recusa com `incompleta` ou `ja_pego`.

**Ordem de trava:** todo caminho que mexe nas duas tabelas pega `profiles` **antes** de `missions` — inclusive `missions_claim`, que faz um `select … for update` em `profiles` antes de chamar `missoes_hoje`. Sem essa regra única, um jogador coletando missão enquanto termina um duelo poderia travar em deadlock.

O dia das missões é o de Brasília (`dia_jogo()`), de propósito diferente do `current_date` em UTC que o teto de 100 duelos/dia usa. Missões são um subsistema fechado: só leem e escrevem a coluna `dia` delas, então os dois relógios não se atropelam.

## Stack

- **Agora:** HTML5 + CSS + JS (vanilla), mobile-first, arquivo único.
- **Backend:** Supabase (Postgres + Auth) — contas, coleção, ouro, deck, ranking, Arena, missões.
- **Publicação (planejada):** empacotar com Capacitor → App Store (iOS) + Play Store (Android).

## Banco (Supabase)

`supabase/migrations/` versiona **tudo** que roda em produção — não há passo manual no dashboard.

| Arquivo | O que faz |
|---|---|
| `0001_init.sql` | `profiles`, `cards`, `collection`, `decks`, RLS por usuário, trigger de cadastro |
| `0002_seed_cards.sql` | catálogo das 52 cartas |
| `0003_economy.sql` | ouro, gemas, essência, loja diária, carreira, recompensa diária |
| `0004_seguranca_economia_e_deck.sql` | fecha escrita direta em `profiles`/`collection`; trigger `valida_deck()` |
| `0005_duel_reward_unico_com_carreira.sql` | fim de duelo vira **uma** chamada atômica |
| `0006_execute_grants_explicitos.sql` | revoga EXECUTE de `public` (ver pegadinha abaixo) |
| `0007_arena_ranking_e_historico.sql` | Arena, pareamento, pontos, ranking e histórico de partidas |
| `0008_username_e_grants_de_tabela.sql` | formato e unicidade do apelido; faxina nos GRANTs de tabela |
| `0009_apelido_com_acento_e_grant_de_deck.sql` | apelido aceita acento; UPDATE de deck restrito por coluna |
| `0010_missoes_diarias.sql` | missões diárias: catálogo, sorteio do dia, contagem nos pontos de pagamento |

### Modelo de permissões

O cliente é público, então o JavaScript **só desenha a tela**. Toda regra de economia vive no banco.

| O quê | Quem pode escrever |
|---|---|
| `profiles` | o dono, e **só a coluna `username`** (grant por coluna) |
| `collection` | ninguém pelo REST — só `grant_card` / `forge_card` / `shop_buy` |
| `decks` | o dono, só as colunas `nome, cartas, ativo, updated_at`, e ainda passando pelo trigger `valida_deck()` |
| `arena_pending` | ninguém — RLS ligado sem policy nenhuma, só funções `SECURITY DEFINER` encostam |
| `missions` / `mission_defs` | idem: RLS sem policy, e nem SELECT o cliente tem |
| ouro / gemas / essência / rank | só funções `SECURITY DEFINER` |

**API pública (11 RPCs, só `authenticated`):** `state_get`, `daily_claim`, `duel_reward`, `shop_get`, `shop_buy`, `forge_card`, `arena_find`, `arena_result`, `ranking_top`, `missions_get`, `missions_claim`.

As auxiliares (`dia_jogo`, `missoes_do_dia`, `missoes_hoje`, `missao_prog`, `liga`, `preco_loja`, `custo_forja`, …) **não** são `SECURITY DEFINER` e não têm EXECUTE pra ninguém: rodam com o direito de quem as chamou e são inalcançáveis pelo REST.

**Duas pegadinhas do Postgres que custaram caro aqui:**

`REVOKE EXECUTE ... FROM anon, authenticated` **não adianta nada** sozinho — EXECUTE é concedido a `PUBLIC` por padrão. Tem que revogar de `public, anon, authenticated` e devolver só o necessário.

`TRUNCATE` **não passa pelo RLS**. Enquanto o papel `authenticated` tivesse TRUNCATE em `profiles`, uma única chamada esvaziaria a tabela inteira por cima de todas as policies. A migração 0008 tira todo GRANT que o jogo não usa.

## Design system

Azul-real, prata, dourado e brasa. Elementos: Fogo `#ec5a22`, Água `#2aa9d9`, Natureza `#46b45c`, Raio `#f2c31a`. Raridade = cor (Comum prata · Incomum verde · Rara azul · Épica roxo). Fontes: Cinzel Decorative, Cinzel, EB Garamond.
