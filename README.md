# Valdória ⚔️

MMORPG casual de navegador — jogo de cartas de gladiadores em mundo de fantasia medieval, com 4 elementos (Fogo, Água, Natureza, Raio), progressão, rankings e duelos entre jogadores. **Mobile-first / retrato (celular em pé).**

## Estado — v1.0

Jogo completo de ponta a ponta: conta real, coleção, deck, economia, Carreira, Arena ranqueada, missões diárias e **Duelo ao Vivo — PvP em tempo real, dois jogadores na mesma partida**. Tudo que vale ouro ou pontos é decidido no banco, não no JavaScript — o repositório é público de propósito e o cliente é tratado como não confiável.

O que dá pra fazer hoje: criar conta e receber um pacote de introdução com 10 cartas e um deck legal de 8, montar deck respeitando o limite de 20★, duelar na Carreira, comprar na loja diária, forjar cartas com essência, cumprir três missões novas por dia, treinar contra o deck salvo de outro jogador e enfrentar gente de verdade ao vivo, carta por carta e com prazo por jogada. Bronze → Prata → Ouro → Platina → Diamante → Lenda.

**Novidade da v1.0:** o *Duelo ao Vivo*. A fila fica na tela da Arena; quando dois jogadores de pontuação parecida se encontram, o servidor cria a partida, sorteia quem começa e passa a mandar na ordem das jogadas. Vale o dobro do ouro do treino e mexe mais no ranking.

## Como rodar

Abra `index.html` no navegador — `supabase.js`, `imgdata.js` e `bgdata.js` precisam estar ao lado. Para uma versão de arquivo único (bom pra mandar por e-mail ou abrir offline), rode `python3 build/build_standalone.py`.

Os testes usam Playwright e rodam direto da raiz do repositório: `node test/misstest.js`, `node test/arenatest.js`, `node test/fxtest.js`, `node test/vivotest.js`. O último sobe **dois navegadores contra um servidor de mentira** que reimplementa as regras da migração 0011 em JavaScript — é assim que se prova que os dois clientes nunca divergem.

## Estrutura

```
index.html              o jogo inteiro (HTML + CSS + JS num arquivo só)
supabase.js             SDK do Supabase vendorizado (sem CDN)
imgdata.js              52 cartas em base64 (320px JPEG)
bgdata.js               4 cenários em base64 (splash, home, mapa, duelo)
assets/bg-orig/         PNGs originais dos cenários (alta resolução)
build/                  gera imgdata.js / bgdata.js / o arquivo único
test/                   testes Playwright (telas, duelo, efeitos, Arena, missões, ao vivo)
supabase/migrations/    todo o schema, 0001 → 0012
```

## Regras do duelo

Vida **20**. Deck de **8 cartas**, somando no máximo **20★**. Quatro rodadas de ataque→defesa alternando, com **10 segundos** por jogada (no Duelo ao Vivo o prazo é do servidor: 30s na primeira jogada, 22s nas outras); se empatar em vida, entra morte súbita (rodadas extras até alguém abrir vantagem). Vantagem elemental: Fogo > Natureza > Água > Raio > Fogo.

## Arena — PvP assíncrono ("espelho de deck")

Não há socket nem partida ao vivo. O servidor sorteia **outro jogador de pontuação parecida** e devolve o deck salvo dele; esse deck é jogado pela mesma IA local. Se ninguém na faixa tiver deck válido, entra um gladiador da guilda (PNJ) e a partida vale menos.

O pareamento é escolhido **pelo servidor**, não pedido pelo cliente: `arena_find()` grava uma linha em `arena_pending`, e `arena_result(p_win)` só paga contra aquela linha — depois apaga. Sem isso, um jogador poderia inventar o adversário e a vitória. Vale também um piso de 12 segundos, validade de 30 minutos e o mesmo teto de 100 partidas/dia da Carreira.

Pontos por partida: vitória rende **+15 a +35**, derrota custa **−7 a −23**, sempre proporcional à diferença de pontuação entre os dois. Ganhar de alguém muito mais forte paga o teto; perder pra alguém muito mais fraco cobra o piso. A pontuação nunca fica negativa.

**Sobre fugir da derrota:** no treino ainda dá — sair da tela no meio só deixa a linha pendente expirar, e o teto diário com o piso de 12 segundos é o que limita o estrago. No **Duelo ao Vivo** isso acabou: o servidor sabe que a partida começou, e sair dela é derrota imediata (veja abaixo).

## Duelo ao Vivo — PvP em tempo real

Dois jogadores, uma partida só, cada carta com prazo. A fila mora na tela da Arena: `match_find()` procura alguém na faixa de pontos — a faixa abre conforme a espera — e, quando acha, cria a partida e apaga as duas linhas da fila na mesma transação. Os dois clientes caem no duelo pela resposta do próprio `match_find` ou pelo poll seguinte.

