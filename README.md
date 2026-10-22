# CamLivre — versão 1

App próprio para a câmera Intelbras Mibo iM3 C, para Android e Windows.
Conecta direto na câmera pela rede local (RTSP), sem passar pela nuvem.

## O que faz
- Vídeo ao vivo em HD ou SD
- Som da câmera (liga/desliga)
- Foto da tela
- Gravação de vídeo (.mkv, sem perder qualidade)
- Galeria com as fotos e vídeos, com botão para mandar para a galeria do celular
- Tela cheia e reconexão automática se o Wi-Fi cair

## Como gerar o APK e o .exe (GitHub, grátis)
1. Crie uma conta em github.com e um repositório novo (pode ser privado).
2. Envie todos os arquivos deste zip para o repositório, incluindo a pasta `.github`.
3. Abra a aba **Actions**. A compilação começa sozinha e leva uns 10 minutos.
4. Quando ficar verde, entre na compilação e baixe em **Artifacts**:
   - `CamLivre-Android`: instale o `app-arm64-v8a-release.apk` no celular.
   - `CamLivre-Windows`: extraia e abra o `camlivre.exe`.

## Primeiro uso
Em Configurações, preencha:
- **IP da câmera**: aparece no app Mibo Smart ou na lista de aparelhos do roteador.
  Vale fixar esse IP no roteador (reserva de DHCP) para ele não mudar.
- **Senha**: a chave de acesso da câmera (a nova, se você trocou).

O aparelho precisa estar no mesmo Wi-Fi da câmera.

## Onde ficam os arquivos
- Android: pasta do app. Use o botão de download na Galeria para enviar à galeria do celular.
- Windows: `Documentos\CamLivre`.
