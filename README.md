# Zath Hub V4

Script principal em src/main.lua, carregado pelo loader.lua.

## Loader

Cole no executor:

    loadstring(game:HttpGet("https://raw.githubusercontent.com/verobezileonardo-stack/ZathHub/main/loader.lua"))()

## Recursos

- Coleta de variantes.
- Coleta de CollectableObject e Item Rain.
- Uso individual de pocoes.
- Anti-AFK limitado ao evento Player.Idled do cliente.
- Fechamento pelo X, com cancelamento global da sessao anterior.
- Atalho Left Ctrl para abrir o hub; a bolinha Z continua funcionando para restaurar a janela quando minimizada.
- Auto Collect Rewards: procura botoes de resgate dentro do painel de recompensas por tempo e aciona apenas botoes visiveis e habilitados.

## Observacoes

- O script depende da estrutura de objetos, atributos e RemoteEvents existentes no jogo.
- O limite de caixas normais usa PendingBallCount observado no inicio do lote.
- O limite de caixas azuis usa PolishedBallCount observado no inicio da coleta.
- Falhas de confirmacao encerram a tentativa em vez de repetir indefinidamente.
- A pausa de 30 minutos bloqueia novas retiradas normais; o monitoramento do polidor continua.
- O Anti-AFK nao impede transferencias implementadas pelo servidor ou por um sistema proprio do jogo.
- O Auto Collect Rewards identifica botoes pelo nome/texto (Claim, Collect, Resgatar, Coletar) e pelo contexto da interface (Reward, Playtime, Recompensa). Abra o painel de recompensas no jogo ao menos uma vez; o script usa a acao normal do proprio botao e nao inventa RemoteEvents.
- O Auto Collect Rewards so consegue detectar botoes que estejam presentes em PlayerGui e usem nomes/textos reconheciveis. Se o jogo usar icones sem texto, outro nome, ou um RemoteEvent direto, sera necessario identificar o objeto/remoto real para ajustar.
- O script nao foi testado em runtime dentro do Roblox; valide em uma sessao controlada e confira o status exibido no hub.

## Estrutura

- loader.lua
- src/main.lua
- README.md

## Configuracoes persistentes

- As opcoes gerais, Auto Collect Rewards e cada pocao sao carregadas automaticamente ao iniciar.
- Cada clique em uma opcao salva imediatamente o estado em `ZathHub/config.json` no armazenamento local do executor.
- O botao `SALVAR CONFIGURACOES` permite salvar manualmente.
- Para manter as opcoes depois de rejoin, o executor precisa oferecer `readfile`, `writefile` e suporte a criar a pasta `ZathHub` (`makefolder`/`isfolder`). Se esses recursos nao existirem, o script avisa que nao conseguiu persistir; o cache de memoria nao sobrevive a um rejoin completo.
- O `loader.lua` permanece no mesmo caminho e URL; ele busca sempre a versao atual de `src/main.lua` na branch `main`.

## Alteracao

A automacao de caixas, polidor e venda foi retirada da interface e desativada. O hub nao inicia mais o ciclo automatico de caixas.
