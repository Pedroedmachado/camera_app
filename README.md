# CamLivre

App próprio para a câmera Intelbras Mibo iM3 C, para Android e Windows.
Conecta direto na câmera pela rede local (RTSP), sem passar pela nuvem.

## O que faz
- Vídeo ao vivo em HD ou SD
- Som da câmera (liga/desliga)
- Foto da tela
- Gravação de vídeo (.mkv, sem perder qualidade)
- Galeria com as fotos e vídeos, com botão para mandar para a galeria do celular
- Tela cheia e reconexão automática se o Wi-Fi cair
- **Falar pela câmera** (botão Falar)
- **Cartão SD**: uso do cartão, gravações por dia (filtro de movimento), assistir,
  gravar trecho (.mkv), baixar o arquivo original (.dav) e apagar tudo (formatar)
- Assistir o cartão a partir de qualquer horário (funciona mesmo sem a API web)
- Busca automática da câmera na rede

## Como baixar
Na página do repositório, clique em **Releases** (coluna da direita, ou abaixo do código no celular) e baixe:
- **CamLivre-Android.apk** para o celular
- **CamLivre-Windows.zip** para o PC (extraia e abra `camlivre.exe`)

Cada alteração enviada para o repositório gera uma nova release automaticamente.

## Primeiro uso
Em Configurações, preencha:
- **IP da câmera**: aparece no app Mibo Smart ou na lista de aparelhos do roteador.
  Vale fixar esse IP no roteador (reserva de DHCP) para ele não mudar.
- **Senha**: a chave de acesso da câmera (a nova, se você trocou).

O aparelho precisa estar no mesmo Wi-Fi da câmera.

## Onde ficam os arquivos
- Android: pasta do app. Use o botão de download na Galeria para enviar à galeria do celular.
- Windows: `Documentos\CamLivre`.
