# Configuração do Facada Reels

O site já está publicado em `https://facada-reels-importer.vercel.app`, mas precisa das integrações próprias para manter a fila do Facada separada da fila do Luanz7.

## Vercel

No projeto **facada-reels-importer**, abra **Storage** e conecte/crie:

1. **Upstash Redis** — cria `UPSTASH_REDIS_REST_URL` e `UPSTASH_REDIS_REST_TOKEN`.
2. **Vercel Blob** público — crie `BLOB_READ_WRITE_TOKEN`.

Em **Settings → Environment Variables**, adicione em **Production**:

- `POST_PASSWORD`: senha usada no site para enviar um link manualmente.
- `NOVAK_IMPORTER_TOKEN`: texto aleatório com pelo menos 32 caracteres. Use o mesmo valor quando o executor local pedir esse token.
- `TWITCH_CLIENT_ID` e `TWITCH_CLIENT_SECRET`: credenciais gratuitas de um app criado em [Twitch Developers](https://dev.twitch.tv/console/apps).

Depois de salvar as variáveis, faça um novo deploy no Vercel.

## Executor local

Abra `INICIAR_LOCAL.bat` dentro desta pasta. Na primeira vez ele pede os tokens do Vercel e as contas do Instagram, com entrada oculta. Cada conta do Instagram pode ser a mesma usada no Luanz7 ou outra; as configurações ficam criptografadas e separadas em `.facada-local.json`.

O monitor consulta a Twitch e, uma vez por dia, coloca na fila no máximo três clips do Facada criados no dia anterior, ordenados pelo maior número de visualizações. Ele não republica um clip já selecionado.

Nunca cole credenciais no GitHub ou no chat.