**Quem manda na partida é o servidor.** Ele ordena os dois decks, sorteia quem começa e guarda toda a linha do tempo num array `jogadas`: `{"r":rodada,"f":"atk"|"def","s":slot,"c":índice da carta}`. O cliente não escolhe rodada nem vez — ele pergunta e obedece. `live_turno(starter, rodada, fase)` é a única fonte da verdade sobre de quem é a vez, e a mesma regra está escrita no JavaScript; o teste cruza as duas em todas as 16 combinações.

**As mãos são abertas, de propósito.** Vários especiais leem a mão dos dois lados, então os dois clientes precisam dos dois decks pra chegar no mesmo placar. Esconder seria só fingir que o adversário não sabe.

**Placar conferido dos dois lados.** O cálculo do dano (28 especiais) continua no JavaScript — reescrever isso em plpgsql seria manter duas versões da mesma regra e esperar que nunca discordem. Em vez disso, cada cliente manda `match_report(minha_vida, vida_dele)` e o pagamento **só acontece quando as duas versões batem**. Divergiu, ninguém pontua: a partida vira `disputa` e conta uma no contador do dia dos dois. Três disputas no mesmo dia e o Duelo ao Vivo fecha até amanhã — quem mexe no cliente descobre rápido que o único resultado possível é não jogar.

**Anti-fuga.** Cada fase tem prazo (30s na primeira, 22s nas outras). Estourou, o servidor joga a carta mais baixa que sobrou e marca uma falta; **duas faltas é W.O.**. O cliente joga sozinho ~2s antes do prazo, então quem está com a aba aberta nunca leva falta. Sair no meio (`match_leave`) é derrota na hora, e um F5 devolve a partida exatamente onde estava — as jogadas são reaplicadas sem animação e o duelo continua.

Pagamento: vitória rende **+30 pontos e 60 de ouro**, derrota custa **−12 e paga 15 de consolação**, empate dá 20 pros dois — sempre corrigido pela diferença de pontuação, como na Arena. Cinco RPCs, todas `authenticated`: `match_find`, `match_state`, `match_play`, `match_report`, `match_leave`.

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
- **Backend:** Supabase (Postgres + Auth) — contas, coleção, ouro, deck, ranking, Arena, missões, Duelo ao Vivo.
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
| `0011_duelo_ao_vivo.sql` | Duelo ao Vivo: fila, pareamento, linha do tempo das jogadas, prazos, faltas, W.O., placar cruzado |
| `0012_vivo_fila_e_recompensa.sql` | `match_state` olha a fila antes da partida; `ouro1/ouro2` viram o **ganho**, não o saldo |

### Modelo de permissões

O cliente é público, então o JavaScript **só desenha a tela**. Toda regra de economia vive no banco.

| O quê | Quem pode escrever |
|---|---|
| `profiles` | o dono, e **só a coluna `username`** (grant por coluna) |
| `collection` | ninguém pelo REST — só `grant_card` / `forge_card` / `shop_buy` |
| `decks` | o dono, só as colunas `nome, cartas, ativo, updated_at`, e ainda passando pelo trigger `valida_deck()` |
| `arena_pending` | ninguém — RLS ligado sem policy nenhuma, só funções `SECURITY DEFINER` encostam |
| `missions` / `mission_defs` | idem: RLS sem policy, e nem SELECT o cliente tem |
| `live_queue` / `live_duels` | idem: nem a fila nem a partida o cliente enxerga direto — tudo passa pelas cinco RPCs |
| ouro / gemas / essência / rank | só funções `SECURITY DEFINER` |

**API pública (16 RPCs, só `authenticated`):** `state_get`, `daily_claim`, `duel_reward`, `shop_get`, `shop_buy`, `forge_card`, `arena_find`, `arena_result`, `ranking_top`, `missions_get`, `missions_claim`, `match_find`, `match_state`, `match_play`, `match_report`, `match_leave`.

As auxiliares (`dia_jogo`, `missoes_do_dia`, `missoes_hoje`, `missao_prog`, `liga`, `preco_loja`, `custo_forja`, …) **não** são `SECURITY DEFINER` e não têm EXECUTE pra ninguém: rodam com o direito de quem as chamou e são inalcançáveis pelo REST.

**Duas pegadinhas do Postgres que custaram caro aqui:**

`REVOKE EXECUTE ... FROM anon, authenticated` **não adianta nada** sozinho — EXECUTE é concedido a `PUBLIC` por padrão. Tem que revogar de `public, anon, authenticated` e devolver só o necessário.

`TRUNCATE` **não passa pelo RLS**. Enquanto o papel `authenticated` tivesse TRUNCATE em `profiles`, uma única chamada esvaziaria a tabela inteira por cima de todas as policies. A migração 0008 tira todo GRANT que o jogo não usa.

## Design system

Azul-real, prata, dourado e brasa. Elementos: Fogo `#ec5a22`, Água `#2aa9d9`, Natureza `#46b45c`, Raio `#f2c31a`. Raridade = cor (Comum prata · Incomum verde · Rara azul · Épica roxo). Fontes: Cinzel Decorative, Cinzel, EB Garamond.
