# Valdória ⚔️

MMORPG casual de navegador — jogo de cartas de gladiadores em mundo de fantasia medieval, com 4 elementos (Fogo, Água, Natureza, Raio), progressão, rankings e duelos entre jogadores. **Mobile-first / retrato (celular em pé).**

## Estado
Protótipo jogável (v0.4). Front-end completo em HTML/CSS/JS puro, com as 52 cartas ilustradas, cenários e o duelo funcional (sorteio de início, timer de 10s, ataque→defesa alternando, 2 ataques + 2 defesas por jogador). Backend (contas, coleção, PvP) em construção no Supabase.

## Como rodar
Abra `index.html` no navegador (o `imgdata.js` e o `bgdata.js` precisam estar ao lado). Para uma versão de arquivo único, rode o build (abaixo) ou use o `valdoria-standalone.html` gerado.

## Estrutura
```
index.html              jogo (referencia imgdata.js + bgdata.js)
imgdata.js              52 cartas em base64 (320px JPEG)
bgdata.js              4 cenários do GPT em base64 (splash, home, mapa, duelo)
assets/bg-orig/        PNGs originais dos cenários (alta resolução)
build/                 scripts que geram imgdata.js / bgdata.js a partir dos PNGs
test/                  testes Playwright (telas + fluxo de duelo)
supabase/migrations/   schema (0001) + seed do catálogo de 52 cartas (0002)
```

## Stack
- **Agora:** HTML5 + CSS + JS (vanilla), mobile-first.
- **Backend:** Supabase (Postgres + Auth + Realtime) — contas, coleção, ouro, deck, ranking, PvP.
- **Publicação (planejada):** empacotar com Capacitor → App Store (iOS) + Play Store (Android).

## Banco (Supabase)
`supabase/migrations/` versiona o schema:
- `0001_init.sql` — tabelas `profiles`, `cards`, `collection`, `decks`, RLS por usuário e trigger que dá cartas iniciais + deck no cadastro.
- `0002_seed_cards.sql` — catálogo das 52 cartas.

## Design system
Azul-real, prata, dourado e brasa. Elementos: Fogo `#ec5a22`, Água `#2aa9d9`, Natureza `#46b45c`, Raio `#f2c31a`. Raridade = cor (Comum prata · Incomum verde · Rara azul · Épica roxo). Fontes: Cinzel Decorative, Cinzel, EB Garamond.
