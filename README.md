# NovaK Reels Importer

Executor privado do NovaK Reels. Ele consulta a fila do painel, processa apenas links do TikTok que ja possuem direitos confirmados, baixa o video com `yt-dlp`, limita o arquivo a 95 MB e envia o resultado para revisao humana no armazenamento privado do painel.

## Protecoes do MVP

- aceita somente URLs HTTPS do dominio `tiktok.com`;
- processa no maximo 12 itens por execucao;
- impede duas execucoes simultaneas no GitHub Actions;
- nunca agenda ou publica o video automaticamente;
- exige revisao do arquivo no NovaK Reels;
- nao registra tokens nos logs;
- marca falhas no item da fila sem interromper os demais;
- usa somente itens classificados como proprios, autorizados ou de dominio publico pelo painel.

O importador tenta obter a melhor versao MP4 fornecida ao `yt-dlp`, mas nao promete remover ou detectar marca-d'agua em todos os casos. O arquivo sempre fica bloqueado para revisao antes de entrar na agenda.

## Configuracao

O workflow precisa de dois segredos no repositorio:

| Segredo | Finalidade |
|---|---|
| `NOVAK_IMPORTER_TOKEN` | Autentica o executor na API do NovaK Reels |
| `NOVAK_SITES_AUTHORIZATION` | Autoriza a chamada automatica ao site privado |

O executor roda automaticamente uma vez por hora e tambem pode ser iniciado pela aba **Actions**. A execucao manual permite escolher de um a quatro lotes, com ate tres videos por lote.

O workflow de verificacao roda os testes automaticamente em cada pull request e atualizacao da branch principal.

## Desenvolvimento

Requer Python 3.11 ou superior.

```bash
python -m pip install -e .
python -m unittest discover -s tests -v
```

Variaveis locais obrigatorias:

```text
NOVAK_API_BASE_URL=https://seu-site.example
NOVAK_IMPORTER_TOKEN=uma-chave-aleatoria-com-pelo-menos-32-caracteres
NOVAK_SITES_AUTHORIZATION=token-de-acesso-do-site-privado
```

Nao salve essas chaves em `.env` versionado, logs, issues ou mensagens.
