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
