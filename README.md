# Zath Hub V4

Script principal em src/main.lua, carregado pelo loader.lua.

## Loader

Cole no executor:

    loadstring(game:HttpGet("https://raw.githubusercontent.com/verobezileonardo-stack/ZathHub/main/loader.lua"))()

## Recursos

- Coleta de variantes.
- Coleta de CollectableObject e Item Rain.
- Automacao de caixas com snapshot do lote e limite de chamadas.
- Polimento, coleta limitada de caixas azuis e venda.
- Uso individual de pocoes.
- Anti-AFK limitado ao evento Player.Idled do cliente.
- Botao de encerramento com cancelamento global da sessao anterior.

## Observacoes

- O script depende da estrutura de objetos, atributos e RemoteEvents existentes no jogo.
- O limite de caixas normais usa PendingBallCount observado no inicio do lote.
- O limite de caixas azuis usa PolishedBallCount observado no inicio da coleta.
- Falhas de confirmacao encerram a tentativa em vez de repetir indefinidamente.
- A pausa de 30 minutos bloqueia novas retiradas normais; o monitoramento do polidor continua.
- O Anti-AFK nao impede transferencias implementadas pelo servidor ou por um sistema proprio do jogo.
- Esta publicacao nao foi testada em runtime dentro do Roblox; valide primeiro em uma sessao controlada.

## Estrutura

- loader.lua
- src/main.lua
- README.md

## Configuracoes persistentes

- As opcoes gerais e cada pocao sao carregadas automaticamente ao iniciar.
- Cada clique em uma opcao salva imediatamente o estado em `ZathHub/config.json` no armazenamento local do executor.
- O botao `SALVAR CONFIGURACOES` permite salvar manualmente.
- Para manter as opcoes depois de rejoin, o executor precisa oferecer `readfile`, `writefile` e suporte a criar a pasta `ZathHub` (`makefolder`/`isfolder`). Se esses recursos nao existirem, o script avisa que nao conseguiu persistir; o cache de memoria nao sobrevive a um rejoin completo.
- O `loader.lua` permanece no mesmo caminho e URL; ele busca sempre a versao atual de `src/main.lua` na branch `main`.
