# NovaK Reels

Site mínimo para postar um link do TikTok ou de um clip da Twitch. O projeto usa Vercel Functions para a fila, Upstash Redis para armazenamento dos trabalhos, Vercel Blob para os vídeos processados e GitHub Actions para baixar, aplicar a marca d'água e publicar Reels no Instagram.

## O que acontece quando você toca em Postar

1. O site valida o link HTTPS e exige a senha de postagem e a confirmação de autorização.
2. O link entra na fila persistente no Upstash Redis.
3. O worker do GitHub Actions baixa o vídeo com `yt-dlp`, limita o arquivo a 95 MB e aplica a marca d'água `twitch.tv/facada` perto da parte inferior.
4. O vídeo processado é enviado ao Vercel Blob público e recebe a hashtag `#facadarp`.
5. O worker de publicação envia o Reel à API do Instagram e registra o resultado na fila.

O GitHub Actions verifica a fila a cada 15 minutos e também pode ser iniciado manualmente em **Actions → Import and publish authorized videos → Run workflow**. O horário do cron depende da disponibilidade do GitHub Actions, então o envio pelo site coloca o vídeo na fila; não garante publicação instantânea.

Use somente vídeos próprios, autorizados ou de domínio público. A pessoa que envia o link é responsável por ter direito de reutilizá-lo e publicá-lo. A marca d'água não comprova autorização. O token de publicação fica apenas nos segredos do GitHub, nunca no navegador.

## Recriar o projeto no Vercel

1. Entre no [Vercel Dashboard](https://vercel.com/dashboard), escolha **Add New → Project** e importe o repositório `nohanvs/novak-reels-importer` do GitHub, usando a branch `main`. Não é necessário escolher um framework; mantenha a raiz do repositório e faça o deploy.
2. No Marketplace do Vercel, adicione **Upstash Redis** e crie/conecte uma base Redis ao projeto. A integração precisa disponibilizar `UPSTASH_REDIS_REST_URL` e `UPSTASH_REDIS_REST_TOKEN`.
3. Crie um armazenamento **Vercel Blob** com acesso público para os vídeos dos Reels. O projeto precisa da variável `BLOB_READ_WRITE_TOKEN`.
4. Em **Project → Settings → Environment Variables**, crie:
   - `POST_PASSWORD`: a senha que você vai digitar na página para autorizar um envio.
   - `NOVAK_IMPORTER_TOKEN`: segredo aleatório longo, com pelo menos 32 caracteres.
   - Confirme que as integrações disponibilizaram `UPSTASH_REDIS_REST_URL`, `UPSTASH_REDIS_REST_TOKEN` e `BLOB_READ_WRITE_TOKEN).
5. Faça um novo deploy depois de conectar as integrações e salvar as variáveis.

## Segredos do GitHub Actions

Abra **GitHub → Settings → Secrets and variables → Actions → New repository secret** e configure:

| Nome | Valor |
| --- | --- |
| `NOVAK_API_BASE_URL` | URL HTTPS principal que o Vercel atribuiu ao projeto, sem caminho no final |
| `NOVAK_IMPORTER_TOKEN` | Exatamente o mesmo valor criado em `NOVAK_IMPORTER_TOKEN` no Vercel |
| `BLOB_READ_WRITE_TOKEN` | Valor de `BLOB_READ_WRITE_TOKEN` do Vercel Blob |
| `INSTAGRAM_USER_ID` | ID da conta profissional do Instagram conectada ao app Meta |
| `INSTAGRAM_ACCESS_TOKEN` | Token válido da API do Instagram |

Os dois últimos segredos já podem existir no repositório; confirme que continuam válidos. Nunca coloque esses valores no código, no README, em issues ou na página HTML.

## Executar e conferir

- No Vercel, abra a URL de produção. A página deve mostrar um link, a senha e a confirmação de autorização.
- Cole um link aceito, digite a senha configurada em `POST_PASSWORD`, marque a confirmação e toque em **Postar**.
- Para processar imediatamente, abra a aba **Actions** no GitHub e execute manualmente o workflow.
- Se o site disser que o Redis está indisponível, confirme a integração Upstash e faça novo deploy.
- Se o Actions reclamar de configuração, confira se `NOVAK_API_BASE_URL`, `NOVAK_IMPORTER_TOKEN` e `BLOB_READ_WRITE_TOKEN` estão presentes e se os dois tokens correspondentes são iguais no Vercel e no GitHub.
- Os trabalhos processados e seu estado são mantidos por 30 dias no Redis. Os vídeos públicos do Blob não são removidos automaticamente por este MVP; apague-os no painel do Blob quando não forem mais necessários.

## Desenvolvimento local

Requer Python 3.11+, Node.js 20+ e FFmpeg.

```bash
npm install
python -m pip install -e .
python -m unittest discover -s tests -v
```
