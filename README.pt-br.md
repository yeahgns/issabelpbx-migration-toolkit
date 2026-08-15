🇺🇸 [English](README.md) | 🇧🇷 Português

# Issabel PBX Migration Toolkit

Migra um Issabel PBX de uma VM para outra, mantendo fluxo, ramais, troncos, CDR e gravações.

## Por que dois modos

Ambiente de origem: multi-tenant, cada cliente numa VM própria, provisionadas sob demanda. Como cada instalação puxava a versão mais recente do repositório oficial no momento da criação, o parque acabou com versões bastante distintas entre si. Uma VM de dois anos atrás podia estar em uma major version anterior, ou na mesma major version só que numa build bem mais antiga.

Isso gera dois cenários de migração diferentes, que não podem ser tratados pelo mesmo caminho:

- **Origem em Issabel 4** (major version anterior): o Issabel tem uma função nativa de Migrate, feita exatamente pra isso. Você importa um backup gerado num Issabel 5 novo através dela. É o caminho mais confiável quando está disponível, então o modo `legacy` usa essa ferramenta em vez de tentar reconstruir manualmente algo que o próprio sistema já resolve.
- **Origem já em Issabel 5, build antiga**: aqui não tem salto de major version, mas depois de tempo suficiente entre uma build e outra, o import de backup simples para de funcionar, por causa de módulos e schema que já divergiram demais. A função Migrate nativa não ajuda nesse caso, ela é pensada pra salto de major version, não pra deriva de build. O modo `current` faz a extração manual do tarball e reconstrói o AstDB do zero.

O script cobre os dois; você escolhe o modo no começo da execução.

## O que cada etapa faz

| Etapa | `legacy` | `current` |
|---|---|---|
| 0. Troncos | Desabilita e remove só os registros SIP associados | Remove os troncos de vez |
| 1. Backup | Função Migrate nativa do Issabel (`issabel_migration.sh`), pra importar backup de Issabel 4 num Issabel 5 | Extração manual do tarball + reconstrução do AstDB (device state / hints) |
| 2. Rede | External IP, localnet, portas SIP/SIP-TLS, `strictrtp`. Igual nos dois modos |
| 3. CDR | Dump (período configurável ou tudo) + import, com fix de schema |
| 4. Gravações | rsync de `/var/spool/asterisk/monitor/`. Igual nos dois modos |

Etapas são independentes, roda só as que fazem sentido pra migração específica.

## Como rodar

O script roda no seu próprio computador, não nas VMs. Ele se conecta via SSH na origem e no destino a partir da sua máquina local. As variáveis de ambiente com as credenciais também são definidas localmente, no seu terminal, antes de chamar o script, nunca dentro do arquivo `.sh` em si:

```bash
export PBX_MYSQL_USER="asteriskuser"
export PBX_MYSQL_PASS="sua-senha"
export PBX_MYSQL_ROOT_PASS="sua-senha-root"
export PBX_NEW_VM_ROOT_PASS="senha-temporaria-so-para-a-transferencia"
export PBX_SSH_KEY="$HOME/.ssh/id_ed25519"   # opcional
export PBX_SSH_PORT="22"                      # opcional

bash scripts/migrate-pbx.sh
```

Sem as variáveis, o script pergunta na hora (sem ecoar na tela). Cada pessoa que rodar o script define as próprias variáveis no ambiente dela, elas não ficam salvas em nenhum arquivo do repositório.

## Migração em massa

Se você precisa migrar várias VMs no mesmo dia (cenário comum quando o motivo da migração é estrutural, tipo trocar de fornecedor ou de datacenter, não só um cliente isolado), rodar o script sequencialmente, um de cada vez, não escala. A abordagem mais simples e que funciona bem aqui é usar `tmux` com uma janela por migração:

```bash
tmux new -s migracoes

# dentro do tmux, uma janela por VM:
# Ctrl+b c   → cria nova janela
# Ctrl+b número → navega entre janelas (0, 1, 2...)
# Ctrl+b ,   → renomeia a janela atual (útil pra saber qual cliente é qual)

# em cada janela:
export PBX_MYSQL_USER="asteriskuser"
export PBX_MYSQL_PASS="sua-senha"
# ...demais variáveis
bash scripts/migrate-pbx.sh
```

O ganho real do tmux aqui não é só rodar em paralelo, é poder **fechar o terminal ou cair a conexão SSH da sua máquina sem matar as migrações em andamento** — a sessão tmux continua rodando no servidor/máquina onde você a iniciou, e você reconecta depois com `tmux attach -t migracoes` pra ver o progresso de cada uma.

Alguns cuidados que fazem diferença na prática:

- **Não abre migração demais ao mesmo tempo.** Cada migração já usa rsync pesado (gravações, principalmente) e conexões SSH simultâneas. Abrir 15 janelas de uma vez satura a banda de saída da sua origem e o resultado é todas ficarem lentas, em vez de rápidas. Migrar em lotes de 3 a 5 por vez costuma ser um bom equilíbrio.
- **Renomeia as janelas do tmux com o nome do cliente/VM**, não deixa como "1", "2", "3" — quando alguma etapa pedir confirmação manual (ex: troca de DNS), você precisa saber rápido qual janela é qual sem abrir todas pra descobrir.
- **Os arquivos de log** (`migration_*.log`) já são nomeados com timestamp, então rodar várias instâncias em paralelo não causa conflito de nome — mas vale ir conferindo os logs entre um lote e outro, em vez de só no final, pra pegar falha cedo.
- Se o volume de gravações de algum cliente for muito grande, considera rodar a etapa 4 (gravações) separada das outras, numa janela própria, já que ela é a que mais demora e menos precisa de atenção ativa sua.

## Segurança

Nenhuma credencial fica no script. Ela só existe em memória durante a execução, vinda das variáveis de ambiente ou do prompt interativo.

Detalhes que importam:

- A senha de root da VM de destino é temporária. O script habilita `PasswordAuthentication` só durante a transferência e reverte no final. Se o script cair no meio, confere manualmente (`grep PasswordAuthentication /etc/ssh/sshd_config`).
- O log não grava senha, só os comandos. Mesmo assim trate como sensível, expõe estrutura de tabela e diretório.
- Prefira chave SSH sempre que der. A VM de origem é a única que depende de senha aqui, geralmente porque vai ser desativada logo depois.
- Qualquer senha que já passou por texto puro em outro lugar (script antigo, chat, doc), troca. Não tem meio-termo nisso.

## Requisitos

- [sshpass](https://sshpass.com/) e [rsync](https://github.com/RsyncProject/rsync)
- Chave SSH pra VM de destino (`~/.ssh/id_ed25519` por padrão)
- Modo `legacy`: o `issabel_migration.sh` precisa existir na VM de destino, o script para se não achar
- Pra migração em massa: `tmux` (ou `screen`, se preferir)

## Estrutura
